"""EdgeTAM's own video predictor (PyTorch) on a folder of frames: the reference every other run
is held to. Seeded with a box on the first frame, propagated through all of them.

  reference.py <EdgeTAM repo> <frames dir> <out dir> <x0,y0,x1,y1 in pixels>

Writes <out>/<frame>.png (the mask, 0/255) and <out>/times.json.
"""
import json
import os
import sys
import time

import cv2
import numpy as np
import torch

root, frames, out, box_arg = sys.argv[1:5]
box = [float(v) for v in box_arg.split(",")]
sys.path.insert(0, root)
os.chdir(root)
from sam2.build_sam import build_sam2_video_predictor  # noqa: E402

torch.set_num_threads(max(1, os.cpu_count() or 4))
pred = build_sam2_video_predictor("edgetam.yaml", os.path.join(root, "checkpoints/edgetam.pt"), device="cpu")
os.makedirs(out, exist_ok=True)
names = sorted(f for f in os.listdir(frames) if f.endswith(".jpg"))
times = []
with torch.inference_mode():
    state = pred.init_state(video_path=frames, async_loading_frames=False)
    pred.add_new_points_or_box(state, frame_idx=0, obj_id=1, box=np.array(box, dtype=np.float32))
    t = time.time()
    for f, _, logits in pred.propagate_in_video(state):
        m = (logits[0, 0] > 0).cpu().numpy().astype(np.uint8) * 255
        cv2.imwrite(os.path.join(out, names[f].replace(".jpg", ".png")), m)
        now = time.time()
        times.append((now - t) * 1000)
        t = now
        if f % 50 == 0:
            print(f"reference frame {f}: {int((m > 0).sum())} px, {times[-1]:.0f} ms", flush=True)
json.dump({"ms": times}, open(os.path.join(out, "times.json"), "w"))
print(f"reference: {len(times)} frames, {np.mean(times):.0f} ms a frame (PyTorch, CPU)")
