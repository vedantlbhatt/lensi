"""How well an outline run followed the thing: IoU with the reference masks frame by frame, how
much the outline shakes, and the outline drawn on the video the way the phone draws it.

  report.py <frames dir> <reference dir> <run.json> <out dir> [name] [key ...]

run.json is tools/edgetrack's: frames[i][key] is a flat x,y list (fractions of the frame); `key`
defaults to "outline" (the tracker's own) and can name more (say "shown", what the phone draws
after smoothing), each scored and drawn. Shake: how far the outline's points sit from halfway
between where they were the frame before and the frame after, in pixels of the 540-wide frame --
zero for an outline that glides, however fast; a few pixels when it trembles. Wobble: how much
its shape changes from one frame to the next once moved, turned and scaled to fit (pixels, RMS):
a bottle's own outline barely changes in a 30th of a second, so this is mostly noise.

Writes <name>-summary.txt, <name>.csv, <name>-<key>.mp4 and <name>-sheet.jpg.
"""
import json
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "track"))
from render import PEN, caption, outline  # noqa: E402

N = 128  # points an outline is resampled to, to compare frames


def ring(flat):
    p = np.array(flat, dtype=np.float64).reshape(-1, 2)
    return p if len(p) >= 3 else None


def resample(p, n=N):
    """n points evenly spaced along the closed outline, counter-clockwise, starting at the top."""
    if signed_area(p) < 0:
        p = p[::-1]
    q = np.vstack([p, p[:1]])
    seg = np.linalg.norm(np.diff(q, axis=0), axis=1)
    s = np.concatenate([[0], np.cumsum(seg)])
    if s[-1] <= 0:
        return np.repeat(p[:1], n, axis=0)
    t = np.linspace(0, s[-1], n, endpoint=False)
    out = np.stack([np.interp(t, s, q[:, 0]), np.interp(t, s, q[:, 1])], axis=1)
    return out


def signed_area(p):
    x, y = p[:, 0], p[:, 1]
    return 0.5 * float(np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y))


def align(a, b):
    """b's points rolled to sit best against a's (both resampled)."""
    best, shift = None, 0
    for k in range(len(b)):
        d = np.sum((np.roll(b, -k, axis=0) - a) ** 2)
        if best is None or d < best:
            best, shift = d, k
    return np.roll(b, -shift, axis=0)


def similarity_fit(a, b):
    """a moved, turned and scaled to fit b best (Umeyama; both N x 2, points paired)."""
    ca, cb = a.mean(axis=0), b.mean(axis=0)
    a0, b0 = a - ca, b - cb
    cov = b0.T @ a0 / len(a)
    u, sv, vt = np.linalg.svd(cov)
    d = np.sign(np.linalg.det(u @ vt))
    D = np.diag([1, d])
    r = u @ D @ vt
    var = np.mean(np.sum(a0 ** 2, axis=1))
    scale = np.trace(np.diag(sv) @ D) / var if var > 0 else 1.0
    return (scale * (r @ a0.T)).T + cb


def raster(poly, w, h):
    """The pixels whose centres are inside the outline (OpenCV puts pixel i's centre at i, a
    fraction of the frame at i + 0.5)."""
    m = np.zeros((h, w), np.uint8)
    if poly is not None:
        pts = np.round((poly * [w, h] - 0.5) * 4).astype(np.int32)
        cv2.fillPoly(m, [pts], 1, lineType=cv2.LINE_8, shift=2)
    return m.astype(bool)


def main():
    frames_dir, ref_dir, run_path, out_dir = sys.argv[1:5]
    name = sys.argv[5] if len(sys.argv) > 5 else "run"
    keys = sys.argv[6:] or ["outline"]
    os.makedirs(out_dir, exist_ok=True)
    run = json.load(open(run_path))
    frames = run["frames"]
    first = cv2.imread(os.path.join(frames_dir, frames[0]["name"]))
    h, w = first.shape[:2]
    px = np.array([w, h], dtype=np.float64)
    rows = []
    stats = {}
    for key in keys:
        polys = [ring(f.get(key, [])) for f in frames]
        ious, shake, wobble = [], [], []
        for i, f in enumerate(frames):
            ref_path = os.path.join(ref_dir, f["name"].replace(".jpg", ".png"))
            ref = cv2.imread(ref_path, cv2.IMREAD_GRAYSCALE)
            ref = ref > 127 if ref is not None else np.zeros((h, w), bool)
            ours = raster(polys[i], w, h)
            union = (ours | ref).sum()
            ious.append(1.0 if union == 0 else float((ours & ref).sum() / union))
        for i in range(1, len(frames) - 1):
            a, b, c = polys[i - 1], polys[i], polys[i + 1]
            if a is None or b is None or c is None:
                continue
            rb = resample(b) * px
            ra = align(rb, resample(a) * px)
            rc = align(rb, resample(c) * px)
            shake.append(float(np.mean(np.linalg.norm(rb - (ra + rc) / 2, axis=1))))
            wobble.append(float(np.sqrt(np.mean(np.sum((similarity_fit(ra, rb) - rb) ** 2, axis=1)))))
        stats[key] = {"ious": ious, "shake": shake, "wobble": wobble}
        for i, v in enumerate(ious):
            if len(rows) <= i:
                rows.append({"frame": i})
            rows[i][f"iou_{key}"] = v
    lines = [f"{name}: {len(frames)} frames, {w}x{h}"]
    for key in keys:
        ious = np.array(stats[key]["ious"])
        shake = np.array(stats[key]["shake"]) if stats[key]["shake"] else np.zeros(1)
        wobble = np.array(stats[key]["wobble"]) if stats[key]["wobble"] else np.zeros(1)
        lines.append(
            f"  {key}: IoU with the reference mean {ious.mean():.4f}, median {np.median(ious):.4f}, worst {ious.min():.4f} "
            f"(frame {int(ious.argmin())}), under 0.9: {int((ious < 0.9).sum())}, under 0.7: {int((ious < 0.7).sum())}, "
            f"under 0.5: {int((ious < 0.5).sum())}; shake mean {shake.mean():.2f} px, 95th percentile "
            f"{np.percentile(shake, 95):.2f} px, worst {shake.max():.2f} px; wobble mean {wobble.mean():.2f} px, 95th "
            f"percentile {np.percentile(wobble, 95):.2f} px")
    ms = run.get("medianMs")
    if ms:
        lines.append("  median ms a frame: " + ", ".join(f"{k} {v}" for k, v in sorted(ms.items())))
    text = "\n".join(lines)
    print(text)
    open(os.path.join(out_dir, f"{name}-summary.txt"), "w").write(text + "\n")
    with open(os.path.join(out_dir, f"{name}.csv"), "w") as f:
        cols = ["frame"] + [f"iou_{k}" for k in keys]
        f.write(",".join(cols) + "\n")
        for r in rows:
            f.write(",".join(f"{r.get(c, '')}" if c == "frame" else f"{r.get(c, 0):.4f}" for c in cols) + "\n")

    # Videos: the outline as the phone draws it, at twice the frame's size (REPORT_VIDEO=0: none).
    if os.environ.get("REPORT_VIDEO", "1") == "0":
        return
    s = 2
    thumbs = []
    for key in keys:
        path = os.path.join(out_dir, f"{name}-{key}.mp4")
        out = cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*"mp4v"), 30, (w * s, h * s))
        for i, f in enumerate(frames):
            img = cv2.imread(os.path.join(frames_dir, f["name"]))
            if img is None:
                continue
            big = cv2.resize(img, (w * s, h * s), interpolation=cv2.INTER_CUBIC)
            poly = f.get(key, [])
            pts = [(poly[j], poly[j + 1]) for j in range(0, len(poly) - 1, 2)]
            big = outline(big, pts, PEN, 2.5 * s)
            iou = stats[key]["ious"][i]
            big = caption(big, [f"{key}  frame {i}  IoU {iou:.3f}"], size=13 * s)
            out.write(big)
            if key == keys[-1] and i % 15 == 0:
                t = cv2.resize(big, (w * 240 // h, 240))
                thumbs.append(t)
        out.release()
    if thumbs:
        cols = 9
        while len(thumbs) % cols:
            thumbs.append(np.zeros_like(thumbs[0]))
        sheet = np.vstack([np.hstack(thumbs[i:i + cols]) for i in range(0, len(thumbs), cols)])
        cv2.imwrite(os.path.join(out_dir, f"{name}-sheet.jpg"), sheet, [cv2.IMWRITE_JPEG_QUALITY, 85])


if __name__ == "__main__":
    main()
