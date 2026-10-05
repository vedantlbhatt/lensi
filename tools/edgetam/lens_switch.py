"""A lens switch on the bottle clip, simulated: '1x' frames are the clip's centre half blown up
to the full size, '0.5x' frames the clip as it is. The tracker (parts.Tracker, the app's loop)
follows the bottle across an instant switch, as the app's 0.5x mode does when it swaps cameras,
three ways: keep stepping (its memory from the other lens), restart from the last mask's box
mapped into the new picture, or re-prompt on the new picture but keep the recent memory. IoU
against EdgeTAM's own run on the unzoomed clip, mapped into whichever picture each frame is.

  lens_switch.py <EdgeTAM repo> <frames dir> <reference masks dir> <out.json>

Keeping the memory came out best both ways (README: "Across the switch to 0.5x")."""
import json
import os
import sys

import cv2
import numpy as np
import torch
import torch.nn.functional as F

ROOT, FRAMES, REF, OUT = (os.path.abspath(a) for a in sys.argv[1:5])
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
torch.set_num_threads(8)
import parts  # noqa: E402
m = parts.load(ROOT, f"{ROOT}/checkpoints/edgetam.pt")
E, P, T, M = parts.EdgeTAMEncoder(m).eval(), parts.EdgeTAMPrompt(m).eval(), parts.EdgeTAMTrack(m).eval(), parts.EdgeTAMMemory(m).eval()
W, H = 540, 960
def frame(i): return cv2.cvtColor(cv2.imread(os.path.join(FRAMES, f"{i:05d}.jpg")), cv2.COLOR_BGR2RGB)
def ref(i): return cv2.imread(os.path.join(REF, f"{i:05d}.png"), 0) > 127
def crop(img, interp):  # centre half, blown up 2x
    c = img[H // 4: H // 4 + H // 2, W // 4: W // 4 + W // 2]
    return cv2.resize(c.astype(np.uint8), (W, H), interpolation=interp)
def tensor(img):
    x = cv2.resize(img, (1024, 1024), interpolation=cv2.INTER_LINEAR) / 255.0
    return torch.from_numpy(x).permute(2, 0, 1)[None].float()
def to_mask(logits): return (F.interpolate(logits, size=(H, W), mode="bilinear", align_corners=False)[0, 0] > 0).numpy()
def box_of(mask):
    ys, xs = np.nonzero(mask)
    return np.array([xs.min(), ys.min(), xs.max() + 1, ys.max() + 1], np.float64)
def to_zoomed(b):  # full-frame pixel box -> 1x picture
    return (b - [W / 4, H / 4, W / 4, H / 4]) * 2
def to_wide(b):  # 1x picture -> full frame
    return b / 2 + [W / 4, H / 4, W / 4, H / 4]
def tbox(b): return torch.tensor([[b[0] / W * 1024, b[1] / H * 1024, b[2] / W * 1024, b[3] / H * 1024]], dtype=torch.float32)
def iou(a, b):
    u = (a | b).sum()
    return 1.0 if u == 0 else float((a & b).sum() / u)

def run(first, last, switch, start_zoomed, how):
    """Frames first..last; the lens switches before frame `switch`."""
    t = parts.Tracker(E, P, T, M)
    out = []
    zoomed = start_zoomed
    with torch.inference_mode():
        for i in range(first, last + 1):
            if i == switch:
                zoomed = not zoomed
            img = frame(i)
            truth = ref(i)
            if zoomed:
                img = crop(img, cv2.INTER_LINEAR)
                truth = crop(truth.astype(np.uint8) * 255, cv2.INTER_LINEAR) > 127
            x = tensor(img)
            if i == first:
                b = box_of(truth)
                mask, score = t.start(x, tbox(b))
            elif i == switch and how != "keep":
                b = box_of(prev)  # the last mask, in the old picture
                b = to_wide(b) if not zoomed else to_zoomed(b)
                b = np.clip(b, 0, [W, H, W, H])
                if how == "restart":
                    mask, score = t.start(x, tbox(b))
                else:  # re-prompt, keep the recent frames
                    recent, ptrs = t.recent, t.ptrs
                    mask, score = t.start(x, tbox(b))
                    t.recent, t.ptrs = recent, ptrs
            else:
                mask, score = t.step(x)
            prev = to_mask(mask)
            out.append(iou(prev, truth))
    return out

res = {}
for (a, b) in [(447, 502), (315, 353)]:
    sw = (a + b) // 2
    for start_zoomed, name in [(True, "1x->0.5x"), (False, "0.5x->1x")]:
        for how in ["keep", "restart", "recond"]:
            r = run(a, b, sw, start_zoomed, how)
            after = r[sw - a:]
            key = f"{a}-{b} {name} {how}"
            res[key] = r
            print(f"{key}: before the switch mean {np.mean(r[:sw - a]):.4f}; after: first {after[0]:.4f}, next 5 mean {np.mean(after[:5]):.4f}, all after mean {np.mean(after):.4f}, worst {min(after):.4f}", flush=True)
json.dump(res, open(OUT, "w"))
