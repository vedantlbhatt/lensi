"""Frames start..end (exclusive) of a video, as numbered JPEGs: frames.py <video> <out dir> <start> <end>"""
import os
import sys

import cv2

src, out, start, end = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
os.makedirs(out, exist_ok=True)
cap = cv2.VideoCapture(src)
cap.set(cv2.CAP_PROP_POS_FRAMES, start)
n = 0
for i in range(start, end):
    ok, img = cap.read()
    if not ok:
        break
    cv2.imwrite(os.path.join(out, f"{i:05d}.jpg"), img, [cv2.IMWRITE_JPEG_QUALITY, 95])
    n += 1
print(f"{src}: {n} frames to {out}")
