"""Draws tools/pin's outlines on the real iPad frames, the way the phone draws them.

  render.py <scene dir> <name>.json <out dir>

The outlines are in the app's upright picture (the sensor image turned `.right`); the frames
are drawn as the iPad recorded them (sideways), so each point is turned back: (x, y) upright
is (y, 1 - x) in the recorded frame. Writes <name>.mp4 (the app), <name>-compare.mp4 (top: no
ARKit, SAM at a fixed place in the picture; bottom: the app), <name>-arkit-compare.mp4
(top: ARKit alone, one cut at the start; bottom: the app) and <name>-loose-compare.mp4 (top:
the app before the gate went by speed; bottom: the app).
"""
import json
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "track"))
from render import OLD, PEN, caption, outline, writer  # noqa: E402

CAPTIONS = {
    "fixed": "No ARKit: SAM at the same place in the picture",
    "arkit": "ARKit alone: cut once, pinned in the world",
    "coast@8": "ARKit + SAM 7.5/s, coasting between cuts",
    "loose@8": "Before: ARKit + SAM 7.5/s + point tracking, any cut taken",
    "strict@8": "ARKit + SAM 7.5/s + point tracking, strict",
    "lensi@8": "The app: ARKit + SAM 7.5/s + point tracking",
}


def main():
    scene, json_path, out_dir = sys.argv[1:4]
    os.makedirs(out_dir, exist_ok=True)
    data = json.load(open(json_path))
    name = data["name"]
    runs = {r["label"]: r for r in data["runs"]}
    # The iPad was held whichever way; turn each frame so the room's up is up (the harness
    # says where up points in the recorded image: x right, y up).
    ux, uy = data.get("upInImage", [0, 1])
    if abs(uy) >= abs(ux):
        quarter = 0 if uy > 0 else 2
    else:
        quarter = 3 if ux > 0 else 1  # clockwise quarter turns
    def upright_frame(img):
        for _ in range(quarter):
            img = cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
        return img
    def place(x, y):
        # A recorded-image point, after the same quarter turns.
        for _ in range(quarter):
            x, y = 1 - y, x
        return x, y
    turn = lambda flat: [place(flat[i + 1], 1 - flat[i]) for i in range(0, len(flat) - 1, 2)]
    frames = [os.path.join(scene, "vga_wide", f) for f in data["frameNames"]]
    first = upright_frame(cv2.imread(frames[0]))
    h, w = first.shape[:2]
    fps = 30
    s = 2
    single = writer(os.path.join(out_dir, f"{name}.mp4"), w * s, h * s, fps)
    pairs = {
        "compare": ("fixed", writer(os.path.join(out_dir, f"{name}-compare.mp4"), w, h * 2, fps)),
        "arkit-compare": ("arkit", writer(os.path.join(out_dir, f"{name}-arkit-compare.mp4"), w, h * 2, fps)),
        "loose-compare": ("loose@8", writer(os.path.join(out_dir, f"{name}-loose-compare.mp4"), w, h * 2, fps)),
    }
    app_label = os.environ.get("PIN_APP", "lensi@8")
    app = runs[app_label]
    for i, path in enumerate(frames):
        img = cv2.imread(path)
        if img is None:
            continue
        img = upright_frame(img)
        big = cv2.resize(img, (w * s, h * s), interpolation=cv2.INTER_CUBIC)
        big = outline(big, turn(app["outlines"][i]), PEN, 2.5 * s)
        big = caption(big, [f"{CAPTIONS[app_label]}: the {data['thing']}"], size=13 * s)
        single.write(big)
        for before, out in pairs.values():
            top = outline(img.copy(), turn(runs[before]["outlines"][i]), OLD, 2)
            top = caption(top, [CAPTIONS[before]], size=15)
            bottom = outline(img.copy(), turn(app["outlines"][i]), PEN, 2.5)
            bottom = caption(bottom, [CAPTIONS[app_label]], size=15)
            out.write(np.vstack([top, bottom]))
    single.release()
    for _, out in pairs.values():
        out.release()
    print(f"{name}: wrote {name}.mp4, {name}-compare.mp4, {name}-arkit-compare.mp4 ({len(frames)} frames)")


if __name__ == "__main__":
    main()
