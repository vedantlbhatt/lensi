"""Which frame of the full-rate footage each frame of a clip made from it shows: the one it
differs from least, of the two or three around where its time puts it. A phone's video can stamp
its frames unevenly (round a lens switch, say), so a 15 fps clip cut from 30 fps footage isn't
always every other frame of it, and a track packed by time alone (pack.py) lags the picture there.

  match.py <clip.mp4> <full-rate frames dir> <out.json> [full-rate fps, 30]

Writes a list: for clip frame k, the full-rate frame it shows (for PACK_MATCH, pack.py).
"""
import json
import os
import sys

import cv2
import numpy as np

clip_path, frames_dir, out = sys.argv[1:4]
full_fps = float(sys.argv[4]) if len(sys.argv) > 4 else 30.0
cap = cv2.VideoCapture(clip_path)
clip_fps = cap.get(cv2.CAP_PROP_FPS) or 15.0
names = sorted(f for f in os.listdir(frames_dir) if f.endswith(".jpg"))
step = full_fps / clip_fps
match = []
k = 0
while True:
    ok, f = cap.read()
    if not ok:
        break
    g = cv2.cvtColor(f, cv2.COLOR_BGR2GRAY).astype(np.float32)
    h, w = g.shape
    at = round(k * step)
    best, err = at, None
    for i in range(at - 1, at + 2):
        if not 0 <= i < len(names):
            continue
        b = cv2.imread(os.path.join(frames_dir, names[i]), cv2.IMREAD_GRAYSCALE)
        b = cv2.resize(b, (w, h), interpolation=cv2.INTER_AREA).astype(np.float32)
        e = float(np.mean(np.abs(g - b)))
        if err is None or e < err:
            best, err = i, e
    match.append(best)
    k += 1
moved = sum(1 for k, i in enumerate(match) if i != round(k * step))
json.dump(match, open(out, "w"))
print(f"{out}: {len(match)} clip frames, {moved} of them show a frame other than their time says")
