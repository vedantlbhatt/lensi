"""EdgeTAM's four parts (parts.py) to Core ML: convert.py <EdgeTAM repo> <out dir>

Writes EdgeTAMEncoder, EdgeTAMPrompt, EdgeTAMTrack and EdgeTAMMemory .mlpackage (ML Program,
iOS 17, float16), for `xcrun coremlcompiler compile` into the app's Models/. Runs anywhere
coremltools does (the conversion doesn't load the models; checking them needs a Mac: check_coreml.py).
EDGETAM_WEIGHTS=int8 stores the weights in 8 bits a value with a scale per output channel (half
the size; Core ML turns them back into float16 as it loads them).
"""
import os
import sys

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch

root, out_dir = sys.argv[1:3]
sys.path.insert(0, root)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
import parts  # noqa: E402

os.makedirs(out_dir, exist_ok=True)
m = parts.load(root, os.path.join(root, "checkpoints/edgetam.pt"))
on_mac = sys.platform == "darwin"
weights = os.environ.get("EDGETAM_WEIGHTS", "float16")

F = parts.FEAT
features = torch.randn(1, 256, F, F)
high0 = torch.randn(1, 32, 4 * F, 4 * F)
high1 = torch.randn(1, 64, 2 * F, 2 * F)
feature_inputs = [
    ct.TensorType(name="features", shape=features.shape),
    ct.TensorType(name="high0", shape=high0.shape),
    ct.TensorType(name="high1", shape=high1.shape),
]
heads_outputs = [ct.TensorType(name=n) for n in ("masks", "ious", "pointers", "score")]


def convert(name, module, example, inputs, outputs):
    module = module.eval()
    with torch.no_grad():
        traced = torch.jit.trace(module, example, strict=False)
        ref = module(*example)
    mlmodel = ct.convert(
        traced,
        inputs=inputs,
        outputs=outputs,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        skip_model_load=not on_mac,
    )
    if weights == "int8":
        config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int8", granularity="per_channel", weight_threshold=2048))
        mlmodel = cto.linear_quantize_weights(mlmodel, config=config)
    mlmodel.author = "EdgeTAM (Meta, Apache 2.0), split for Lensi: tools/edgetam"
    mlmodel.short_description = name
    path = os.path.join(out_dir, f"{name}.mlpackage")
    mlmodel.save(path)
    shapes = [tuple(r.shape) for r in (ref if isinstance(ref, (tuple, list)) else [ref])]
    print(f"{name}: {path}, outputs {shapes}", flush=True)
    return mlmodel


convert(
    "EdgeTAMEncoder",
    parts.EdgeTAMEncoder(m),
    (torch.rand(1, 3, parts.IMAGE, parts.IMAGE),),
    [ct.ImageType(name="image", shape=(1, 3, parts.IMAGE, parts.IMAGE), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
    [ct.TensorType(name=n) for n in ("features", "high0", "high1")],
)
convert(
    "EdgeTAMPrompt",
    parts.EdgeTAMPrompt(m),
    (features, high0, high1, torch.tensor([[300.0, 400.0, 600.0, 800.0]])),
    feature_inputs + [ct.TensorType(name="box", shape=(1, 4))],
    heads_outputs,
)
memory = torch.randn(1, parts.NUM_MEM * parts.MEM_TOKENS, parts.MEM_DIM)
memory_valid = torch.ones(1, parts.NUM_MEM)
ptrs = torch.randn(1, parts.NUM_PTRS, 256)
ptr_valid = torch.ones(1, parts.NUM_PTRS)
convert(
    "EdgeTAMTrack",
    parts.EdgeTAMTrack(m),
    (features, high0, high1, memory, memory_valid, ptrs, ptr_valid),
    feature_inputs
    + [
        ct.TensorType(name="memory", shape=memory.shape),
        ct.TensorType(name="memory_valid", shape=memory_valid.shape),
        ct.TensorType(name="pointers_in", shape=ptrs.shape),
        ct.TensorType(name="pointer_valid", shape=ptr_valid.shape),
    ],
    heads_outputs,
)
convert(
    "EdgeTAMMemory",
    parts.EdgeTAMMemory(m),
    (features, torch.randn(1, 1, 4 * F, 4 * F), torch.zeros(1, 1)),
    [ct.TensorType(name="features", shape=features.shape), ct.TensorType(name="mask", shape=(1, 1, 4 * F, 4 * F)),
     ct.TensorType(name="binarize", shape=(1, 1))],
    [ct.TensorType(name="memory")],
)
