#!/usr/bin/env python3
"""Run LensiSAMEncoder / LensiSAMDecoder with Core ML on the fixtures and compare against the
PyTorch references evaluate.py stored. macOS only: Core ML predictions don't run elsewhere.

    pip install coremltools==9.0 numpy pillow
    python tools/sam/verify_coreml.py --models OUT_DIR [--compute-units ALL]

For every fixture prompt the decoder's mask at the reference's chosen index is reduced to 64x64
(4x4 mean of the logits, > 0) and compared with the stored mask; the run fails when that IoU is
below --min-iou or a predicted-IoU score moves by more than --max-score-diff. Inputs are rebuilt
exactly as the references were: the fixture image (downloaded, sha256-checked), Pillow bilinear
resize, mean-colour canvas, and the stored decoder inputs.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sam_common as sc  # noqa: E402


def check_signature(encoder, decoder) -> None:
    def names(model, kind):
        return sorted(f.name for f in getattr(model.get_spec().description, kind))

    expected = [
        (encoder, "input", ["image"]), (encoder, "output", ["image_embeddings"]),
        (decoder, "input", ["image_embeddings", "point_coords", "point_labels"]),
        (decoder, "output", ["masks", "scores"]),
    ]
    for model, kind, want in expected:
        got = names(model, kind)
        if got != want:
            sys.exit(f"unexpected model {kind}s {got}, expected {want}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models", required=True, help="directory with LensiSAMEncoder/Decoder.mlpackage")
    ap.add_argument("--fixtures", default=os.path.join(HERE, "fixtures"))
    ap.add_argument("--image-cache", default=os.path.expanduser("~/.cache/lensi-sam/images"),
                    help="where fixture images are downloaded (or pre-placed as <name>.jpg)")
    ap.add_argument("--compute-units", default="ALL", choices=["ALL", "CPU_ONLY", "CPU_AND_GPU", "CPU_AND_NE"])
    ap.add_argument("--min-iou", type=float, default=0.95)
    ap.add_argument("--max-score-diff", type=float, default=0.05)
    args = ap.parse_args()

    if sys.platform != "darwin":
        sys.exit(f"verify_coreml.py needs macOS; Core ML predictions do not run on {sys.platform}.")
    import coremltools as ct
    from PIL import Image

    units = getattr(ct.ComputeUnit, args.compute_units)
    t0 = time.perf_counter()
    encoder = ct.models.MLModel(os.path.join(args.models, "LensiSAMEncoder.mlpackage"), compute_units=units)
    decoder = ct.models.MLModel(os.path.join(args.models, "LensiSAMDecoder.mlpackage"), compute_units=units)
    print(f"loaded models in {time.perf_counter() - t0:.1f}s (compute units {args.compute_units})")
    check_signature(encoder, decoder)

    fixtures = sorted(glob.glob(os.path.join(args.fixtures, "*.json")))
    if not fixtures:
        sys.exit(f"no fixtures in {args.fixtures}")
    failures = []
    for path in fixtures:
        with open(path) as f:
            fx = json.load(f)
        image_path = sc.fetch(fx["image"]["url"], os.path.join(args.image_cache, f"{fx['name']}.jpg"),
                              fx["image"]["sha256"])
        canvas, params = sc.preprocess(sc.load_rgb(image_path))
        want = (fx["preprocess"]["resized_width"], fx["preprocess"]["resized_height"])
        if (params["resized_width"], params["resized_height"]) != want:
            sys.exit(f"{fx['name']}: resized size {params} != fixture {want}")

        encoder.predict({"image": Image.fromarray(canvas)})  # warm-up
        t0 = time.perf_counter()
        emb = encoder.predict({"image": Image.fromarray(canvas)})["image_embeddings"]
        enc_ms = (time.perf_counter() - t0) * 1000
        emb = np.asarray(emb, np.float32).reshape(sc.EMBED_SHAPE)
        probes = fx["embedding_probes"]
        got = np.array([emb[0, c, y, x] for c, y, x in probes["indices"]])
        ref = np.array(probes["values"], np.float32)
        print(f"\n{fx['name']}: encoder {enc_ms:.0f} ms; embedding probes max|diff| "
              f"{np.abs(got - ref).max():.4f} (reference |max| {np.abs(ref).max():.3f})")

        for p in fx["prompts"]:
            feeds = {
                "image_embeddings": emb,
                "point_coords": np.array(p["point_coords"], np.float32).reshape(1, sc.NUM_POINTS, 2),
                "point_labels": np.array(p["point_labels"], np.float32).reshape(1, sc.NUM_POINTS),
            }
            t0 = time.perf_counter()
            out = decoder.predict(feeds)
            dec_ms = (time.perf_counter() - t0) * 1000
            masks = np.asarray(out["masks"], np.float32).reshape(4, sc.MASK_SIZE, sc.MASK_SIZE)
            scores = np.asarray(out["scores"], np.float32).reshape(4)
            k = p["chosen"]
            ious = [sc.iou(sc.mask64_from_logits(masks[i]), sc.decode_mask64(p["mask64"][i])) for i in range(4)]
            score_diff = float(np.abs(scores - np.array(p["scores"], np.float32)).max())
            k_here = sc.choose_mask(scores, p["labels"], p["box"] is not None)
            ok = ious[k] >= args.min_iou and score_diff <= args.max_score_diff
            print(f"  {'ok  ' if ok else 'FAIL'} {p['name']:<30s} mask {k}: IoU64 {ious[k]:.4f} "
                  f"(all {[round(v, 3) for v in ious]}), max|d score| {score_diff:.4f}, decoder {dec_ms:.0f} ms"
                  + ("" if k_here == k else f"  [note: Core ML scores pick mask {k_here}]"))
            if not ok:
                failures.append(f"{fx['name']}/{p['name']}")

    print(f"\n{'FAILED: ' + ', '.join(failures) if failures else 'all fixtures passed'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
