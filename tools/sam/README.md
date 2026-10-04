# On-device Segment Anything (MobileSAM -> Core ML)

`app/modules/lensi-ar/ios/SAMSegmenter.swift` outlines what a tap or box points at with
[MobileSAM](https://github.com/ChaoningZhang/MobileSAM) (Apache-2.0): a TinyViT image encoder
plus SAM's prompt encoder and mask decoder. This folder builds its two Core ML models and checks
them. Nothing big lives in the repo: weights are downloaded (pinned commit, sha256-checked) and
the `.mlpackage` outputs go wherever `--out` points.

| file | what |
|---|---|
| `convert.py` | fetches MobileSAM, patches it for Core ML / float16, writes `LensiSAMEncoder.mlpackage` and `LensiSAMDecoder.mlpackage` |
| `sam_common.py` | preprocessing, prompt packing, mask choice, mask -> polygon. The Python twin of `SAMSegmenter.swift` |
| `evaluate.py` | compares everything with MobileSAM's own `SamPredictor` on public images; writes `report/` and `fixtures/` |
| `mil_check.py` | runs the converted MIL programs in numpy with float16 storage: the Linux stand-in for Core ML |
| `verify_coreml.py` | macOS only: runs the real Core ML models on `fixtures/` and fails below IoU 0.95 |

## Convert (Linux or macOS)

```sh
python3.11 -m venv .venv && . .venv/bin/activate
pip install -r tools/sam/requirements.txt
python tools/sam/convert.py --out build/sam             # ~1 min; 14 MB encoder + 10 MB decoder
python tools/sam/evaluate.py --models build/sam         # optional, ~6 min; rewrites report/ and fixtures/
```

Downloads are cached in `~/.cache/lensi-sam` (`--cache` or `LENSI_SAM_CACHE` to move it).
Compile for the module's `LensiARModels` resource bundle (the podspec picks up `Models/*.mlmodelc`):

```sh
xcrun coremlcompiler compile build/sam/LensiSAMEncoder.mlpackage app/modules/lensi-ar/ios/Models/
xcrun coremlcompiler compile build/sam/LensiSAMDecoder.mlpackage app/modules/lensi-ar/ios/Models/
```

## Verify with Core ML (macOS, e.g. CI)

```sh
pip install coremltools==9.0 numpy pillow
python tools/sam/verify_coreml.py --models build/sam --compute-units CPU_ONLY
python tools/sam/verify_coreml.py --models build/sam --compute-units ALL
```

It downloads the two fixture images from GitHub (or reads `--image-cache/<name>.jpg`), rebuilds
the exact canvases and decoder inputs, and compares 64x64 masks and scores with the stored PyTorch
references.

## Model I/O (ML Program, float16 weights and compute, iOS 17, fixed shapes)

| model | inputs | outputs |
|---|---|---|
| LensiSAMEncoder | `image`: 1024x1024 RGB image, raw 0-255 | `image_embeddings`: float32 [1,256,64,64] |
| LensiSAMDecoder | `image_embeddings`: float32 [1,256,64,64]; `point_coords`: float32 [1,5,2]; `point_labels`: float32 [1,5] | `masks`: float32 [1,4,256,256] logits; `scores`: float32 [1,4] |

- Encoder input: resize the long side to 1024 (`round(side * 1024 / long side)`), draw it at the
  top-left of a 1024x1024 canvas filled with RGB (124, 116, 104). SAM's normalisation is inside
  the model.
- `point_coords` are pixels of that 1024 canvas: normalised point x resized size. Labels: 1 fg,
  0 bg, 2 box top-left, 3 box bottom-right, -1 padding. Real slots first, padding last.
- `masks` cover the whole 1024 canvas (4 px per cell), so crop to `resized / 4` before use.
  Index 0 is SAM's single-mask output, 1-3 the multimask candidates; use the best-scoring of 1-3
  for a lone positive click and 0 for everything else.

## Things that are not obvious

- **Naive float16 conversion of MobileSAM is broken.** The neck's LayerNorm2d sees
  `|x - mean|` up to ~620, so `(x - mean)^2` overflows float16 (max 65504) and the embedding
  turns to garbage (mask IoU 0 in `mil_check.py`). `convert.py` evaluates those LayerNorms, and
  TinyViT layer 3's attention norms, on `x / 32` with `eps / 32^2`, which is the same function
  without the overflow. It also normalises tokens before window padding (the padding is zeros
  after the norm, its affine folded into qkv) so no zero-variance token depends on a subnormal
  `eps`. After any change, run `evaluate.py --models` (or
  `mil_check.py`) and check "float16 hazards: none".
- **Padding slots are masked.** SamPredictor gives the decoder one padding token without a box
  and none with one. With five fixed slots, ONNX-style padding would add up to four identical
  `not_a_point` tokens, and that changes masks a lot (IoU down to 0.22 in the report). The
  decoder keeps the first `-1` slot visible only when there is no box and hides every other one
  from attention, so it matches SamPredictor exactly. `--onnx-padding` turns this off.
- **The encoder is laid out for the Neural Engine.** The unpatched TinyViT already compiled and
  ran on the ANE, but slowly (~41 ms on an M3 with `CPU_AND_NE`): its channel-last tokens and
  per-head permutes became transposes and reshapes, ~30% of the estimated cost. The patched
  encoder keeps an NCHW map from the patch embedding to the neck: channel LayerNorms (1x1 conv
  means where C is a power of two), linear layers as 1x1 convs with the norm affine and q scale
  folded in, windows partitioned into `[windows, C, 1, tokens]`, one slice per head, and the
  softmax folded into the value matmul (an all-ones row in v gives the denominator). Same
  function; ~29 ms on the ANE (mean of 10), same probe error and IoUs in `verify_coreml.py`.
  The GPU path got slower (~52 -> ~120 ms with `CPU_AND_GPU`), which matters only where there is
  no ANE. The `ANECCompile() FAILED` line that `verify_coreml.py` prints comes from the
  decoder (its `-1` padding mask; it compiles with `--onnx-padding`), which then runs off the
  ANE in ~5 ms.
- coremltools 9.0 was tested up to torch 2.7.0; newer torch may trace into ops it doesn't know.
- Core ML can't predict on Linux. `mil_check.py` runs the converted programs as a stand-in.
  `verify_coreml.py` on a Mac is the real check, and the only one that exercises the
  GPU / Neural Engine kernels.
