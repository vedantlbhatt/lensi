"""What the phone's timing alone costs on the bottle clip, apart from how the outline is moved
between answers: tools/edgetrack's every-frame outlines taken as EdgeTAM's answers at the phone's
rate (a look every `every` frames, each answer `late` frames after its frame, glided in as
OutlineMath.glide does), with the outline between answers moved (a) exactly as the bottle moved
(the affine map from its every-frame outline at one frame onto the next: the best a phone that
knew its own motion perfectly could do, which ARKit approaches for a thing standing still) or
(b) not at all. Scored like report.py, against EdgeTAM's own every-frame masks.

  timing.py <reference dir> <edgetrack run.json> [every late]...
"""
import glob
import json
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from smooth import affine_fit, align, resample, spread  # noqa: E402

ref_dir, run_path = sys.argv[1:3]
pairs = [(int(a), int(b)) for a, b in zip(sys.argv[3::2], sys.argv[4::2])] or [(2, 2), (3, 3)]
masks = sorted(glob.glob(os.path.join(ref_dir, "*.png")))
run = json.load(open(run_path))["frames"]
N = min(len(run), len(masks))
truth = [cv2.imread(m, cv2.IMREAD_GRAYSCALE) > 127 for m in masks[:N]]
H, W = truth[0].shape


def ring(flat):
    p = np.array(flat or [], float).reshape(-1, 2)
    return resample(p * [W, H], 64) if len(p) >= 3 else None


R = [ring(f["outline"]) for f in run[:N]]


def iou(poly, t):
    m = np.zeros((H, W), np.uint8)
    if poly is not None:
        cv2.fillPoly(m, [np.round(poly * 8).astype(np.int32)], 1, cv2.LINE_8, shift=3)
    u = (m.astype(bool) | t).sum()
    return 1.0 if u == 0 else float((m.astype(bool) & t).sum() / u)


def glide(old, new, alpha=0.5, fast=0.08):
    """OutlineMath.glide."""
    if old is None or len(old) != len(new):
        return new
    size = max(spread(old), 1e-6)
    co, cn = old.mean(axis=0), new.mean(axis=0)
    if np.linalg.norm(co - cn) / size >= 1:
        return new
    lined = align(new - cn, old - co)[0] + cn
    moved = affine_fit(old, lined)
    left = np.sqrt(np.mean(np.sum((lined - moved) ** 2, axis=1))) / size
    return moved + (lined - moved) * (alpha if left < fast else 1.0)


def moved(o, a, b):
    """o (on frame a) moved as the bottle moved from frame a to frame b."""
    if a == b or R[a] is None or R[b] is None:
        return o
    rb = align(R[b] - R[b].mean(axis=0), R[a] - R[a].mean(axis=0))[0] + R[b].mean(axis=0)
    m, *_ = np.linalg.lstsq(np.hstack([R[a], np.ones((64, 1))]), rb, rcond=None)
    return np.hstack([o, np.ones((len(o), 1))]) @ m


def play(every, late, carry):
    stored, at, pending, out = None, 0, None, []
    for g in range(N):
        if pending is not None and pending[1] <= g:
            f = pending[0]
            pending = None
            stored, at = (glide(moved(stored, at, f) if carry and stored is not None else stored, R[f]), f) if R[f] is not None else (None, f)
        if g == 0:
            stored, at = R[0], 0
        elif pending is None and g % every == 0:
            pending = (g, g + late)
        shown = (moved(stored, at, g) if carry else stored) if stored is not None else None
        out.append(iou(shown, truth[g]))
    o = np.array(out)
    return f"mean {o.mean():.4f}, worst {o.min():.4f} (frame {o.argmin()}), under 0.9: {(o < 0.9).sum()}"


print(f"timing: every frame, mean {np.mean([iou(R[g], truth[g]) for g in range(N)]):.4f}")
for every, late in pairs:
    print(f"timing: a look every {every} frames, each answer {late} late; moved exactly as the bottle moved: {play(every, late, True)}")
    print(f"timing: a look every {every} frames, each answer {late} late; not moved between answers: {play(every, late, False)}")
