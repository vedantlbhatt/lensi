"""EdgeSAM (github.com/chongzhou96/EdgeSAM, S-Lab License 1.0: non-commercial) -> Core ML,
as drop-in replacements for LensiSAMEncoder / LensiSAMDecoder (same names, inputs and outputs;
see README.md "Model I/O"). EdgeSAM's encoder is a RepViT CNN that runs entirely on the Neural
Engine (~12 ms on an M3), where MobileSAM's TinyViT falls back to the GPU (~40 ms).

    git clone https://github.com/chongzhou96/EdgeSAM && cd EdgeSAM && git checkout d24d996
    curl -LO --create-dirs --output-dir weights \
      https://huggingface.co/spaces/chongzhou/EdgeSAM/resolve/main/weights/edge_sam_3x.pth
    python tools/sam/convert_edgesam.py --edgesam path/to/EdgeSAM --out build/edgesam

Decoder scores are SAM's stability score (EdgeSAM did not distil the IoU head, so its own
predicted IoU is unreliable): fraction of the mask that survives a +-1 logit threshold shift.
"""
import argparse
import os
import sys
import types

import coremltools as ct
import torch
import torch.nn as nn

SLOTS = 5
MEAN = [123.675, 116.28, 103.53]
STD = [58.395, 57.12, 57.375]


def stub_mm():
    # EdgeSAM imports mmdet/mmengine for its optional RPN head only.
    for name in ["mmdet", "mmdet.models", "mmdet.models.dense_heads", "mmdet.models.necks", "mmengine",
                 "projects", "projects.EfficientDet", "projects.EfficientDet.efficientdet"]:
        m = types.ModuleType(name)
        m.RPNHead = m.CenterNetUpdateHead = m.FPN = m.ConfigDict = object
        m.EfficientDet = m.efficientdet = m
        sys.modules[name] = m


class Encoder(nn.Module):
    def __init__(self, sam):
        super().__init__()
        self.encoder = sam.image_encoder
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("inv_std", 1 / torch.tensor(STD).view(1, 3, 1, 1))

    def forward(self, image):
        return self.encoder((image - self.mean) * self.inv_std)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--edgesam", required=True)
    ap.add_argument("--weights", default=None)
    ap.add_argument("--out", required=True)
    ap.add_argument("--decoder-fp16", action="store_true", help="float16 decoder (runs on the Neural Engine)")
    a = ap.parse_args()
    sys.path.insert(0, a.edgesam)
    stub_mm()
    from edge_sam import sam_model_registry
    from edge_sam.utils.coreml import SamCoreMLModel

    weights = a.weights or os.path.join(a.edgesam, "weights", "edge_sam_3x.pth")
    sam = sam_model_registry["edge_sam"](checkpoint=None, upsample_mode="bilinear")
    state = torch.load(weights, map_location="cpu")
    sam.load_state_dict(state.get("model", state) if isinstance(state, dict) else state, strict=True)
    sam.eval()
    os.makedirs(a.out, exist_ok=True)

    enc = Encoder(sam).eval()
    x = torch.rand(1, 3, 1024, 1024) * 255
    traced = torch.jit.trace(enc, x)
    m = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=x.shape, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="image_embeddings", dtype=float)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
    )
    m.short_description = "EdgeSAM-3x image encoder (Lensi drop-in for LensiSAMEncoder)"
    m.save(os.path.join(a.out, "LensiSAMEncoder.mlpackage"))

    dec = SamCoreMLModel(model=sam, use_stability_score=True).eval()
    emb = torch.randn(1, 256, 64, 64)
    pc = torch.randint(0, 1024, (1, SLOTS, 2)).float()
    pl = torch.tensor([[1, 2, 3, -1, -1]]).float()
    traced = torch.jit.trace(dec, [emb, pc, pl])
    m = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="image_embeddings", shape=emb.shape, dtype=float),
            ct.TensorType(name="point_coords", shape=pc.shape, dtype=float),
            ct.TensorType(name="point_labels", shape=pl.shape, dtype=float),
        ],
        outputs=[ct.TensorType(name="scores", dtype=float), ct.TensorType(name="masks", dtype=float)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        # float16 shifts the small-mask logits enough to change which candidate wins.
        compute_precision=ct.precision.FLOAT16 if a.decoder_fp16 else ct.precision.FLOAT32,
    )
    m.short_description = "EdgeSAM-3x prompt encoder + mask decoder (Lensi drop-in for LensiSAMDecoder)"
    m.save(os.path.join(a.out, "LensiSAMDecoder.mlpackage"))
    print("wrote", a.out)


if __name__ == "__main__":
    main()
