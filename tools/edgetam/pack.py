"""Packs tools/edgetrack's outlines for the app's virtual camera (tools/strip/pack.py's format,
app/assets/demo/video/<clip>.tracks.json): the clip's frames at its own rate, each outline
resampled to `points` points as uint16 x,y pairs, base64.

  pack.py <edgetrack.json> <out.json> <clip> <label> <clip fps> <clip frames> <width> <height> [key, shown] [points, 64]

The run is on the full-rate frames; clip frame k is the run's frame round(k * run fps / clip fps)
(the run at 30 fps, the clip at 15: every other one).
"""
import base64
import json
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "strip"))
from pack import resample  # noqa: E402

src, dst, clip, label = sys.argv[1:5]
fps, frames, width, height = float(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]), int(sys.argv[8])
key = sys.argv[9] if len(sys.argv) > 9 else "shown"
n = int(sys.argv[10]) if len(sys.argv) > 10 else 64
run = json.load(open(src))["frames"]
step = 30.0 / fps
data = bytearray()
last = None
for k in range(frames):
    f = run[min(len(run) - 1, round(k * step))]
    o = f.get(key) or []
    if len(o) >= 6:
        # Evenly spaced in pixels, not in fractions of a tall picture.
        pts = [(o[j] * width, o[j + 1] * height) for j in range(0, len(o), 2)]
        last = [(x / width, y / height) for x, y in resample(pts, n)]
    if last is None:
        raise SystemExit(f"{src}: nothing at frame {k}")
    for x, y in last:
        data += struct.pack("<HH", round(min(max(x, 0), 1) * 65535), round(min(max(y, 0), 1) * 65535))
out = {"clip": clip, "fps": int(fps), "frames": frames, "size": [width, height], "every": 1, "points": n,
       "things": [{"label": label, "start": 0, "data": base64.b64encode(bytes(data)).decode()}]}
with open(dst, "w") as fh:
    json.dump(out, fh, separators=(",", ":"))
print(f"{dst}: {frames} frames of {label}, {len(out['things'][0]['data']) // 1024} KB")
