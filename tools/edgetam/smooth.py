"""The app's outline code in Python, to try ways of steadying EdgeTAM's outlines on footage before
they go into Swift: `contour` is MaskContour.largest (LiveSeg.swift), `resample`, `align` and
`steady` are OutlineMath's. Change them together.

  smooth.py <logits.npz> <frames dir> <reference masks dir> <out.json>

logits.npz: every frame's 256 x 256 mask logits (`logits`) and object scores (`scores`), as the
tracker chose them. Writes a tools/edgetrack-style run with "outline" (each frame's own) and
"shown" (steadied as the app does), for report.py.
"""
import json
import os
import sys

import cv2
import numpy as np

COUNT = 64


def contour(logits):
    """MaskContour.largest: the largest 4-connected region above zero, holes filled, traced by
    marching squares on the zero level (sub-cell). Cell units (cell i's centre at i + 0.5)."""
    H, W = logits.shape
    inside = (logits > 0).astype(np.uint8)
    if not inside.any():
        return np.zeros((0, 2))
    n, labels, stats, _ = cv2.connectedComponentsWithStats(inside, connectivity=4)
    best = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    comp = (labels == best).astype(np.uint8)
    # Fill holes: whatever the outside can't reach is part of it.
    pad = np.pad(comp, 1)
    flood = pad.copy()
    mask = np.zeros((H + 4, W + 4), np.uint8)
    cv2.floodFill(flood, mask, (0, 0), 2, flags=4)
    comp = (flood[1:-1, 1:-1] != 2).astype(bool)
    v = -np.ones((H + 2, W + 2), np.float64)
    l = logits.astype(np.float64)
    v[1:-1, 1:-1] = np.where(comp, np.maximum(l, 0.01), np.minimum(l, -0.01))
    CW = W + 2
    a = v[:-1, :-1]
    b = v[:-1, 1:]
    c = v[1:, 1:]
    d = v[1:, :-1]
    code = (a > 0) * 1 + (b > 0) * 2 + (c > 0) * 4 + (d > 0) * 8
    centre = (a + b + c + d) > 0
    links = {}

    def link(p, q):
        links.setdefault(p, []).append(q)
        links.setdefault(q, []).append(p)

    ys, xs = np.nonzero((code != 0) & (code != 15))
    for cy, cx in zip(ys.tolist(), xs.tolist()):
        k = int(code[cy, cx])
        T = 2 * (cy * CW + cx)
        B = 2 * ((cy + 1) * CW + cx)
        L = 2 * (cy * CW + cx) + 1
        R = 2 * (cy * CW + cx + 1) + 1
        if k in (1, 14):
            link(L, T)
        elif k in (2, 13):
            link(T, R)
        elif k in (3, 12):
            link(L, R)
        elif k in (4, 11):
            link(R, B)
        elif k in (6, 9):
            link(T, B)
        elif k in (7, 8):
            link(L, B)
        elif k == 5:
            if centre[cy, cx]:
                link(T, R)
                link(B, L)
            else:
                link(L, T)
                link(R, B)
        elif k == 10:
            if centre[cy, cx]:
                link(L, T)
                link(R, B)
            else:
                link(T, R)
                link(B, L)
    flat = v.ravel()

    def position(e):
        base = e // 2
        x, y = base % CW, base // CW
        x2, y2 = (x + 1, y) if e % 2 == 0 else (x, y + 1)
        va, vb = flat[y * CW + x], flat[y2 * CW + x2]
        t = 0.5 if va == vb else va / (va - vb)
        return (x - 0.5 + (x2 - x) * t, y - 0.5 + (y2 - y) * t)

    seen = set()
    best_loop, best_area = [], 0.0
    for start in links:
        if start in seen:
            continue
        loop = []
        prev, cur = -1, start
        while cur not in seen:
            seen.add(cur)
            loop.append(position(cur))
            nb = links[cur]
            nxt = nb[0] if nb[0] != prev else (nb[1] if len(nb) > 1 else -1)
            if nxt < 0:
                break
            prev, cur = cur, nxt
        p = np.array(loop)
        if len(p) >= 3:
            area = abs(signed_area(p))
            if area > best_area:
                best_area, best_loop = area, loop
    return np.array(best_loop)


def signed_area(p):
    x, y = p[:, 0], p[:, 1]
    return 0.5 * float(np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y))


def resample(ring, count=COUNT, scale=(1.0, 1.0)):
    """OutlineMath.resample: `count` points evenly spaced (in `scale` units) along the ring."""
    n = len(ring)
    if n < 3:
        return ring
    q = np.vstack([ring, ring[:1]])
    seg = np.hypot(np.diff(q[:, 0]) * scale[0], np.diff(q[:, 1]) * scale[1])
    along = np.concatenate([[0], np.cumsum(seg)])
    total = along[-1]
    if total <= 0:
        return ring
    d = total * np.arange(count) / count
    edge = np.clip(np.searchsorted(along, d, side="left") - 1, 0, n - 1)
    length = along[edge + 1] - along[edge]
    t = np.where(length > 0, (d - along[edge]) / np.where(length > 0, length, 1), 0)
    a = q[edge]
    b = q[edge + 1]
    return a + (b - a) * t[:, None]


def align(new, old):
    """OutlineMath.align: `new` rolled (and reversed, if that fits better) to line up with `old`;
    and the RMS gap."""
    best, best_cost = new, np.inf
    for ring in (new, new[::-1]):
        for shift in range(len(new)):
            r = np.roll(ring, -shift, axis=0)
            cost = float(np.sum((r - old) ** 2))
            if cost < best_cost:
                best, best_cost = r, cost
    return best, (best_cost / len(new)) ** 0.5


def spread(p):
    m = p.mean(axis=0)
    return float(np.sqrt(np.mean(np.sum((p - m) ** 2, axis=1))))


SMOOTHING = {
    # quiet, keepQuiet, small, keepSmall, still, followStill, followMoving (OutlineMath.Smoothing)
    "standard": (0.1, 0.65, 0.25, 0.4, 0.03, 0.6, 1.0),
    "strong": (0.1, 0.65, 0.25, 0.4, 0.15, 0.5, 0.9),
    "light": (0.05, 0.5, 0.1, 0.25, 0.03, 0.6, 1.0),
    "minimal": (0.04, 0.4, 0.04, 0.0, 0.0, 1.0, 1.0),
    "still": (0.15, 0.8, 0.3, 0.6, 0.1, 0.35, 0.8),
}


def steady(old, new, previous, how="standard"):
    """OutlineMath.steady (points in pixels): the outline to show, and this change."""
    if old is None or len(old) != len(new) or len(new) == 0:
        return new, None
    quiet, keep_quiet, small, keep_small, still, follow_still, follow_moving = SMOOTHING[how]
    size = max(spread(old), 1e-6)
    co, cn = old.mean(axis=0), new.mean(axis=0)
    jump = float(np.linalg.norm(co - cn)) / size
    if jump >= 1:
        return new, None
    shape, gap = align(new - cn, old - co)
    change = shape - (old - co)
    relative = gap / size
    keep = keep_quiet if relative < quiet else keep_small if relative < small else 0.0
    if previous is not None and len(previous) == len(change) and keep > 0:
        dot = float(np.sum(change * previous))
        a, b = float(np.sum(change ** 2)), float(np.sum(previous ** 2))
        if a > 0 and b > 0 and dot / (a ** 0.5 * b ** 0.5) > 0.3:
            keep = 0.0
    follow = follow_still if jump < still else follow_moving
    middle = co + (cn - co) * follow
    return middle + (old - co) * keep + shape * (1 - keep), change


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


def steady_fit(old, new, previous, quiet=0.06, keep=0.7, loud=0.15):
    """A candidate: the last outline carried onto the new one's place, turn and size (a
    similarity fit, so motion and zoom pass straight through), and only then its shape
    blended -- `keep` of the old shape while the new one differs by under `quiet` of its size,
    none past `loud`."""
    if old is None or len(old) != len(new) or len(new) == 0:
        return new, None
    size = max(spread(old), 1e-6)
    co, cn = old.mean(axis=0), new.mean(axis=0)
    if float(np.linalg.norm(co - cn)) / size >= 1:
        return new, None
    shape, _ = align(new - cn, old - co)
    lined = shape + cn
    moved = similarity_fit(old, lined)
    r = lined - moved
    rel = float(np.sqrt(np.mean(np.sum(r ** 2, axis=1)))) / size
    k = keep if rel < quiet else keep * (loud - rel) / (loud - quiet) if rel < loud else 0.0
    return moved + (1 - k) * r, r


def main():
    npz, frames_dir, ref_dir, out = sys.argv[1:5]
    how = sys.argv[5] if len(sys.argv) > 5 else "standard"
    data = np.load(npz)
    logits, scores = data["logits"].astype(np.float32), data["scores"]
    names = sorted(f for f in os.listdir(frames_dir) if f.endswith(".jpg"))
    h, w = cv2.imread(os.path.join(frames_dir, names[0])).shape[:2]
    n = logits.shape[1]
    frames = []
    shown, change = None, None
    for i, name in enumerate(names[: len(logits)]):
        cells = contour(logits[i]) if scores[i] > 0 else np.zeros((0, 2))
        outline = cells / n
        if len(outline) >= 3:
            ring = resample(outline, scale=(w, h)) * [w, h]
            if how.startswith("fit"):
                # fit[:quiet:keep:loud]
                args = [float(v) for v in how.split(":")[1:]]
                shown, change = steady_fit(shown, ring, change, *args)
            else:
                shown, change = steady(shown, ring, change, how)
        else:
            shown, change = None, None
        frames.append({"name": name, "outline": [round(float(v), 5) for v in outline.ravel()],
                       "shown": [] if shown is None else [round(float(v), 5) for v in (shown / [w, h]).ravel()]})
    json.dump({"frames": frames}, open(out, "w"))
    print(f"{out}: {len(frames)} frames")


if __name__ == "__main__":
    main()
