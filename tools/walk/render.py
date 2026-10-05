"""Draws tools/walk's outlines on the real iPad frames, the way the phone draws them.

  render.py <scene dir> <name>.json <out dir>

The outlines are in the app's upright picture (the sensor image turned `.right`); the frames
are drawn as the iPad recorded them, turned so the room's up is up. Writes, top over bottom:

  <name>-before-after.mp4  the app before / now, pinned at the right depth
  <name>-far.mp4           before / now, both pinned 40% too far
  <name>-lidar.mp4         before / now with LiDAR, both pinned 40% too far
  <name>-depth.mp4         ARKit alone at a depth 40% off / at the right depth: what a wrong
                           depth does by itself as the camera moves
and <name>.mp4, the app now, bigger.
"""
import json
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "track"))
from render import OLD, PEN, caption, outline, writer  # noqa: E402

CAPTIONS = {
    "arkit@true": "ARKit alone, pinned at the right depth",
    "arkit@far": "ARKit alone, pinned 40% too far",
    "app@true": "Before",
    "app@far": "Before, pinned 40% too far",
    "lidar@far": "Before + LiDAR depth, pinned 40% too far",
    "steady@true": "Now",
    "steady@far": "Now, pinned 40% too far",
    "steadyl@far": "Now with LiDAR, pinned 40% too far",
    "clamp@true": "Now (up close, steadier)",
    "clampl@far": "Now with LiDAR (up close, steadier), pinned 40% too far",
    "sight@far": "Now, depth from lines of sight, pinned 40% too far",
    "sight@near": "Now, depth from lines of sight, pinned 30% too near",
    "edge@true": "EdgeTAM, pinned at the right depth",
    "edge@far": "EdgeTAM, depth from lines of sight, pinned 40% too far",
    "edgel@far": "EdgeTAM with LiDAR, pinned 40% too far",
}

PAIRS = [
    ("before-after", "app@true", "steady@true"),
    ("far", "app@far", "steady@far"),
    ("lidar", "app@far", "steadyl@far"),
    ("clamp", "app@true", "clamp@true"),
    ("sight", "steady@far", "sight@far"),
    ("edge", "steady@true", "edge@true"),
    ("edge-far", "steady@far", "edge@far"),
    ("depth", "arkit@far", "arkit@true"),
]


def main():
    scene, json_path, out_dir = sys.argv[1:4]
    os.makedirs(out_dir, exist_ok=True)
    data = json.load(open(json_path))
    name = data["name"]
    runs = {r["label"]: r for r in data["runs"]}
    distances = data.get("distances", [])
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

    def turn(flat):
        return [place(flat[i + 1], 1 - flat[i]) for i in range(0, len(flat) - 1, 2)]

    frames = [os.path.join(scene, "vga_wide", f) for f in data["frameNames"]]
    first = upright_frame(cv2.imread(frames[0]))
    h, w = first.shape[:2]
    fps = 30
    s = 2
    app = os.environ.get("WALK_APP", "steady@true")
    single = writer(os.path.join(out_dir, f"{name}.mp4"), w * s, h * s, fps)
    pairs = [(top, bottom, writer(os.path.join(out_dir, f"{name}-{tag}.mp4"), w, h * 2, fps))
             for tag, top, bottom in PAIRS if top in runs and bottom in runs]
    for i, path in enumerate(frames):
        img = cv2.imread(path)
        if img is None:
            continue
        img = upright_frame(img)
        away = f"{distances[i]:.1f} m away" if i < len(distances) else ""
        big = cv2.resize(img, (w * s, h * s), interpolation=cv2.INTER_CUBIC)
        big = outline(big, turn(runs[app]["outlines"][i]), PEN, 2.5 * s)
        big = caption(big, [f"{CAPTIONS[app]}: the {data['thing']}", away], size=13 * s)
        single.write(big)
        for top_label, bottom_label, out in pairs:
            top = outline(img.copy(), turn(runs[top_label]["outlines"][i]), OLD, 2)
            top = caption(top, [CAPTIONS[top_label], away], size=15)
            bottom = outline(img.copy(), turn(runs[bottom_label]["outlines"][i]), PEN, 2.5)
            bottom = caption(bottom, [CAPTIONS[bottom_label]], size=15)
            out.write(np.vstack([top, bottom]))
    single.release()
    for _, _, out in pairs:
        out.release()
    print(f"{name}: wrote {name}.mp4 and {len(pairs)} comparisons ({len(frames)} frames)")


if __name__ == "__main__":
    main()
