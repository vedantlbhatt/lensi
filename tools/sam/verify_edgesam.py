"""Checks the converted EdgeSAM models against PyTorch on one image (macOS, real Core ML).

    python tools/sam/verify_edgesam.py --edgesam path/to/EdgeSAM --models build/edgesam --image some.jpg
"""
import argparse
import importlib.util
import os
import sys

import coremltools as ct
import numpy as np
import torch
from PIL import Image

ap = argparse.ArgumentParser()
ap.add_argument("--edgesam", required=True)
ap.add_argument("--models", required=True)
ap.add_argument("--image", required=True)
ap.add_argument("--compute-units", default="ALL")
a = ap.parse_args()

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("conv", os.path.join(here, "convert_edgesam.py"))
conv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(conv)
sys.path.insert(0, a.edgesam)
conv.stub_mm()
from edge_sam import sam_model_registry  # noqa: E402
from edge_sam.utils.coreml import SamCoreMLModel  # noqa: E402

sam = sam_model_registry["edge_sam"](checkpoint=None, upsample_mode="bilinear")
sam.load_state_dict(torch.load(os.path.join(a.edgesam, "weights", "edge_sam_3x.pth"), map_location="cpu"))
sam.eval()

img = Image.open(a.image).convert("RGB")
s = 1024 / max(img.size)
w, h = int(img.size[0] * s + 0.5), int(img.size[1] * s + 0.5)
canvas = Image.new("RGB", (1024, 1024), (124, 116, 104))
canvas.paste(img.resize((w, h), Image.BILINEAR), (0, 0))
x = torch.from_numpy(np.array(canvas)).permute(2, 0, 1)[None].float()

units = getattr(ct.ComputeUnit, a.compute_units)
enc = ct.models.MLModel(os.path.join(a.models, "LensiSAMEncoder.mlpackage"), compute_units=units)
dec = ct.models.MLModel(os.path.join(a.models, "LensiSAMDecoder.mlpackage"), compute_units=units)
emb_ml = enc.predict({"image": canvas})["image_embeddings"]
with torch.no_grad():
    emb_pt = conv.Encoder(sam)(x).numpy()
cos = float((emb_ml * emb_pt).sum() / np.linalg.norm(emb_ml) / np.linalg.norm(emb_pt))
print(f"encoder cosine {cos:.4f}")

wrapper = SamCoreMLModel(model=sam, use_stability_score=True).eval()
prompts = {
    "point": ([[0.5, 0.5]], [1]),
    "box": ([[0.3, 0.3], [0.7, 0.7]], [2, 3]),
    "box+point": ([[0.5, 0.5], [0.3, 0.3], [0.7, 0.7]], [1, 2, 3]),
}
worst = 1.0
for name, (pts, labels) in prompts.items():
    pc = np.zeros((1, 5, 2), np.float32)
    pl = -np.ones((1, 5), np.float32)
    for i, (p, l) in enumerate(zip(pts, labels)):
        pc[0, i] = [p[0] * w, p[1] * h]
        pl[0, i] = l
    out = dec.predict({"image_embeddings": emb_pt.astype(np.float32), "point_coords": pc, "point_labels": pl})
    with torch.no_grad():
        sc, mk = wrapper(torch.from_numpy(emb_pt), torch.from_numpy(pc), torch.from_numpy(pl))
    for k in range(4):
        m1, m2 = out["masks"][0, k] > 0, mk.numpy()[0, k] > 0
        if m2.mean() < 0.002:
            continue  # near-empty candidates flip on noise and are never used
        iou = (m1 & m2).sum() / max(1, (m1 | m2).sum())
        worst = min(worst, iou)
    print(f"{name}: scores ml {np.round(out['scores'][0], 3)} pt {np.round(sc.numpy()[0], 3)}")
print(f"worst decoder mask IoU {worst:.4f}")
sys.exit(0 if cos > 0.99 and worst > 0.95 else 1)
