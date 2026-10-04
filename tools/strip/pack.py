#!/usr/bin/env python3
"""Packs tools/strip's tracks for the app's virtual camera (app/assets/demo/video/<clip>.tracks.json).

  pack.py <strip.json> <out.json> [things, 8] [points, 24] [big, 0.12]

Keeps YOLO's things first, then SAM's parts (not the big background ones: a stretch of wall or
floor more than `big` of the picture), up to `things`; each outline is resampled to
`points` points and stored as uint16 x,y pairs (0-65535 across the picture), frame after frame
from the frame it was found, base64. The virtual camera decodes it (VirtualCamera.tsx).
"""
import base64
import json
import math
import struct
import sys


def resample(pts, n):
    """n points evenly spaced along the closed outline."""
    ring = pts + pts[:1]
    seg = [math.dist(ring[i], ring[i + 1]) for i in range(len(pts))]
    total = sum(seg) or 1.0
    out, i, acc = [], 0, 0.0
    for k in range(n):
        target = total * k / n
        while i < len(seg) - 1 and acc + seg[i] < target:
            acc += seg[i]
            i += 1
        t = 0.0 if seg[i] == 0 else (target - acc) / seg[i]
        a, b = ring[i], ring[i + 1]
        out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out


def area(o):
    pts = [(o[j], o[j + 1]) for j in range(0, len(o), 2)]
    return abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(pts, pts[1:] + pts[:1]))) / 2


def main():
    src, dst = sys.argv[1], sys.argv[2]
    keep = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 24
    big = float(sys.argv[5]) if len(sys.argv) > 5 else 0.12
    tr = json.load(open(src))
    parts = [t for t in tr["things"] if not t["label"] and area(t["outlines"][t["start"]]) <= big]
    order = [t for t in tr["things"] if t["label"]] + parts
    things = []
    for th in order[:keep]:
        start = th["start"]
        data = bytearray()
        for o in th["outlines"][start:]:
            if not o:
                raise SystemExit(f"{src}: a gap in a track after it starts")
            pts = resample([(o[j], o[j + 1]) for j in range(0, len(o), 2)], n)
            for x, y in pts:
                data += struct.pack("<HH", round(min(max(x, 0), 1) * 65535), round(min(max(y, 0), 1) * 65535))
        things.append({"label": th["label"], "start": start, "data": base64.b64encode(bytes(data)).decode()})
    out = {"clip": tr["clip"], "fps": tr["fps"], "frames": tr["frames"], "size": tr["size"], "every": tr["every"], "points": n, "things": things}
    with open(dst, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"{dst}: {len(things)} things, {sum(len(t['data']) for t in things) // 1024} KB")


if __name__ == "__main__":
    main()
