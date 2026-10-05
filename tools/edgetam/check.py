"""The split (parts.py) against EdgeTAM's own video predictor: the same frames, the same box, the
masks frame by frame. check.py <EdgeTAM repo> <frames dir> <reference masks dir> <x0,y0,x1,y1> [frames]"""
import glob
import os
import sys
import time

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

root, frames_dir, ref_dir, box_arg = sys.argv[1:5]
limit = int(sys.argv[5]) if len(sys.argv) > 5 else 10**9
sys.path.insert(0, root)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
torch.set_num_threads(4)
import parts  # noqa: E402

m = parts.load(root, os.path.join(root, "checkpoints/edgetam.pt"))
tracker = parts.Tracker(parts.EdgeTAMEncoder(m).eval(), parts.EdgeTAMPrompt(m).eval(), parts.EdgeTAMTrack(m).eval(),
                        parts.EdgeTAMMemory(m).eval())
files = sorted(glob.glob(os.path.join(frames_dir, "*.jpg")))[:limit]


def load(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    x = np.asarray(im.resize((parts.IMAGE, parts.IMAGE))) / 255.0
    return torch.from_numpy(x).permute(2, 0, 1)[None].float(), w, h


ious = []
with torch.inference_mode():
    for i, f in enumerate(files):
        image, w, h = load(f)
        t = time.time()
        if i == 0:
            x0, y0, x1, y1 = [float(v) for v in box_arg.split(",")]
            box = torch.tensor([[x0 / w * parts.IMAGE, y0 / h * parts.IMAGE, x1 / w * parts.IMAGE, y1 / h * parts.IMAGE]])
            mask, score = tracker.start(image, box)
        else:
            mask, score = tracker.step(image)
        ms = (time.time() - t) * 1000
        ours = (F.interpolate(mask, size=(h, w), mode="bilinear", align_corners=False)[0, 0] > 0).numpy()
        ref = np.asarray(Image.open(os.path.join(ref_dir, os.path.basename(f).replace(".jpg", ".png")))) > 127
        inter, union = (ours & ref).sum(), (ours | ref).sum()
        iou = 1.0 if union == 0 else inter / union
        ious.append(iou)
        if i % 25 == 0 or iou < 0.95:
            print(f"frame {i}: IoU with the official predictor {iou:.4f}, object score {float(score):.2f}, {ms:.0f} ms", flush=True)
print(f"{len(ious)} frames: mean IoU {np.mean(ious):.4f}, worst {np.min(ious):.4f} (frame {int(np.argmin(ious))})")
