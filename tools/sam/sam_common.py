"""Torch-free pieces of Lensi's SAM pipeline: preprocessing, prompt packing, mask choice and
the mask -> polygon postprocess.

This file is the reference for app/modules/lensi-ar/ios/SAMSegmenter.swift. Every function here
has a Swift twin with the same name in a comment; change them together.

Needs numpy + Pillow. OpenCV is imported lazily, only by `largest_contour`, so
verify_coreml.py can import this module on a macOS runner without it.
"""

from __future__ import annotations

import base64
import hashlib
import os
import urllib.request
from typing import Optional, Sequence

import numpy as np

IMG_SIZE = 1024  # encoder input side; the image is resized so its long side is this
MASK_SIZE = 256  # side of the decoder's low-res masks (covers the whole 1024 canvas)
EMBED_SHAPE = (1, 256, 64, 64)
NUM_POINTS = 5  # fixed number of prompt slots in LensiSAMDecoder
PIXEL_MEAN = (123.675, 116.28, 103.53)  # applied inside LensiSAMEncoder
PIXEL_STD = (58.395, 57.12, 57.375)
# Canvas fill. SAM pads with exact zeros *after* normalisation; filling with the rounded mean
# colour gets within 0.008 of that, which the evaluation shows is invisible in the masks.
PAD_RGB = (124, 116, 104)
WORK_DIV = 2  # postprocess grid = 1024-space resolution / 2, i.e. 512 on the long side
SIMPLIFY_FRACTION = 0.003  # Douglas-Peucker epsilon, as a fraction of the contour perimeter

LABEL_PAD, LABEL_BG, LABEL_FG, LABEL_BOX_TL, LABEL_BOX_BR = -1, 0, 1, 2, 3


# --------------------------------------------------------------------------------------------
# Preprocessing (Swift: SAMSegmenter.prepare / makeCanvas)


def resized_size(width: int, height: int, side: int = IMG_SIZE) -> tuple[int, int]:
    """SAM's ResizeLongestSide.get_preprocess_shape, returned as (new_w, new_h)."""
    scale = side * 1.0 / max(width, height)
    return int(width * scale + 0.5), int(height * scale + 0.5)


def preprocess(image_rgb: np.ndarray, resample: Optional[int] = None) -> tuple[np.ndarray, dict]:
    """uint8 HxWx3 RGB -> (1024x1024x3 uint8 canvas, params).

    Resizes the long side to 1024 with Pillow bilinear (what SamPredictor does; `resample`
    overrides the filter) and pastes it at the top-left of a PAD_RGB canvas. The canvas is fed to
    LensiSAMEncoder as raw 0-255 RGB. On device, Core Graphics does the resize.
    """
    from PIL import Image

    h, w = image_rgb.shape[:2]
    new_w, new_h = resized_size(w, h)
    filt = Image.BILINEAR if resample is None else resample
    resized = np.asarray(Image.fromarray(image_rgb).resize((new_w, new_h), filt))
    canvas = np.empty((IMG_SIZE, IMG_SIZE, 3), np.uint8)
    canvas[:] = PAD_RGB
    canvas[:new_h, :new_w] = resized
    return canvas, {"width": w, "height": h, "resized_width": new_w, "resized_height": new_h}


# --------------------------------------------------------------------------------------------
# Prompts (Swift: SAMSegmenter.packPrompt / chooseMask)


def pack_prompt(
    points: Sequence[Sequence[float]],
    labels: Sequence[int],
    box: Optional[Sequence[float]],
    params: dict,
) -> tuple[np.ndarray, np.ndarray]:
    """Normalised prompt -> (point_coords [1,5,2], point_labels [1,5]) float32 decoder inputs.

    points: (x, y) in [0, 1] of the upright image, top-left origin. labels: 1 = foreground,
    0 = background. box: normalised (x0, y0, x1, y1) or None. Points come first (at most 5, or
    3 with a box), then the box corners (labels 2, 3), then padding slots at (0, 0) label -1.
    """
    sx, sy = float(params["resized_width"]), float(params["resized_height"])
    max_points = NUM_POINTS - (2 if box is not None else 0)
    used = list(zip(points, labels))[:max_points]
    if not used and box is None:
        raise ValueError("need at least one point or a box")  # Swift: SAMError.noPrompt
    slots: list[tuple[float, float, float]] = []
    for (x, y), label in used:
        slots.append((x * sx, y * sy, float(label)))
    if box is not None:
        x0, y0, x1, y1 = box
        slots.append((min(x0, x1) * sx, min(y0, y1) * sy, float(LABEL_BOX_TL)))
        slots.append((max(x0, x1) * sx, max(y0, y1) * sy, float(LABEL_BOX_BR)))
    while len(slots) < NUM_POINTS:
        slots.append((0.0, 0.0, float(LABEL_PAD)))
    coords = np.array([[[s[0], s[1]] for s in slots]], np.float32)
    lab = np.array([[s[2] for s in slots]], np.float32)
    return coords, lab


def uses_multimask(labels: Sequence[int], has_box: bool) -> bool:
    """One positive click and nothing else is ambiguous: pick among the 3 multimask outputs.
    `labels` are those of the points actually packed (pack_prompt keeps at most 5, or 3 + box)."""
    return not has_box and len(labels) == 1 and labels[0] == LABEL_FG


def choose_mask(scores: np.ndarray, labels: Sequence[int], has_box: bool) -> int:
    """Index into the decoder's 4 masks: best of 1...3 by score, or the single-mask token 0."""
    s = np.asarray(scores, np.float32).reshape(-1)
    if uses_multimask(labels, has_box):
        return 1 + int(np.argmax(s[1:4]))
    return 0


# --------------------------------------------------------------------------------------------
# Postprocess (Swift: SAMSegmenter.upsample / largestContour / simplifyClosed / polygon)


def work_size(params: dict) -> tuple[int, int]:
    """Size of the grid the mask is traced on: the valid image area at 1024-space / WORK_DIV."""
    out_w = max(1, int(params["resized_width"] / WORK_DIV + 0.5))
    out_h = max(1, int(params["resized_height"] / WORK_DIV + 0.5))
    return out_w, out_h


def upsample_logits(logits256: np.ndarray, params: dict) -> np.ndarray:
    """Crop the valid (non-padding) part of a 256x256 logit map and resample it bilinearly onto
    the work grid, in one pass (half-pixel centres, edge clamp: torch's align_corners=False).
    Returns float32 logits of shape (out_h, out_w); threshold them at 0."""
    lg = np.asarray(logits256, np.float32).reshape(MASK_SIZE, MASK_SIZE)
    out_w, out_h = work_size(params)
    valid_w = params["resized_width"] / 4.0  # extent of the image inside the 256 mask
    valid_h = params["resized_height"] / 4.0
    sx = (np.arange(out_w, dtype=np.float32) + 0.5) * np.float32(valid_w / out_w) - 0.5
    sy = (np.arange(out_h, dtype=np.float32) + 0.5) * np.float32(valid_h / out_h) - 0.5
    sx = np.clip(sx, 0, MASK_SIZE - 1)
    sy = np.clip(sy, 0, MASK_SIZE - 1)
    x0 = np.floor(sx).astype(np.int64)
    y0 = np.floor(sy).astype(np.int64)
    x1 = np.minimum(x0 + 1, MASK_SIZE - 1)
    y1 = np.minimum(y0 + 1, MASK_SIZE - 1)
    fx = (sx - x0).astype(np.float32)[None, :]
    fy = (sy - y0).astype(np.float32)[:, None]
    top = lg[y0][:, x0] * (1 - fx) + lg[y0][:, x1] * fx
    bottom = lg[y1][:, x0] * (1 - fx) + lg[y1][:, x1] * fx
    return (top * (1 - fy) + bottom * fy).astype(np.float32)


def largest_contour(binary: np.ndarray) -> np.ndarray:
    """Largest external contour of a 0/255 uint8 mask, as (N, 2) float pixel coordinates
    (pixel centres, so a pixel's contour point is index + 0.5). Swift uses
    VNDetectContoursRequest for this step; the two agree to within about one work pixel."""
    import cv2

    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    if not contours:
        return np.zeros((0, 2), np.float64)
    best = max(contours, key=cv2.contourArea)
    return best[:, 0, :].astype(np.float64) + 0.5


def _segment_distance(p: np.ndarray, a: np.ndarray, b: np.ndarray) -> np.ndarray:
    ab = b - a
    denom = float(ab @ ab)
    if denom == 0.0:
        return np.hypot(*(p - a).T)
    t = np.clip(((p - a) @ ab) / denom, 0.0, 1.0)
    proj = a + t[:, None] * ab
    return np.hypot(*(p - proj).T)


def _douglas_peucker(chain: np.ndarray, eps: float) -> np.ndarray:
    """Open-chain Douglas-Peucker with an explicit stack; keeps both endpoints."""
    keep = np.zeros(len(chain), bool)
    keep[0] = keep[-1] = True
    stack = [(0, len(chain) - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        d = _segment_distance(chain[i + 1 : j], chain[i], chain[j])
        m = int(np.argmax(d))  # first maximum, like the Swift loop's strict '>'
        if d[m] > eps:
            k = i + 1 + m
            keep[k] = True
            stack.append((i, k))
            stack.append((k, j))
    return chain[keep]


def perimeter(points: np.ndarray) -> float:
    if len(points) < 2:
        return 0.0
    return float(np.hypot(*(np.roll(points, -1, axis=0) - points).T).sum())


def simplify_closed(points: np.ndarray, eps: float) -> np.ndarray:
    """Douglas-Peucker on a closed ring: split at the point farthest from points[0], simplify
    both halves, join them."""
    n = len(points)
    if n < 4:
        return points
    d2 = ((points - points[0]) ** 2).sum(axis=1)
    k = int(np.argmax(d2))
    if k == 0:
        return points[:1]
    first = _douglas_peucker(points[: k + 1], eps)
    second = _douglas_peucker(np.vstack([points[k:], points[:1]]), eps)
    return np.vstack([first[:-1], second[:-1]])


def mask_to_polygon(logits256: np.ndarray, params: dict) -> tuple[list[tuple[float, float]], float]:
    """The app's full postprocess. Returns (polygon normalised to [0,1] image coords with a
    top-left origin, mask area as a fraction of the image). An empty mask gives ([], 0)."""
    up = upsample_logits(logits256, params)
    binary = np.where(up > 0, 255, 0).astype(np.uint8)
    out_h, out_w = binary.shape
    area = float((binary > 0).mean())
    contour = largest_contour(binary)
    if len(contour) < 3:
        return [], area
    simplified = simplify_closed(contour, SIMPLIFY_FRACTION * perimeter(contour))
    if len(simplified) < 3:
        return [], area
    return [(float(x) / out_w, float(y) / out_h) for x, y in simplified], area


# --------------------------------------------------------------------------------------------
# Fixture helpers (shared by evaluate.py and verify_coreml.py)


def mask64_from_logits(logits256: np.ndarray) -> np.ndarray:
    """256x256 logits -> 64x64 bool mask (4x4 mean of the logits, then > 0)."""
    lg = np.asarray(logits256, np.float32).reshape(64, 4, 64, 4)
    return lg.mean(axis=(1, 3)) > 0


def encode_mask64(mask: np.ndarray) -> str:
    return base64.b64encode(np.packbits(mask.astype(bool).reshape(-1)).tobytes()).decode("ascii")


def decode_mask64(text: str) -> np.ndarray:
    bits = np.unpackbits(np.frombuffer(base64.b64decode(text), np.uint8))
    return bits[: 64 * 64].reshape(64, 64).astype(bool)


def iou(a: np.ndarray, b: np.ndarray) -> float:
    a = np.asarray(a, bool)
    b = np.asarray(b, bool)
    union = np.logical_or(a, b).sum()
    if union == 0:
        return 1.0
    return float(np.logical_and(a, b).sum() / union)


def embedding_probe_indices(count: int = 64, seed: int = 0) -> list[list[int]]:
    """Fixed (channel, y, x) positions sampled from the [1,256,64,64] embedding."""
    rng = np.random.default_rng(seed)
    return [[int(c), int(y), int(x)] for c, y, x in zip(
        rng.integers(0, 256, count), rng.integers(0, 64, count), rng.integers(0, 64, count))]


def fetch(url: str, dest: str, sha256: Optional[str] = None) -> str:
    """Download `url` to `dest` once; verify sha256 when given."""
    if not os.path.exists(dest):
        os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
        tmp = dest + ".part"
        with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
        os.replace(tmp, dest)
    if sha256:
        h = hashlib.sha256()
        with open(dest, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        if h.hexdigest() != sha256:
            raise RuntimeError(f"sha256 mismatch for {dest}: {h.hexdigest()} != {sha256}")
    return dest


def load_rgb(path: str) -> np.ndarray:
    from PIL import Image, ImageOps

    with Image.open(path) as im:
        return np.asarray(ImageOps.exif_transpose(im).convert("RGB"))


def round_list(values, digits: int = 5) -> list:
    return [round(float(v), digits) for v in np.asarray(values).reshape(-1)]
