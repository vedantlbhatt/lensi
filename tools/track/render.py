"""Draws tools/track's outlines on the real frames, the way the phone draws them.

  render.py <frames dir> <name>.json <out dir>

Writes <name>.mp4 (the phone's outline, SAM 8 times a second, on every frame) and
<name>-compare.mp4 (top: SAM asked at a fixed spot every frame; bottom: the phone's
tracker), each with its per-frame J against the hand-drawn mask when there is one.
"""
import json
import os
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

PEN = (255, 138, 31)  # the guide lens orange, RGB
OLD = (255, 255, 255)


def font(size):
    for path in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                pass
    return ImageFont.load_default()


def outline(img, poly, color, width):
    """The app's outline: a faint dark halo, the line on top, a light fill."""
    if len(poly) < 3:
        return img
    h, w = img.shape[:2]
    pts = np.array([[x * w, y * h] for x, y in poly], dtype=np.float32)
    pts_i = np.round(pts * 4).astype(np.int32)  # 2 fractional bits for smooth edges
    fill = img.copy()
    cv2.fillPoly(fill, [pts_i], color[::-1], lineType=cv2.LINE_AA, shift=2)
    img = cv2.addWeighted(fill, 0.14, img, 0.86, 0)
    halo = img.copy()
    cv2.polylines(halo, [pts_i], True, (0, 0, 0), int(width + 3), lineType=cv2.LINE_AA, shift=2)
    img = cv2.addWeighted(halo, 0.35, img, 0.65, 0)
    cv2.polylines(img, [pts_i], True, color[::-1], int(width), lineType=cv2.LINE_AA, shift=2)
    return img


def caption(img, lines, size=20):
    """Plain white text on a soft dark band at the top."""
    pil = Image.fromarray(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))
    d = ImageDraw.Draw(pil, "RGBA")
    f = font(size)
    band = int(size * 1.5 * len(lines) + size * 0.6)
    d.rectangle([0, 0, pil.width, band], fill=(0, 0, 0, 130))
    y = int(size * 0.35)
    for text in lines:
        d.text((int(size * 0.6), y), text, font=f, fill=(255, 255, 255, 255))
        y += int(size * 1.5)
    return cv2.cvtColor(np.array(pil), cv2.COLOR_RGB2BGR)


def writer(path, w, h, fps):
    return cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))


def main():
    frames_dir, json_path, out_dir = sys.argv[1:4]
    os.makedirs(out_dir, exist_ok=True)
    data = json.load(open(json_path))
    name = data["name"]
    runs = {r["label"]: r for r in data["runs"]}
    lensi, fixed = runs["lensi@8"], runs["fixed"]
    unpack = lambda flat: [(flat[i], flat[i + 1]) for i in range(0, len(flat) - 1, 2)]
    fps = 24
    first = cv2.imread(os.path.join(frames_dir, data["frameNames"][0]))
    h, w = first.shape[:2]
    # Big enough to read on a phone.
    s = 2 if w < 1000 else 1
    single = writer(os.path.join(out_dir, f"{name}.mp4"), w * s, h * s, fps)
    pair = writer(os.path.join(out_dir, f"{name}-compare.mp4"), w, h * 2, fps)
    def j(run, i):
        v = run["jPerFrame"]
        return f"  J {v[i] * 100:.0f}%" if i < len(v) else ""
    for i, fn in enumerate(data["frameNames"]):
        img = cv2.imread(os.path.join(frames_dir, fn))
        if img is None:
            continue
        big = cv2.resize(img, (w * s, h * s), interpolation=cv2.INTER_CUBIC) if s != 1 else img.copy()
        big = outline(big, unpack(lensi["outlines"][i]), PEN, 2.5 * s)
        big = caption(big, [f"Live SAM, tracked: {name}{j(lensi, i)}"], size=13 * s)
        single.write(big)
        left = outline(img.copy(), unpack(fixed["outlines"][i]), OLD, 2)
        left = caption(left, [f"Before: SAM at a fixed spot{j(fixed, i)}"], size=15)
        right = outline(img.copy(), unpack(lensi["outlines"][i]), PEN, 2.5)
        right = caption(right, [f"Now: tracked, SAM 8/s{j(lensi, i)}"], size=15)
        pair.write(np.vstack([left, right]))
    single.release()
    pair.release()
    print(f"{name}: wrote {name}.mp4 and {name}-compare.mp4 ({len(data['frameNames'])} frames)")


if __name__ == "__main__":
    main()
