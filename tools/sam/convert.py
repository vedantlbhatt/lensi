#!/usr/bin/env python3
"""Convert MobileSAM (TinyViT encoder + SAM prompt encoder / mask decoder) to the two Core ML
models SAMSegmenter.swift runs.

    python tools/sam/convert.py --out /path/to/out

Writes LensiSAMEncoder.mlpackage and LensiSAMDecoder.mlpackage (ML Program, float16 compute and
weights, iOS 17, fixed shapes). Compile on macOS for the app's resource bundle with
`xcrun coremlcompiler compile <name>.mlpackage app/modules/lensi-ar/ios/Models/`.

MobileSAM source and weights are downloaded from GitHub at a pinned commit (weights are checked
against a sha256) into --cache, never into the repo.

Encoder  image [1,3,1024,1024] RGB 0-255 (ImageType)  -> image_embeddings [1,256,64,64] fp32
Decoder  image_embeddings [1,256,64,64], point_coords [1,5,2], point_labels [1,5]  (all fp32)
         -> masks [1,4,256,256] low-res logits, scores [1,4] predicted IoU (fp32)
"""

from __future__ import annotations

import argparse
import copy
import math
import os
import shutil
import sys
import time
import types

import numpy as np
import torch
import torch.nn.functional as F
from torch import nn

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sam_common as sc  # noqa: E402

MOBILE_SAM_REPO = "ChaoningZhang/MobileSAM"
MOBILE_SAM_COMMIT = "f706ad9c4eb7f219c00d9050e46328518ffb65d2"
MOBILE_SAM_WEIGHTS = "weights/mobile_sam.pt"
MOBILE_SAM_WEIGHTS_SHA256 = "6dbb90523a35330fedd7f1d3dfc66f995213d81b29a5ca8108dbcdd4e37d6c2f"
MOBILE_SAM_SOURCES = [
    "__init__.py", "build_sam.py", "predictor.py", "automatic_mask_generator.py",
    "modeling/__init__.py", "modeling/common.py", "modeling/image_encoder.py",
    "modeling/mask_decoder.py", "modeling/prompt_encoder.py", "modeling/sam.py",
    "modeling/tiny_vit_sam.py", "modeling/transformer.py",
    "utils/__init__.py", "utils/transforms.py", "utils/onnx.py", "utils/amg.py",
]
DEFAULT_CACHE = os.environ.get("LENSI_SAM_CACHE", os.path.expanduser("~/.cache/lensi-sam"))
ENCODER_NAME = "LensiSAMEncoder"
DECODER_NAME = "LensiSAMDecoder"
# Additive attention bias that hides surplus padding tokens (see DecoderWrapper). Large enough
# that exp() underflows to exactly 0, small enough to stay finite in float16.
MASKED_TOKEN_BIAS = -1.0e4


# --------------------------------------------------------------------------------------------
# MobileSAM download + build


def _raw_url(path: str) -> str:
    return f"https://raw.githubusercontent.com/{MOBILE_SAM_REPO}/{MOBILE_SAM_COMMIT}/{path}"


def fetch_mobile_sam(cache: str = DEFAULT_CACHE) -> tuple[str, str]:
    """Returns (directory containing the `mobile_sam` package, weights path)."""
    root = os.path.join(cache, f"MobileSAM-{MOBILE_SAM_COMMIT[:12]}")
    for rel in MOBILE_SAM_SOURCES:
        sc.fetch(_raw_url(f"mobile_sam/{rel}"), os.path.join(root, "mobile_sam", rel))
    weights = sc.fetch(_raw_url(MOBILE_SAM_WEIGHTS), os.path.join(root, MOBILE_SAM_WEIGHTS),
                       MOBILE_SAM_WEIGHTS_SHA256)
    return root, weights


def load_mobile_sam(cache: str = DEFAULT_CACHE):
    """The unmodified MobileSAM `Sam` module in eval mode, float32, on CPU."""
    root, weights = fetch_mobile_sam(cache)
    if root not in sys.path:
        sys.path.insert(0, root)
    import warnings

    with warnings.catch_warnings():  # timm's deprecated-import warnings
        warnings.simplefilter("ignore")
        from mobile_sam import sam_model_registry

        sam = sam_model_registry["vit_t"]()
    state = torch.load(weights, map_location="cpu", weights_only=True)
    sam.load_state_dict(state)
    return sam.eval()


# --------------------------------------------------------------------------------------------
# Patches that keep the graph inside what Core ML (and float16) can do. Each one computes the
# same function as the original; evaluate.py checks that against the unpatched model.

# Power-of-two input scale for LayerNorms whose sum((x - mean)^2) leaves float16 range.
# LayerNorm(x * s, eps * s^2) == LayerNorm(x, eps), and scaling by 2^-5 is exact in fp16/fp32.
# Measured over the evaluation images plus flat / noise / black / white canvases: that sum
# reaches 1.0e6 in TinyViT layer 3's attention norms and 2.1e6 in the neck (single squares up
# to 3.9e5), while float16 tops out at 65504. Unpatched, the neck's pow() overflows to inf at
# every position and the fp16 model returns garbage. After scaling the sums stay below ~2.1e3
# and the smallest per-token variance (5.7, resp. 39) stays far above fp16's normal range.
LN_PRESCALE = 1.0 / 32


def _layer_norm(norm: nn.LayerNorm, x: torch.Tensor, prescale: float) -> torch.Tensor:
    if prescale == 1.0:
        return norm(x)
    return F.layer_norm(x * prescale, norm.normalized_shape, norm.weight, norm.bias,
                        norm.eps * prescale * prescale)


def _tinyvit_attention(attn, x):
    """TinyViT Attention.forward without its leading LayerNorm (the block applies it)."""
    B, N, _ = x.shape
    qkv = attn.qkv(x)
    q, k, v = qkv.view(B, N, attn.num_heads, -1).split([attn.key_dim, attn.key_dim, attn.d], dim=3)
    q = q.permute(0, 2, 1, 3)
    k = k.permute(0, 2, 1, 3)
    v = v.permute(0, 2, 1, 3)
    logits = (q @ k.transpose(-2, -1)) * attn.scale + attn.ab
    out = (logits.softmax(dim=-1) @ v).transpose(1, 2).reshape(B, N, attn.dh)
    return attn.proj(out)


def _tinyvit_block_forward(self, x):
    """TinyViTBlock.forward, rearranged for Core ML. Two changes, same function:

    1. Window partition/reverse on rank-5 tensors. The original views x as
       (B, nH, ws, nW, ws, C), rank 6, and Core ML tops out at rank 5. Folding B into nH keeps
       the memory order, so it is bit-identical.
    2. The attention LayerNorm runs before window padding. The original pads with zero tokens
       and normalises them inside Attention, which maps each one to exactly norm.bias; in float16
       that result hinges on eps=1e-5 surviving as a subnormal (0/0 = NaN if it is flushed).
       Here the real tokens are normalised and the padding is filled with norm.bias directly.
    """
    H, W = self.input_resolution
    B, L, C = x.shape
    assert L == H * W, "input feature has wrong size"
    res_x = x
    ws = self.window_size
    norm = self.attn.norm
    x = _layer_norm(norm, x, getattr(self, "lensi_ln_prescale", 1.0))
    if H == ws and W == ws:
        x = _tinyvit_attention(self.attn, x)
    else:
        x = x.view(B, H, W, C)
        pad_b = (ws - H % ws) % ws
        pad_r = (ws - W % ws) % ws
        padding = pad_b > 0 or pad_r > 0
        if padding:
            # Pad with norm.bias: shift so the zero fill lands on it. Avoids a large constant.
            x = F.pad(x - norm.bias, (0, 0, 0, pad_r, 0, pad_b)) + norm.bias
        pH, pW = H + pad_b, W + pad_r
        nH, nW = pH // ws, pW // ws
        x = x.reshape(B * nH, ws, nW, ws, C).transpose(1, 2).reshape(B * nH * nW, ws * ws, C)
        x = _tinyvit_attention(self.attn, x)
        x = x.reshape(B * nH, nW, ws, ws, C).transpose(1, 2).reshape(B, pH, pW, C)
        if padding:
            x = x[:, :H, :W].contiguous()
        x = x.reshape(B, L, C)
    x = res_x + self.drop_path(x)
    x = x.transpose(1, 2).reshape(B, C, H, W)
    x = self.local_conv(x)
    x = x.view(B, C, L).transpose(1, 2)
    x = x + self.drop_path(self.mlp(x))
    return x


def _layernorm2d_forward(self, x):
    """common.LayerNorm2d.forward on x * prescale with eps * prescale^2 (see LN_PRESCALE)."""
    s = self.lensi_prescale
    x = x * s
    u = x.mean(1, keepdim=True)
    var = (x - u).pow(2).mean(1, keepdim=True)
    x = (x - u) / torch.sqrt(var + self.eps * s * s)
    return self.weight[:, None, None] * x + self.bias[:, None, None]


def patch_for_coreml(sam):
    """Patches a (copied) Sam in place; returns it."""
    encoder = sam.image_encoder
    blocks = 0
    for i, layer in enumerate(encoder.layers):
        for block in layer.blocks:
            if type(block).__name__ != "TinyViTBlock":
                continue
            block.forward = types.MethodType(_tinyvit_block_forward, block)
            block.lensi_ln_prescale = LN_PRESCALE if i == 3 else 1.0
            blocks += 1
    assert blocks == 10, f"expected 10 TinyViT blocks, patched {blocks}"
    for idx in (1, 3):
        ln = encoder.neck[idx]
        assert type(ln).__name__ == "LayerNorm2d", type(ln)
        ln.lensi_prescale = LN_PRESCALE
        ln.forward = types.MethodType(_layernorm2d_forward, ln)
    return sam


# --------------------------------------------------------------------------------------------
# Wrappers that get traced


class EncoderWrapper(nn.Module):
    """[1,3,1024,1024] RGB 0-255 (the padded canvas) -> image_embeddings [1,256,64,64].

    Sam.preprocess's normalisation, inside the graph and in the same op order, so it is exact.
    The zero-padding SAM applies after normalisation is the caller's PAD_RGB canvas fill.
    """

    def __init__(self, sam):
        super().__init__()
        self.image_encoder = sam.image_encoder
        self.register_buffer("pixel_mean", sam.pixel_mean.detach().clone().view(1, 3, 1, 1))
        self.register_buffer("pixel_std", sam.pixel_std.detach().clone().view(1, 3, 1, 1))

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        return self.image_encoder((image - self.pixel_mean) / self.pixel_std)


def _attention(attn, q, k, v, key_bias=None):
    """segment_anything's transformer.Attention.forward plus an optional additive key bias."""
    q = attn._separate_heads(attn.q_proj(q), attn.num_heads)
    k = attn._separate_heads(attn.k_proj(k), attn.num_heads)
    v = attn._separate_heads(attn.v_proj(v), attn.num_heads)
    c_per_head = q.shape[-1]
    logits = q @ k.permute(0, 1, 3, 2)
    logits = logits / math.sqrt(c_per_head)
    if key_bias is not None:
        logits = logits + key_bias
    out = torch.softmax(logits, dim=-1) @ v
    return attn.out_proj(attn._recombine_heads(out))


def _two_way_block(blk, queries, keys, query_pe, key_pe, key_bias):
    """TwoWayAttentionBlock.forward; key_bias masks prompt tokens wherever they are keys."""
    if blk.skip_first_layer_pe:
        queries = _attention(blk.self_attn, queries, queries, queries, key_bias)
    else:
        q = queries + query_pe
        queries = queries + _attention(blk.self_attn, q, q, queries, key_bias)
    queries = blk.norm1(queries)

    q = queries + query_pe
    k = keys + key_pe
    queries = blk.norm2(queries + _attention(blk.cross_attn_token_to_image, q, k, keys))

    queries = blk.norm3(queries + blk.mlp(queries))

    q = queries + query_pe
    k = keys + key_pe
    keys = blk.norm4(keys + _attention(blk.cross_attn_image_to_token, k, q, queries, key_bias))
    return queries, keys


class DecoderWrapper(nn.Module):
    """SamOnnxModel without mask input and without upscaling, for a fixed 5-slot prompt.

    Point embedding is SamOnnxModel._embed_points verbatim: label -1 slots get
    not_a_point_embed (no positional encoding), 0/1/2/3 get their point_embeddings, coordinates
    are 1024-space pixels shifted by 0.5. has_mask_input is fixed to 0, so the dense prompt is
    no_mask_embed broadcast.

    Padding (pad_mask=True, the default): SamPredictor feeds the decoder exactly one padding
    token when there is no box and none with a box; the ONNX export leaves that to the caller.
    A fixed 5-slot input would otherwise carry up to four identical padding tokens, which shifts
    the token attention away from what SAM was trained on. With pad_mask the decoder keeps the
    first -1 slot when no box corner (2/3) is present and hides every other -1 slot from
    attention (as keys in token self-attention and image->token cross-attention; their own
    outputs are never read), which reproduces SamPredictor exactly for any prompt that fits in 5
    slots. pad_mask=False is the plain ONNX behaviour with all padding tokens visible.

    Outputs: masks [1,4,256,256] logits (0 = single-mask token, 1..3 = multimask), scores [1,4].
    """

    def __init__(self, sam, pad_mask: bool = True):
        super().__init__()
        pe = sam.prompt_encoder
        self.decoder = sam.mask_decoder
        self.transformer = sam.mask_decoder.transformer
        self.pe_layer = pe.pe_layer
        self.img_size = float(sam.image_encoder.img_size)
        self.pad_mask = pad_mask
        self.num_mask_tokens = sam.mask_decoder.num_mask_tokens
        self.num_output_tokens = 1 + self.num_mask_tokens
        with torch.no_grad():
            self.register_buffer("dense_pe", pe.get_dense_pe().detach().clone())
            self.register_buffer("no_mask_embed", pe.no_mask_embed.weight.detach().clone().reshape(1, -1, 1, 1))
            self.register_buffer("not_a_point_embed", pe.not_a_point_embed.weight.detach().clone())
            self.register_buffer(
                "point_embeds", torch.cat([e.weight.detach().clone() for e in pe.point_embeddings], 0))
            self.register_buffer(
                "output_tokens",
                torch.cat([self.decoder.iou_token.weight, self.decoder.mask_tokens.weight], 0)
                .detach().clone().unsqueeze(0))
            self.register_buffer("upper", torch.triu(torch.ones(sc.NUM_POINTS, sc.NUM_POINTS)))

    def embed_points(self, point_coords, point_labels):
        coords = (point_coords + 0.5) / self.img_size
        emb = self.pe_layer._pe_encoding(coords)  # [1, N, 256]
        labels = point_labels.unsqueeze(-1)  # broadcasts over the channel axis
        emb = emb * (labels != -1).to(emb.dtype)
        emb = emb + self.not_a_point_embed * (labels == -1).to(emb.dtype)
        for i in range(self.point_embeds.shape[0]):
            emb = emb + self.point_embeds[i] * (labels == i).to(emb.dtype)
        return emb

    def token_key_bias(self, point_labels):
        """[1,1,1,5+N] additive bias: 0 for visible tokens, MASKED_TOKEN_BIAS for hidden ones."""
        is_pad = (point_labels == -1).to(torch.float32)  # [1, N]
        is_corner = ((point_labels == 2).to(torch.float32) + (point_labels == 3).to(torch.float32))
        has_box = torch.clamp(is_corner.amax(dim=1, keepdim=True), max=1.0)  # [1, 1]
        running = is_pad @ self.upper  # inclusive cumulative count of padding slots
        first_pad = is_pad * (running == 1).to(torch.float32)
        visible = (1.0 - is_pad) + first_pad * (1.0 - has_box)
        bias = (1.0 - visible) * MASKED_TOKEN_BIAS
        lead = torch.zeros(1, self.num_output_tokens, dtype=bias.dtype)
        return torch.cat([lead, bias], dim=1).view(1, 1, 1, -1)

    def forward(self, image_embeddings, point_coords, point_labels):
        sparse = self.embed_points(point_coords, point_labels)
        key_bias = self.token_key_bias(point_labels) if self.pad_mask else None
        tokens = torch.cat([self.output_tokens, sparse], dim=1)  # [1, 5+N, 256]

        src = image_embeddings + self.no_mask_embed
        b, c, h, w = src.shape
        image_tokens = src.flatten(2).permute(0, 2, 1)
        image_pe = self.dense_pe.flatten(2).permute(0, 2, 1)

        # TwoWayTransformer.forward
        queries, keys = tokens, image_tokens
        for blk in self.transformer.layers:
            queries, keys = _two_way_block(blk, queries, keys, tokens, image_pe, key_bias)
        q = queries + tokens
        k = keys + image_pe
        queries = queries + _attention(self.transformer.final_attn_token_to_image, q, k, keys)
        hs = self.transformer.norm_final_attn(queries)

        # MaskDecoder.predict_masks
        iou_token_out = hs[:, 0, :]
        mask_tokens_out = hs[:, 1:self.num_output_tokens, :]
        src = keys.transpose(1, 2).reshape(b, c, h, w)
        upscaled = self.decoder.output_upscaling(src)
        hyper_in = torch.stack(
            [mlp(mask_tokens_out[:, i, :]) for i, mlp in enumerate(self.decoder.output_hypernetworks_mlps)],
            dim=1)
        b, c, h, w = upscaled.shape
        masks = (hyper_in @ upscaled.reshape(b, c, h * w)).reshape(b, -1, h, w)
        scores = self.decoder.iou_prediction_head(iou_token_out)
        return masks, scores


def build_wrappers(sam, pad_mask: bool = True) -> tuple[EncoderWrapper, DecoderWrapper]:
    """Wrappers around a patched deep copy, so `sam` itself stays the untouched reference."""
    model = patch_for_coreml(copy.deepcopy(sam))
    return EncoderWrapper(model).eval(), DecoderWrapper(model, pad_mask=pad_mask).eval()


def example_decoder_inputs():
    g = torch.Generator().manual_seed(0)
    emb = torch.randn(sc.EMBED_SHAPE, generator=g)
    coords = torch.rand(1, sc.NUM_POINTS, 2, generator=g) * sc.IMG_SIZE
    labels = torch.tensor([[1.0, 0.0, 2.0, 3.0, -1.0]])
    return emb, coords, labels


def trace(encoder: EncoderWrapper, decoder: DecoderWrapper):
    with torch.no_grad():
        enc = torch.jit.trace(encoder, torch.rand(1, 3, sc.IMG_SIZE, sc.IMG_SIZE) * 255)
        dec = torch.jit.trace(decoder, example_decoder_inputs())
    return enc, dec


# --------------------------------------------------------------------------------------------
# Core ML


def _describe(model, kind: str, pad_mask: bool):
    model.author = "Lensi; MobileSAM by Chaoning Zhang et al. (Apache-2.0), SAM by Meta (Apache-2.0)"
    model.license = "Apache-2.0"
    model.version = f"mobile_sam@{MOBILE_SAM_COMMIT[:12]}"
    meta = model.user_defined_metadata
    meta["mobile_sam_commit"] = MOBILE_SAM_COMMIT
    meta["image_size"] = str(sc.IMG_SIZE)
    if kind == "encoder":
        model.short_description = (
            "MobileSAM TinyViT image encoder. Input: the image resized so its long side is 1024, "
            "drawn at the top-left of a 1024x1024 canvas filled with RGB "
            f"{sc.PAD_RGB}. SAM pixel normalisation happens inside the model.")
        model.input_description["image"] = "1024x1024 RGB, raw 0-255, image at top-left, mean-colour padding"
        model.output_description["image_embeddings"] = "SAM image embedding [1,256,64,64]"
        meta["pixel_mean"] = ",".join(map(str, sc.PIXEL_MEAN))
        meta["pixel_std"] = ",".join(map(str, sc.PIXEL_STD))
        meta["pad_rgb"] = ",".join(map(str, sc.PAD_RGB))
    else:
        model.short_description = (
            "SAM prompt encoder + mask decoder (SamOnnxModel without mask input or upscaling), "
            "5 fixed prompt slots.")
        model.input_description["image_embeddings"] = "LensiSAMEncoder output [1,256,64,64]"
        model.input_description["point_coords"] = "[1,5,2] x,y in 1024-input pixels (point * resized size)"
        model.input_description["point_labels"] = (
            "[1,5] 1 fg, 0 bg, 2 box top-left, 3 box bottom-right, -1 padding (put padding last)")
        model.output_description["masks"] = (
            "[1,4,256,256] low-res mask logits over the 1024 canvas; 0 single-mask, 1-3 multimask")
        model.output_description["scores"] = "[1,4] predicted IoU per mask"
        meta["pad_mask"] = "1" if pad_mask else "0"
        meta["num_points"] = str(sc.NUM_POINTS)


def convert(traced, kind: str, pad_mask: bool = True):
    import coremltools as ct

    common = dict(
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
    )
    if kind == "encoder":
        model = ct.convert(
            traced,
            inputs=[ct.ImageType(name="image", shape=(1, 3, sc.IMG_SIZE, sc.IMG_SIZE),
                                 color_layout=ct.colorlayout.RGB, scale=1.0, bias=[0.0, 0.0, 0.0])],
            outputs=[ct.TensorType(name="image_embeddings", dtype=np.float32)],
            **common)
    else:
        model = ct.convert(
            traced,
            inputs=[
                ct.TensorType(name="image_embeddings", shape=sc.EMBED_SHAPE, dtype=np.float32),
                ct.TensorType(name="point_coords", shape=(1, sc.NUM_POINTS, 2), dtype=np.float32),
                ct.TensorType(name="point_labels", shape=(1, sc.NUM_POINTS), dtype=np.float32),
            ],
            outputs=[ct.TensorType(name="masks", dtype=np.float32),
                     ct.TensorType(name="scores", dtype=np.float32)],
            **common)
    _describe(model, kind, pad_mask)
    return model


def summarize(model) -> dict:
    """I/O signature, op histogram and max tensor rank of a converted model."""
    spec = model.get_spec()

    def sig(features):
        out = []
        for f in features:
            t = f.type
            which = t.WhichOneof("Type")
            if which == "imageType":
                out.append((f.name, "image", f"{t.imageType.width}x{t.imageType.height}",
                            "RGB" if t.imageType.colorSpace == 20 else str(t.imageType.colorSpace)))
            else:
                arr = t.multiArrayType
                dtype = {65568: "float32", 65552: "float16", 65600: "float64", 131104: "int32"}.get(
                    arr.dataType, str(arr.dataType))
                out.append((f.name, "multiarray", list(arr.shape), dtype))
        return out

    ops: dict[str, int] = {}
    max_rank = 0
    prog = getattr(model, "_mil_program", None)
    if prog is not None:
        for op in prog.functions["main"].operations:
            ops[op.op_type] = ops.get(op.op_type, 0) + 1
            for v in op.outputs:
                if v.shape is not None:
                    max_rank = max(max_rank, len(v.shape))
    return {"inputs": sig(spec.description.input), "outputs": sig(spec.description.output),
            "ops": dict(sorted(ops.items(), key=lambda kv: -kv[1])), "max_rank": max_rank,
            "spec_version": spec.specificationVersion}


def dir_size(path: str) -> int:
    return sum(os.path.getsize(os.path.join(d, f)) for d, _, files in os.walk(path) for f in files)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="directory for the .mlpackage outputs")
    ap.add_argument("--cache", default=DEFAULT_CACHE, help="MobileSAM source/weights cache")
    ap.add_argument("--onnx-padding", action="store_true",
                    help="plain SamOnnxModel padding: every -1 slot stays visible to attention")
    ap.add_argument("--only", choices=["encoder", "decoder"], help="convert just one model")
    args = ap.parse_args()

    torch.manual_seed(0)
    sam = load_mobile_sam(args.cache)
    encoder, decoder = build_wrappers(sam, pad_mask=not args.onnx_padding)
    os.makedirs(args.out, exist_ok=True)
    traced_enc, traced_dec = trace(encoder, decoder)
    jobs = [("encoder", traced_enc, ENCODER_NAME), ("decoder", traced_dec, DECODER_NAME)]
    for kind, traced, name in jobs:
        if args.only and args.only != kind:
            continue
        t0 = time.time()
        model = convert(traced, kind, pad_mask=not args.onnx_padding)
        path = os.path.join(args.out, f"{name}.mlpackage")
        if os.path.exists(path):
            shutil.rmtree(path)
        model.save(path)
        info = summarize(model)
        print(f"\n{name}: {path} ({dir_size(path) / 1e6:.1f} MB, converted in {time.time() - t0:.0f}s, "
              f"spec v{info['spec_version']}, max tensor rank {info['max_rank']})")
        for label in ("inputs", "outputs"):
            for row in info[label]:
                print(f"  {label[:-1]:6s} {row}")
        top = ", ".join(f"{k}:{v}" for k, v in list(info["ops"].items())[:14])
        print(f"  ops    {sum(info['ops'].values())} total; {top}")


if __name__ == "__main__":
    main()
