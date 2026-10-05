"""EdgeTAM (Meta's on-device SAM 2, github.com/facebookresearch/EdgeTAM, Apache 2.0) split into the
four fixed-shape models the app runs, and the loop that strings them together frame by frame.

SAM 2's video predictor keeps a memory of the thing it follows: the frame it was prompted on, the
last six frames it followed it through, and an "object pointer" from each of the last sixteen. Each
new frame's features attend to that memory before the mask decoder runs, which is why it holds on
through close-ups, blur, turning and the thing running off the picture where a fresh cut of every
frame jumps about. Its memory is variable in length; here it's laid out in fixed slots with a
validity flag each, so every model has one shape (what Core ML and the Neural Engine want):

  EdgeTAMEncoder  a frame (RGB 0..1, the camera picture stretched to 1024 x 1024, as SAM 2 does)
                  -> features (256 @ 64x64), and two finer levels for the mask decoder
  EdgeTAMPrompt   the first frame's features and a box -> its mask (logits @ 256x256), IoU
                  estimate, object pointer and whether the thing is there at all
  EdgeTAMTrack    any later frame's features and the memory (7 frames x 512 tokens, 16 pointers)
                  -> the same for three candidates, with no prompt
  EdgeTAMMemory   a frame's features and its chosen mask -> its memory (512 tokens x 64)

As in EdgeTAM's video predictor (build_sam2_video_predictor): a box's single mask falls back to the
best of three when it isn't stable, and the prompted frame's memory is made from its mask cut hard
(what the person saw) rather than its sigmoid. The predictor also stores memories in bfloat16 and
fills pinholes in the prompted mask; neither is done here.

`Tracker` below is the loop the app's Swift runs (EdgeTAMTracker.swift), in PyTorch, so the split
can be checked against the official predictor (check.py) before it's converted (convert.py).
"""
import math

import torch
import torch.nn.functional as F
from torch import nn

from sam2.modeling.position_encoding import compute_axial_cis

NUM_MEM = 7  # memory frames: the prompted one and the last six
MEM_TOKENS = 512  # per memory frame, from the spatial perceiver: 256 global latents, then 256 on a 16x16 grid
MEM_DIM = 64
NUM_PTRS = 16  # object pointers: the prompted frame's and the last fifteen
PTR_TOKENS = 4  # a 256-d pointer is four 64-d tokens
NO_OBJ = -1024.0  # SAM 2's mask logit where the thing isn't there
IMAGE = 1024
FEAT = 64


def rope_tables(dim, end_x, end_y, theta=10000.0):
    """SAM 2's axial rotary encoding as cos and sin tables (N x dim/2), for a real-valued rotation."""
    cis = compute_axial_cis(dim=dim, end_x=end_x, end_y=end_y, theta=theta)
    return cis.real.float().contiguous(), cis.imag.float().contiguous()


def rotate(x, cos, sin):
    """x (..., N, D) rotated pairwise by the angles in cos/sin (N x D/2): x * e^(i angle) on (x0, x1) pairs."""
    shape = x.shape
    x = x.reshape(*shape[:-1], shape[-1] // 2, 2)
    x0, x1 = x[..., 0], x[..., 1]
    out = torch.stack((x0 * cos - x1 * sin, x0 * sin + x1 * cos), dim=-1)
    return out.reshape(shape)


def attend(q, k, v, bias=None):
    """Single-head attention (B x N x D), optionally with an additive bias on the keys (B x M)."""
    logits = torch.matmul(q, k.transpose(-1, -2)) * (1.0 / math.sqrt(q.shape[-1]))
    if bias is not None:
        logits = logits + bias[:, None, :]
    return torch.matmul(torch.softmax(logits, dim=-1), v)


def sam_heads(m, pix, high0, high1, coords, labels, multimask):
    """SAM's prompt encoder and mask decoder, with SAM 2's occlusion handling: no object -> masks
    at NO_OBJ and the no-object pointer. Three candidates when tracking; one for a box (SAM 2 asks
    for several only for a single click or none)."""
    sparse, dense = m.sam_prompt_encoder(points=(coords, labels), boxes=None, masks=None)
    masks, ious, tokens, score = m.sam_mask_decoder(
        image_embeddings=pix,
        image_pe=m.sam_prompt_encoder.get_dense_pe(),
        sparse_prompt_embeddings=sparse,
        dense_prompt_embeddings=dense,
        multimask_output=multimask,
        repeat_image=False,
        high_res_features=[high0, high1],
    )
    appear = (score > 0).float()  # 1 x 1
    masks = masks * appear[:, :, None, None] + NO_OBJ * (1 - appear[:, :, None, None])
    ptrs = m.obj_ptr_proj(tokens)  # 1 x candidates x 256
    ptrs = appear[:, :, None] * ptrs + (1 - appear[:, :, None]) * m.no_obj_ptr[None]
    return masks, ious, ptrs, score


class EdgeTAMEncoder(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def forward(self, image):
        out = self.m.forward_image((image - self.mean) / self.std)
        fpn = out["backbone_fpn"]
        return fpn[2], fpn[0], fpn[1]


class EdgeTAMPrompt(nn.Module):
    """The prompted frame: no memory yet, so SAM 2 adds its no-memory embedding to the features."""

    def __init__(self, m):
        super().__init__()
        self.m = m
        self.register_buffer("labels", torch.tensor([[2, 3]], dtype=torch.int32))

    def forward(self, features, high0, high1, box):
        pix = features + self.m.no_mem_embed.view(1, -1, 1, 1)
        return sam_heads(self.m, pix, high0, high1, box.view(1, 2, 2), self.labels, multimask=False)


class EdgeTAMTrack(nn.Module):
    """A later frame: its features attend to the memory (SAM 2's memory attention, with the slots
    that aren't filled yet masked out), then SAM's decoder runs unprompted."""

    def __init__(self, m):
        super().__init__()
        self.m = m
        ma = m.memory_attention
        layer = ma.layers[0]
        d = layer.self_attn.internal_dim // layer.self_attn.num_heads
        c, s = rope_tables(d, FEAT, FEAT)
        self.register_buffer("self_cos", c)
        self.register_buffer("self_sin", s)
        cq, sq = rope_tables(layer.cross_attn_image.internal_dim, FEAT, FEAT)
        self.register_buffer("q_cos", cq)
        self.register_buffer("q_sin", sq)
        grid = int(math.sqrt(m.spatial_perceiver.num_latents_2d))
        ck, sk = rope_tables(layer.cross_attn_image.internal_dim, grid, grid)
        # Keys: per memory frame 256 global latents (no rotation), then 256 on the grid; the
        # pointers' tokens at the end aren't rotated either.
        n_global = m.spatial_perceiver.num_latents
        ones = torch.ones(n_global, ck.shape[1])
        zeros = torch.zeros(n_global, ck.shape[1])
        frame_cos = torch.cat([ones, ck], 0).repeat(NUM_MEM, 1)
        frame_sin = torch.cat([zeros, sk], 0).repeat(NUM_MEM, 1)
        ptr_n = NUM_PTRS * PTR_TOKENS
        self.register_buffer("k_cos", torch.cat([frame_cos, torch.ones(ptr_n, ck.shape[1])], 0))
        self.register_buffer("k_sin", torch.cat([frame_sin, torch.zeros(ptr_n, ck.shape[1])], 0))
        # Where things are: the image's (64x64), and each memory slot's (the perceiver's, plus the
        # slot's temporal encoding: slot 0 the prompted frame, slot j the frame 7 - j ago).
        with torch.no_grad():
            vpos = m.image_encoder.neck.position_encoding(torch.zeros(1, 256, FEAT, FEAT))
            self.register_buffer("vision_pos", vpos.flatten(2).transpose(1, 2).contiguous())
            mem_feat = torch.zeros(1, MEM_DIM, FEAT, FEAT)
            mpos = m.memory_encoder.position_encoding(mem_feat)
            _, lat_pos = m.spatial_perceiver(mem_feat, mpos)  # 1 x 512 x 64
            slots = []
            for j in range(NUM_MEM):
                t_pos = j  # slot 0: t_pos 0 (the prompted frame); slot j: t_pos j
                slots.append(lat_pos[0] + m.maskmem_tpos_enc[NUM_MEM - t_pos - 1].view(1, MEM_DIM))
            self.register_buffer("mem_pos", torch.cat(slots, 0)[None].contiguous())
        self.register_buffer("no_coords", torch.zeros(1, 1, 2))
        self.register_buffer("no_labels", -torch.ones(1, 1, dtype=torch.int32))

    def forward(self, features, high0, high1, memory, memory_valid, ptrs, ptr_valid):
        m = self.m
        ma = m.memory_attention
        x = features.flatten(2).transpose(1, 2)  # 1 x 4096 x 256
        x = x + 0.1 * self.vision_pos
        ptr_tokens = ptrs.reshape(1, NUM_PTRS * PTR_TOKENS, MEM_DIM)
        keys = torch.cat([memory, ptr_tokens], 1)  # 1 x (7*512 + 64) x 64
        keys_pos = torch.cat([self.mem_pos, torch.zeros_like(ptr_tokens)], 1)
        valid = torch.cat(
            [
                memory_valid.reshape(1, NUM_MEM, 1).expand(1, NUM_MEM, MEM_TOKENS).reshape(1, NUM_MEM * MEM_TOKENS),
                ptr_valid.reshape(1, NUM_PTRS, 1).expand(1, NUM_PTRS, PTR_TOKENS).reshape(1, NUM_PTRS * PTR_TOKENS),
            ],
            1,
        )
        bias = (valid - 1.0) * 10000.0
        for layer in ma.layers:
            sa = layer.self_attn
            t = layer.norm1(x)
            q = rotate(sa.q_proj(t), self.self_cos, self.self_sin)
            k = rotate(sa.k_proj(t), self.self_cos, self.self_sin)
            x = x + sa.out_proj(attend(q, k, sa.v_proj(t)))
            ca = layer.cross_attn_image
            t = layer.norm2(x)
            q = rotate(ca.q_proj(t), self.q_cos, self.q_sin)
            k = rotate(ca.k_proj(keys + keys_pos), self.k_cos, self.k_sin)
            x = x + ca.out_proj(attend(q, k, ca.v_proj(keys), bias))
            t = layer.norm3(x)
            x = x + layer.linear2(layer.activation(layer.linear1(t)))
        x = ma.norm(x)
        pix = x.transpose(1, 2).reshape(1, -1, FEAT, FEAT)
        return sam_heads(m, pix, high0, high1, self.no_coords, self.no_labels, multimask=True)


class EdgeTAMMemory(nn.Module):
    """A frame's memory: its features fused with its mask (SAM 2 scales the mask's sigmoid to
    -10..10 first), squeezed by EdgeTAM's spatial perceiver to 512 tokens. `binarize` 1 for the
    prompted frame: its mask goes in cut hard at zero instead of through the sigmoid."""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, features, mask, binarize):
        high = F.interpolate(mask, size=(IMAGE, IMAGE), mode="bilinear", align_corners=False)
        hard = (high > 0).float()
        b = binarize.view(1, 1, 1, 1)
        high = b * hard + (1 - b) * torch.sigmoid(high)
        high = high * self.m.sigmoid_scale_for_mem_enc + self.m.sigmoid_bias_for_mem_enc
        out = self.m.memory_encoder(features, high, skip_mask_sigmoid=True)
        latents, _ = self.m.spatial_perceiver(out["vision_features"], out["vision_pos_enc"][0])
        return latents


class Tracker:
    """One thing followed through a video, frame by frame, with the four models above (or anything
    that answers like them): what EdgeTAMTracker.swift does in the app."""

    def __init__(self, encoder, prompt, track, memory):
        self.encoder, self.prompt, self.track, self.memory = encoder, prompt, track, memory
        self.cond = None  # the prompted frame's memory (1 x 512 x 64) and pointer (1 x 256)
        self.recent = []  # the last six frames' memories, oldest first
        self.ptrs = []  # the last fifteen frames' pointers, newest first

    @staticmethod
    def pick(masks, ious, ptrs):
        best = int(torch.argmax(ious[0]))
        return masks[:, best : best + 1], ptrs[:, best]

    def start(self, image, box):
        features, high0, high1 = self.encoder(image)
        masks, ious, ptrs, score = self.prompt(features, high0, high1, box)
        mask, ptr = self.pick(masks, ious, ptrs)
        self.cond = (self.memory(features, mask, torch.ones(1, 1)), ptr)
        self.recent, self.ptrs = [], []
        return mask, score

    def step(self, image):
        features, high0, high1 = self.encoder(image)
        memory = torch.zeros(1, NUM_MEM * MEM_TOKENS, MEM_DIM)
        memory_valid = torch.zeros(1, NUM_MEM)
        memory[:, :MEM_TOKENS] = self.cond[0]
        memory_valid[:, 0] = 1
        # Slot j (1..6) is the frame 7 - j ago: the newest in slot 6.
        for i, mem in enumerate(reversed(self.recent)):
            j = NUM_MEM - 1 - i
            memory[:, j * MEM_TOKENS : (j + 1) * MEM_TOKENS] = mem
            memory_valid[:, j] = 1
        ptrs = torch.zeros(1, NUM_PTRS, 256)
        ptr_valid = torch.zeros(1, NUM_PTRS)
        ptrs[:, 0] = self.cond[1]
        ptr_valid[:, 0] = 1
        for i, p in enumerate(self.ptrs[: NUM_PTRS - 1]):
            ptrs[:, 1 + i] = p
            ptr_valid[:, 1 + i] = 1
        masks, ious, cand_ptrs, score = self.track(features, high0, high1, memory, memory_valid, ptrs, ptr_valid)
        mask, ptr = self.pick(masks, ious, cand_ptrs)
        self.recent = (self.recent + [self.memory(features, mask, torch.zeros(1, 1))])[-(NUM_MEM - 1) :]
        self.ptrs = ([ptr] + self.ptrs)[: NUM_PTRS - 1]
        return mask, score


def load(root, checkpoint, device="cpu"):
    """The EdgeTAM model from its checkpoint (the repo's own config), in eval mode."""
    import os

    from hydra import compose, initialize_config_module
    from hydra.core.global_hydra import GlobalHydra
    from hydra.utils import instantiate
    from omegaconf import OmegaConf

    if GlobalHydra.instance().is_initialized():
        GlobalHydra.instance().clear()
    initialize_config_module("sam2", version_base="1.2")
    # What build_sam2_video_predictor sets for video (its fill_hole_area isn't a model setting).
    cfg = compose(config_name="edgetam.yaml", overrides=[
        "++model.sam_mask_decoder_extra_args.dynamic_multimask_via_stability=true",
        "++model.sam_mask_decoder_extra_args.dynamic_multimask_stability_delta=0.05",
        "++model.sam_mask_decoder_extra_args.dynamic_multimask_stability_thresh=0.98",
        "++model.binarize_mask_from_pts_for_mem_enc=true",
    ])
    OmegaConf.resolve(cfg)
    model = instantiate(cfg.model, _recursive_=True)
    sd = torch.load(checkpoint, map_location="cpu", weights_only=True)["model"]
    missing, unexpected = model.load_state_dict(sd)
    assert not missing and not unexpected, (missing, unexpected)
    return model.to(device).eval()
