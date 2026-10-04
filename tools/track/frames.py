"""Frames of a video as numbered JPEGs.

  frames.py <video> <out dir> <start> <end> [step] [width]

start..end (exclusive) in the video's own frames, every `step`-th one, resized to
`width` pixels wide (aspect kept) when given.
"""
import os
import sys

import cv2

src, out, start, end = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
step = int(sys.argv[5]) if len(sys.argv) > 5 else 1
width = int(sys.argv[6]) if len(sys.argv) > 6 else 0
os.makedirs(out, exist_ok=True)
cap = cv2.VideoCapture(src)
# Read from the start rather than seeking: seeking compressed video can land on another frame,
# and then the seed box (measured on the real frame) is on the wrong thing.
n = 0
for i in range(end):
    ok, img = cap.read()
    if not ok:
        break
    if i < start or (i - start) % step:
        continue
    if width and img.shape[1] != width:
        img = cv2.resize(img, (width, round(img.shape[0] * width / img.shape[1])), interpolation=cv2.INTER_AREA)
    cv2.imwrite(os.path.join(out, f"{i:05d}.jpg"), img, [cv2.IMWRITE_JPEG_QUALITY, 95])
    n += 1
print(f"{src}: {n} frames to {out}")
