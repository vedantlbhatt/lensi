"""The four Core ML models (convert.py) run through parts.Tracker -- the loop the app's Swift
runs -- against the reference masks (reference.py), on a Mac.

  check_coreml.py <EdgeTAM repo> <mlpackage dir> <frames dir> <reference dir> <x0,y0,x1,y1> <out.json>
                  [CPU_ONLY | CPU_AND_GPU | CPU_AND_NE | ALL]

Prints the IoU with the reference frame by frame (every 25th, and any under 0.9) and how long
each model takes; writes the lot to out.json.
"""
import json
import os
import sys
import time

import coremltools as ct
import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

root, models, frames_dir, ref_dir, box_arg, out_path = sys.argv[1:7]
units = getattr(ct.ComputeUnit, sys.argv[7] if len(sys.argv) > 7 else "ALL")
sys.path.insert(0, root)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
import parts  # noqa: E402

timings = {"encoder": [], "prompt": [], "track": [], "memory": []}


def model(name):
    t = time.time()
    m = ct.models.MLModel(os.path.join(models, f"{name}.mlpackage"), compute_units=units)
    print(f"{name}: loaded in {time.time() - t:.1f} s", flush=True)
    return m


enc, prm, trk, mem = (model(n) for n in ("EdgeTAMEncoder", "EdgeTAMPrompt", "EdgeTAMTrack", "EdgeTAMMemory"))


def run(key, m, inputs):
    t = time.time()
    out = m.predict({k: (v.numpy().astype(np.float32) if torch.is_tensor(v) else v) for k, v in inputs.items()})
    timings[key].append((time.time() - t) * 1000)
    return out


def t(a):
    return torch.from_numpy(np.asarray(a, dtype=np.float32))


def encoder(image):
    o = run("encoder", enc, {"image": image})
    return t(o["features"]), t(o["high0"]), t(o["high1"])


def heads(o):
    return t(o["masks"]), t(o["ious"]), t(o["pointers"]), t(o["score"])


def prompt(features, high0, high1, box):
    return heads(run("prompt", prm, {"features": features, "high0": high0, "high1": high1, "box": box}))


def track(features, high0, high1, memory, memory_valid, ptrs, ptr_valid):
    return heads(run("track", trk, {"features": features, "high0": high0, "high1": high1, "memory": memory,
                                    "memory_valid": memory_valid, "pointers_in": ptrs, "pointer_valid": ptr_valid}))


def memory(features, mask, binarize):
    return t(run("memory", mem, {"features": features, "mask": mask, "binarize": binarize})["memory"])


tracker = parts.Tracker(encoder, prompt, track, memory)
files = sorted(f for f in os.listdir(frames_dir) if f.endswith(".jpg"))
ious, scores, areas = [], [], []
for i, name in enumerate(files):
    im = Image.open(os.path.join(frames_dir, name)).convert("RGB")
    w, h = im.size
    image = im.resize((parts.IMAGE, parts.IMAGE))
    if i == 0:
        x0, y0, x1, y1 = [float(v) for v in box_arg.split(",")]
        s = parts.IMAGE
        mask, score = tracker.start(image, torch.tensor([[x0 / w * s, y0 / h * s, x1 / w * s, y1 / h * s]]))
    else:
        mask, score = tracker.step(image)
    ours = (F.interpolate(mask, size=(h, w), mode="bilinear", align_corners=False)[0, 0] > 0).numpy()
    ref = np.asarray(Image.open(os.path.join(ref_dir, name.replace(".jpg", ".png")))) > 127
    inter, union = (ours & ref).sum(), (ours | ref).sum()
    iou = 1.0 if union == 0 else float(inter / union)
    ious.append(iou)
    scores.append(float(score))
    areas.append(float(ours.mean()))
    if i % 25 == 0 or iou < 0.9:
        print(f"frame {i}: IoU with the reference {iou:.4f}, object score {float(score):.2f}, area {ours.mean():.4f}", flush=True)

summary = {name: {"median_ms": float(np.median(v)), "mean_ms": float(np.mean(v)), "runs": len(v)}
           for name, v in timings.items() if v}
result = {"units": str(units), "frames": len(ious), "mean_iou": float(np.mean(ious)), "worst_iou": float(np.min(ious)),
          "worst_frame": int(np.argmin(ious)), "under_0.9": int(sum(1 for v in ious if v < 0.9)),
          "under_0.5": int(sum(1 for v in ious if v < 0.5)), "timings": summary,
          "ious": ious, "scores": scores, "areas": areas}
json.dump(result, open(out_path, "w"))
print(f"Core ML ({units}): {len(ious)} frames, mean IoU {result['mean_iou']:.4f}, worst {result['worst_iou']:.4f} "
      f"(frame {result['worst_frame']}), {result['under_0.9']} under 0.9, {result['under_0.5']} under 0.5")
for name, v in summary.items():
    print(f"  {name}: median {v['median_ms']:.1f} ms over {v['runs']} runs")
