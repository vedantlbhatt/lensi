# Smooth live segmentation (branch smooth-seg)

Goal (owner, 2026-10-03): SAM outlines on the live camera should be fluid, pinned to the
object and barely jitter, with several subjects and while things move. Work started 21:55.

## How it's measured

`tools/livesam` replays DAVIS 2017 val (30 videos, 1-5 moving objects each, ground-truth masks)
through the real Core ML models and the app's own tracking code, with the phone's SAM latency
simulated (`--encoder-ms`, `--decoder-ms`; the camera keeps moving while SAM thinks). Every frame
it scores what would be on screen: **J** = IoU with the true mask, **jitter** = how much the
outline changes frame to frame beyond how much the true mask changes.

Data lives outside the repo: `~/lensi-data/DAVIS` (DAVIS-2017-trainval-480p).

## Results (DAVIS 2017 val, 30 videos, EdgeSAM, 25 ms encoder + 8 ms per prompt)

| version | J (higher better) | jitter (lower better) |
|---|---|---|
| camera-first (SAM at a point, outline held until the next answer; oracle prompts) | 0.355 | 0.171 |
| v1: optical flow + carried-forward SAM + candidate matching + sub-pixel contours | 0.492 | 0.045 |

## What changed

1. **Encoder on the Neural Engine.** MobileSAM's TinyViT encoder fails ANE compilation
   ("ANECCompile() FAILED") and silently falls back to the GPU: 40 ms on an M3. EdgeSAM-3x
   (`tools/sam/convert_edgesam.py`, same model I/O, drop-in) runs fully on the ANE: 11.5 ms.
   Decoder kept in float32 (float16 changed which candidate wins). Verified against PyTorch:
   encoder cosine 0.998, decoder masks IoU 1.000 (`tools/sam/verify_edgesam.py`).
   **License: EdgeSAM weights are S-Lab License 1.0, non-commercial only.** Fine for a
   personal/class build; a commercial release needs MobileSAM on the ANE (being worked on in
   branch ane-mobilesam) or another permissive model.
2. **Outlines move with the object every frame** (`LiveSeg.swift`): pyramidal Lucas-Kanade
   optical flow (forward-backward checked) on ~48 textured points inside each outline, a robust
   similarity fit (RANSAC), applied to the outline. Runs on its own queue on a 480 px luma image.
3. **SAM answers are carried forward**: each answer is for a frame that's already gone; it's moved
   along the track's motion since then, aligned vertex-to-vertex and blended (gain 0.5 when it
   agrees, more when it doesn't, wild answers skipped).
4. **Same object every pass**: tracks prompt SAM with their own box (+10%) and an interior point,
   and the candidate mask that overlaps the track most wins (no flipping between "handle" and
   "whole mug").
5. **Sub-pixel contours from the logits** (marching squares, `MaskContour`): 0.6 ms instead of
   ~19 ms for Vision's contour request, and edges no longer step a whole cell.
6. Faster SAM plumbing: memcpy of the decoder output (MLShapedArray's converting copy cost 12 ms),
   Core Image draws the camera frame straight into the encoder's input buffer.

## Log

