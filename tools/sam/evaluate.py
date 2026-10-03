#!/usr/bin/env python3
"""Check the converted pipeline against MobileSAM's own SamPredictor on public images, render
the outline report, and write the fixtures verify_coreml.py checks on macOS.

    python tools/sam/evaluate.py --models OUT_DIR

Per prompt it compares, against SamPredictor (unpatched model, fp32):
  decoder   DecoderWrapper on SamPredictor's own embedding: should be exact
  app fp32  the app pipeline in torch: mean-colour canvas -> traced encoder -> traced decoder
  coreml16  the converted .mlpackage programs run by mil_check.py with float16 storage
  onnx-pad  plain SamOnnxModel padding (all -1 slots visible), to show why the decoder masks
            surplus padding
and scores the app's polygon (sam_common.mask_to_polygon) against SAM's full-resolution mask.
Writes report/*.jpg + report/README.md and fixtures/*.json next to this file.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import statistics
import sys
import time

import numpy as np
import torch
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import convert as cv  # noqa: E402
import sam_common as sc  # noqa: E402

SAM_RAW = "https://raw.githubusercontent.com/facebookresearch/segment-anything/dca509fe793f601edb92606367a655c15ac00fdf/notebooks/images/"
ULTRA_RAW = "https://raw.githubusercontent.com/ultralytics/ultralytics/0541953490e63c7cf1cb1883c9433c9b376ea7a1/ultralytics/assets/"
MSAM_RAW = f"https://raw.githubusercontent.com/ChaoningZhang/MobileSAM/{cv.MOBILE_SAM_COMMIT}/app/assets/"

# Prompts are in original-image pixels (x, y) like the SAM notebooks; box is x0, y0, x1, y1.
CASES = [
    dict(name="truck", url=SAM_RAW + "truck.jpg",
         sha256="941715e721c8864324a1425b445ea4dde0498b995c45ddce0141a58971c6ff99", prompts=[
             dict(name="window", points=[[500, 375]], labels=[1]),
             dict(name="door", points=[[1100, 600]], labels=[1]),
             dict(name="wheel box", box=[425, 600, 700, 875]),
             dict(name="tyre: box + bg point on hub", points=[[575, 750]], labels=[0], box=[425, 600, 700, 875]),
         ]),
    dict(name="dog", url=SAM_RAW + "dog.jpg",
         sha256="bf76876b90e3ebd521f9882b9177ba8f33e80cb7ec09c630f179b122edd125e1", prompts=[
             dict(name="dog", points=[[220, 380]], labels=[1]),
             dict(name="bowl", points=[[575, 200]], labels=[1]),
         ]),
    dict(name="groceries", url=SAM_RAW + "groceries.jpg",
         sha256="7073dfecb5a3ecafb6152124113163a0ea1c1c70f92999ec892b519eca63e3d3", prompts=[
             dict(name="paper bag", points=[[544, 280]], labels=[1]),
             dict(name="tail light", points=[[675, 137]], labels=[1]),
         ]),
    dict(name="bus", url=ULTRA_RAW + "bus.jpg",
         sha256="c02019c4979c191eb739ddd944445ef408dad5679acab6fd520ef9d434bfbc63", prompts=[
             dict(name="person left", points=[[127, 574]], labels=[1]),
             dict(name="person middle", points=[[287, 624]], labels=[1]),
             dict(name="bus box", box=[8, 236, 802, 692]),
             dict(name="bus: two points", points=[[300, 480], [620, 600]], labels=[1, 1]),
         ]),
    dict(name="zidane", url=ULTRA_RAW + "zidane.jpg",
         sha256="16d73869e3267a7d4ed00de8e860833bd1657c1b252e94c0c348277adc7b6edb", prompts=[
             dict(name="left man's head", points=[[570, 300]], labels=[1]),
             dict(name="right man: head + jacket", points=[[980, 160], [880, 520]], labels=[1, 1]),
         ]),
    dict(name="neon", url=MSAM_RAW + "picture1.jpg",
         sha256="030574b74080862c4bd0c7664bf9c9bae22db73c7c36b28a82ac48e827b40635", prompts=[
             dict(name="guitar sign", points=[[360, 204]], labels=[1]),
             dict(name="boot sign", points=[[463, 673]], labels=[1]),
         ]),
    dict(name="palace", url=MSAM_RAW + "picture2.jpg",
         sha256="0d4fe99d57830586f4c1b1e22ab0f08bf0ad1aec5b2d67f4d5caefd9f788fa7c", prompts=[
             dict(name="clock tower", points=[[373, 337]], labels=[1]),
             dict(name="red bus", points=[[252, 649]], labels=[1]),
         ]),
    dict(name="street", url=MSAM_RAW + "picture3.jpg",
         sha256="b7c32eb0c29526ac66655abe3db01b4e9684801d36d0004c9478d416798c1806", prompts=[
             dict(name="car", points=[[875, 945]], labels=[1]),
             dict(name="bicycle", points=[[2031, 1015]], labels=[1]),
         ]),
    dict(name="corgi", url=MSAM_RAW + "picture4.jpg",
         sha256="a5062538fc67074179eb884fb1d514854af6e759bc8ac623f94035835472937e", prompts=[
             dict(name="corgi", points=[[1344, 800]], labels=[1]),
         ]),
    dict(name="bears", url=MSAM_RAW + "picture5.jpg",
         sha256="286b3a5693322edf01870a561e35016ed46a7cb4b9194c58e2f3526eab1f9efc", prompts=[
             dict(name="mother bear", points=[[1389, 678]], labels=[1]),
             dict(name="cub", points=[[1292, 872]], labels=[1]),
         ]),
    dict(name="horses", url=MSAM_RAW + "picture6.jpg",
         sha256="bdb5acb53dfc78e74008d113b22f5a2fb1e2c7b33cb8eadf4983d709bfe366ba", prompts=[
             dict(name="white horse", points=[[1088, 896]], labels=[1]),
             dict(name="brown horse", points=[[1792, 896]], labels=[1]),
         ]),
]
FIXTURE_IMAGES = ("truck", "bus")
REPORT_WIDTH = 640


def slug(text: str) -> str:
    return "".join(c if c.isalnum() else "-" for c in text.lower()).strip("-").replace("--", "-")


def reference(pred, prompt):
    """SamPredictor outputs stacked like the decoder's: [4,256,256] logits, [4] scores, and the
    full-resolution boolean masks in the same order."""
    pts = np.array(prompt["points"], np.float32) if prompt.get("points") else None
    labels = np.array(prompt["labels"]) if prompt.get("points") else None
    box = np.array(prompt["box"], np.float32) if prompt.get("box") else None
    m1, s1, l1 = pred.predict(pts, labels, box, multimask_output=False, return_logits=True)
    m3, s3, l3 = pred.predict(pts, labels, box, multimask_output=True, return_logits=True)
    return np.concatenate([l1, l3]), np.concatenate([s1, s3]), np.concatenate([m1, m3]) > 0


def normalised(prompt, w, h):
    points = [(x / w, y / h) for x, y in prompt.get("points", [])]
    box = prompt.get("box")
    box = (box[0] / w, box[1] / h, box[2] / w, box[3] / h) if box else None
    return points, list(prompt.get("labels", [])), box


def rasterize(polygon, w, h):
    import cv2

    out = np.zeros((h, w), np.uint8)
    if len(polygon) >= 3:
        pts = np.round((np.array(polygon) * [w, h] - 0.5) * 16).astype(np.int32)
        cv2.fillPoly(out, [pts], 1, lineType=cv2.LINE_8, shift=4)
    return out.astype(bool)


def render(image, mask, polygon, prompt, title, path):
    from PIL import ImageDraw, ImageFont

    h, w = image.shape[:2]
    scale = min(1.0, REPORT_WIDTH / w)
    tw, th = round(w * scale), round(h * scale)
    base = np.asarray(Image.fromarray(image).resize((tw, th), Image.BILINEAR)).astype(np.float32)
    small = np.asarray(Image.fromarray(mask.astype(np.uint8) * 255).resize((tw, th), Image.BILINEAR)) > 127
    tint = np.array([46, 155, 255], np.float32)
    base[small] = base[small] * 0.55 + tint * 0.45
    im = Image.fromarray(base.clip(0, 255).astype(np.uint8))
    d = ImageDraw.Draw(im)
    if len(polygon) >= 3:
        pts = [(x * tw, y * th) for x, y in polygon]
        d.line(pts + [pts[0]], fill=(255, 196, 0), width=2, joint="curve")
        for x, y in pts:
            d.ellipse([x - 1.5, y - 1.5, x + 1.5, y + 1.5], fill=(255, 196, 0))
    if prompt.get("box"):
        x0, y0, x1, y1 = (v * scale for v in prompt["box"])
        d.rectangle([x0, y0, x1, y1], outline=(0, 230, 230), width=2)
    for (x, y), label in zip(prompt.get("points", []), prompt.get("labels", [])):
        x, y = x * scale, y * scale
        d.ellipse([x - 6, y - 6, x + 6, y + 6], fill=(40, 200, 80) if label == 1 else (235, 50, 50),
                  outline=(255, 255, 255), width=2)
    try:
        font = ImageFont.load_default(size=14)
    except TypeError:  # Pillow < 10.1
        font = ImageFont.load_default()
    box = d.textbbox((0, 0), title, font=font)
    d.rectangle([0, 0, box[2] + 12, box[3] + 10], fill=(0, 0, 0))
    d.text((6, 4), title, fill=(255, 255, 255), font=font)
    im.save(path, quality=80, optimize=True)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models", help="directory with the .mlpackage files (enables the coreml16 column)")
    ap.add_argument("--cache", default=cv.DEFAULT_CACHE)
    ap.add_argument("--report", default=os.path.join(HERE, "report"))
    ap.add_argument("--fixtures", default=os.path.join(HERE, "fixtures"))
    ap.add_argument("--threads", type=int, default=4)
    args = ap.parse_args()

    torch.set_num_threads(args.threads)
    torch.set_grad_enabled(False)
    torch.manual_seed(0)
    sam = cv.load_mobile_sam(args.cache)
    from mobile_sam import SamPredictor  # importable after load_mobile_sam

    pred = SamPredictor(sam)
    enc_eager, dec_eager = cv.build_wrappers(sam, pad_mask=True)
    _, dec_onnx = cv.build_wrappers(sam, pad_mask=False)
    enc, dec = cv.trace(enc_eager, dec_eager)
    x = torch.rand(1, 3, sc.IMG_SIZE, sc.IMG_SIZE) * 255
    trace_diff = (enc(x) - enc_eager(x)).abs().max().item()
    for _ in range(2):  # warm-up for timings
        enc(x)
    mil = None
    if args.models:
        import mil_check

        mil = (mil_check.load_program(os.path.join(args.models, f"{cv.ENCODER_NAME}.mlpackage")),
               mil_check.load_program(os.path.join(args.models, f"{cv.DECODER_NAME}.mlpackage")))
    os.makedirs(args.report, exist_ok=True)
    os.makedirs(args.fixtures, exist_ok=True)
    for stale in os.listdir(args.report):
        if stale.endswith(".jpg"):
            os.remove(os.path.join(args.report, stale))

    rows, timings = [], collections.defaultdict(list)
    fp16_problems: dict = collections.defaultdict(list)
    for case in CASES:
        path = sc.fetch(case["url"], os.path.join(args.cache, "images", f"{case['name']}.jpg"), case["sha256"])
        image = sc.load_rgb(path)
        h, w = image.shape[:2]
        t0 = time.perf_counter()
        pred.set_image(image)
        timings["SamPredictor.set_image (resize + encoder)"].append(time.perf_counter() - t0)
        ref_emb = pred.features

        t0 = time.perf_counter()
        canvas, params = sc.preprocess(image)
        timings["preprocess (resize + pad)"].append(time.perf_counter() - t0)
        canvas_t = torch.from_numpy(canvas).permute(2, 0, 1)[None].float()
        t0 = time.perf_counter()
        app_emb = enc(canvas_t)
        timings["encoder (traced wrapper)"].append(time.perf_counter() - t0)
        emb_diff = (app_emb - ref_emb).abs().max().item()
        alt_canvas, _ = sc.preprocess(image, resample=Image.LANCZOS)  # stand-in for Core Graphics
        alt_emb = enc(torch.from_numpy(alt_canvas).permute(2, 0, 1)[None].float())
        mil_emb = None
        if mil:
            t0 = time.perf_counter()
            out, rep = mil_check.run(mil[0], {"image": canvas.transpose(2, 0, 1)[None].astype(np.float32)}, bounds=True)
            timings["encoder (mil_check fp16 interpreter)"].append(time.perf_counter() - t0)
            mil_emb = out["image_embeddings"]
            for k, v in mil_check.problems(rep).items():
                fp16_problems[k] += v
            mil_corr = float(np.corrcoef(mil_emb.ravel(), ref_emb.numpy().ravel())[0, 1])
        else:
            mil_corr = float("nan")

        fixture = None
        if case["name"] in FIXTURE_IMAGES:
            probes = sc.embedding_probe_indices()
            emb_np = app_emb.numpy()[0]
            fixture = {
                "name": case["name"],
                "generated_by": "tools/sam/evaluate.py (PyTorch fp32, traced wrappers)",
                "mobile_sam_commit": cv.MOBILE_SAM_COMMIT,
                "image": {"url": case["url"], "sha256": case["sha256"], "width": w, "height": h},
                "preprocess": {
                    "image_size": sc.IMG_SIZE, "resized_width": params["resized_width"],
                    "resized_height": params["resized_height"], "pad_rgb": list(sc.PAD_RGB),
                    "resample": "PIL.Image.BILINEAR", "placement": "top-left",
                    "pixel_mean": list(sc.PIXEL_MEAN), "pixel_std": list(sc.PIXEL_STD),
                },
                "embedding_probes": {"indices": probes,
                                     "values": [round(float(emb_np[c, y, x]), 5) for c, y, x in probes]},
                "prompts": [],
            }

        for prompt in case["prompts"]:
            points, labels, box = normalised(prompt, w, h)
            coords, lab = sc.pack_prompt(points, labels, box, params)
            coords_t, lab_t = torch.from_numpy(coords), torch.from_numpy(lab)
            ref_logits, ref_scores, ref_full = reference(pred, prompt)
            k = sc.choose_mask(ref_scores, labels, box is not None)

            m_dec, s_dec = dec(ref_emb, coords_t, lab_t)
            m_dec, s_dec = m_dec[0].numpy(), s_dec[0].numpy()
            t0 = time.perf_counter()
            m_app, s_app = dec(app_emb, coords_t, lab_t)
            timings["decoder (traced wrapper)"].append(time.perf_counter() - t0)
            m_app, s_app = m_app[0].numpy(), s_app[0].numpy()
            m_onnx, _ = dec_onnx(ref_emb, coords_t, lab_t)
            m_onnx = m_onnx[0].numpy()
            k_app = sc.choose_mask(s_app, labels, box is not None)
            m_alt, _ = dec(alt_emb, coords_t, lab_t)
            resample_iou = sc.iou(m_alt[0, k_app].numpy() > 0, m_app[k_app] > 0)

            t0 = time.perf_counter()
            polygon, area = sc.mask_to_polygon(m_app[k_app], params)
            timings["postprocess (mask -> polygon)"].append(time.perf_counter() - t0)
            up = sc.upsample_logits(m_app[k_app], params) > 0
            contour = sc.largest_contour(np.where(up, 255, 0).astype(np.uint8))
            out_w, out_h = sc.work_size(params)
            contour_poly = [(x / out_w, y / out_h) for x, y in contour]

            row = dict(
                image=case["name"], prompt=prompt["name"], mode="multimask" if k > 0 else "single", k=k,
                k_app=k_app, score=float(ref_scores[k]), area=area, vertices=len(polygon),
                dec_maxdiff=float(np.abs(m_dec - ref_logits).max()),
                dec_iou=sc.iou(m_dec[k] > 0, ref_logits[k] > 0),
                dec_dscore=float(np.abs(s_dec - ref_scores).max()),
                app_iou=sc.iou(m_app[k] > 0, ref_logits[k] > 0),
                app_dscore=float(np.abs(s_app - ref_scores).max()),
                onnx_iou=sc.iou(m_onnx[k] > 0, ref_logits[k] > 0),
                contour_iou=sc.iou(rasterize(contour_poly, w, h), ref_full[k]),
                outline_iou=sc.iou(rasterize(polygon, w, h), ref_full[k]),
                emb_diff=emb_diff, mil_corr=mil_corr, resample_iou=resample_iou,
            )
            if mil_emb is not None:
                t0 = time.perf_counter()
                o, rep = mil_check.run(mil[1], {"image_embeddings": mil_emb, "point_coords": coords,
                                                "point_labels": lab}, bounds=True)
                timings["decoder (mil_check fp16 interpreter)"].append(time.perf_counter() - t0)
                for kk, v in mil_check.problems(rep).items():
                    fp16_problems[kk] += v
                m_mil, s_mil = o["masks"][0], o["scores"][0]
                row.update(mil_iou=sc.iou(m_mil[k] > 0, ref_logits[k] > 0),
                           mil_dscore=float(np.abs(s_mil - ref_scores).max()),
                           mil_k=sc.choose_mask(s_mil, labels, box is not None),
                           mil_iou64=sc.iou(sc.mask64_from_logits(m_mil[k_app]), sc.mask64_from_logits(m_app[k_app])))
            rows.append(row)

            file = f"{case['name']}_{slug(prompt['name'])}.jpg"
            title = (f"{case['name']} / {prompt['name']}: mask {k_app} score {s_app[k_app]:.3f}, "
                     f"outline IoU {row['outline_iou']:.3f}, {len(polygon)} pts")
            render(image, ref_full[k], polygon, prompt, title, os.path.join(args.report, file))
            row["file"] = file

            if fixture is not None:
                fixture["prompts"].append({
                    "name": prompt["name"],
                    "points": [[round(x, 6), round(y, 6)] for x, y in points], "labels": labels,
                    "box": [round(v, 6) for v in box] if box else None,
                    "point_coords": [[[round(float(v), 4) for v in pt] for pt in coords[0]]],
                    "point_labels": [[float(v) for v in lab[0]]],
                    "chosen": k_app,
                    "scores": sc.round_list(s_app),
                    "mask64": [sc.encode_mask64(sc.mask64_from_logits(m_app[i])) for i in range(4)],
                    "area256": [round(float((m_app[i] > 0).mean()), 5) for i in range(4)],
                    "sampredictor": {"chosen": k, "scores": sc.round_list(ref_scores),
                                     "iou_chosen_256": round(row["app_iou"], 5)},
                })
        if fixture is not None:
            with open(os.path.join(args.fixtures, f"{case['name']}.json"), "w") as f:
                json.dump(fixture, f, indent=1)
                f.write("\n")
        print(f"{case['name']}: {len(case['prompts'])} prompts, emb max|d| {emb_diff:.2e}", flush=True)

    write_report(args.report, rows, timings, fp16_problems, trace_diff, mil is not None)


def write_report(report_dir, rows, timings, fp16_problems, trace_diff, has_mil):
    def ms(key):
        v = timings.get(key)
        return f"{statistics.median(v) * 1000:.0f}" if v else "n/a"

    def worst(key, fn=min):
        vals = [r[key] for r in rows if key in r]
        return fn(vals) if vals else float("nan")

    lines = [
        "# MobileSAM on Lensi: verification report",
        "",
        "Generated by `tools/sam/evaluate.py`. Reference = MobileSAM's own `SamPredictor` (unpatched "
        "model, fp32) on the original image. The app pipeline is the one `SAMSegmenter.swift` runs: "
        "long side resized to 1024, top-left on a mean-colour (124,116,104) canvas, "
        "`LensiSAMEncoder` -> `LensiSAMDecoder` with 5 prompt slots -> mask choice -> "
        "`sam_common.mask_to_polygon`.",
        "",
        "Tint = SAM's full-resolution mask (reference), yellow line = the app's simplified polygon, "
        "green/red dots = positive/negative clicks, cyan = box prompt.",
        "",
        "## Summary",
        "",
        f"- Prompts: {len(rows)} on {len({r['image'] for r in rows})} images.",
        f"- Decoder wrapper vs SamPredictor on the same embedding: worst max|logit diff| "
        f"{worst('dec_maxdiff', max):.2e}, worst mask IoU {worst('dec_iou'):.4f}, worst score diff "
        f"{worst('dec_dscore', max):.2e}.",
        f"- Traced encoder vs eager: max diff {trace_diff:.1e}. App canvas (rounded mean padding) vs "
        f"SamPredictor's exact zero padding: worst embedding max|diff| {worst('emb_diff', max):.4f}.",
        f"- App pipeline in fp32 (canvas -> encoder -> decoder) vs SamPredictor: worst mask IoU "
        f"{worst('app_iou'):.4f}, worst score diff {worst('app_dscore', max):.4f}.",
    ]
    if has_mil:
        lines += [
            f"- Converted Core ML programs, executed by `mil_check.py` with float16 storage: worst "
            f"mask IoU vs SamPredictor {worst('mil_iou'):.4f}, worst score diff {worst('mil_dscore', max):.4f}, "
            f"worst embedding correlation {worst('mil_corr'):.6f}, worst 64x64 fixture-style IoU vs "
            f"fp32 {worst('mil_iou64'):.4f}; mask choice differs from fp32 on "
            f"{sum(r['mil_k'] != r['k_app'] for r in rows)} prompt(s).",
            "- float16 hazards found in the converted graphs: "
            + ("none (no overflow, no non-finite values, all partial-sum bounds < 65504)."
               if not fp16_problems else "; ".join(f"{k}: {len(v)}" for k, v in fp16_problems.items())),
        ]
    lines += [
        f"- Plain ONNX padding (every -1 slot visible) vs SamPredictor: worst mask IoU "
        f"{worst('onnx_iou'):.4f}. That is why `LensiSAMDecoder` hides surplus padding slots.",
        f"- Outline (app polygon vs SAM's full-res mask): median IoU "
        f"{statistics.median(r['outline_iou'] for r in rows):.3f}, worst {worst('outline_iou'):.3f}; "
        f"largest contour before simplification: median {statistics.median(r['contour_iou'] for r in rows):.3f}. "
        f"Median {statistics.median(r['vertices'] for r in rows):.0f} vertices.",
        f"- Resize filter sensitivity (the phone resizes with Core Graphics, not Pillow bilinear): a "
        f"Lanczos canvas moves the chosen mask by IoU {statistics.median(r['resample_iou'] for r in rows):.3f} "
        f"median; lowest " + ", ".join(
            f"{r['image']} / {r['prompt']} {r['resample_iou']:.3f}"
            for r in sorted(rows, key=lambda r: r['resample_iou'])[:2])
        + ". That is SAM's own sensitivity on ambiguous or thin objects, not a conversion error"
        + (f" (float16 worst is {worst('mil_iou'):.3f})" if has_mil else "")
        + ", and phone outlines can differ from this report by that much on such prompts.",
        "",
        "## Notes",
        "",
        "- One polygon per mask: the largest region's outer boundary. Holes are filled and smaller "
        "regions dropped, which is what the two low outline IoUs are: truck / tyre (the hub the "
        "negative click cut out is filled back in) and palace / red bus (a palm trunk splits the bus "
        "and only the larger part is outlined). The contour column is the same outline before "
        "simplification, so contour minus outline is the cost of the 0.3%-of-perimeter "
        "Douglas-Peucker step.",
        "- The coreml16 column runs the converted programs op by op in numpy with every float16 "
        "intermediate rounded to float16 (`mil_check.py`). That models fp16 storage, not the Neural "
        "Engine's own arithmetic; `verify_coreml.py` on macOS is the real check.",
        "- The masks are tinted from SamPredictor's output, so a gap between tint and yellow line is "
        "postprocessing, not model error.",
        "",
        "## Timings (median, CPU, PyTorch fp32, 4 threads on the Linux build box; not iPhone numbers)",
        "",
        "| step | ms |",
        "|---|---|",
    ]
    for key in ["preprocess (resize + pad)", "encoder (traced wrapper)", "decoder (traced wrapper)",
                "postprocess (mask -> polygon)", "SamPredictor.set_image (resize + encoder)",
                "encoder (mil_check fp16 interpreter)", "decoder (mil_check fp16 interpreter)"]:
        if key in timings:
            lines.append(f"| {key} | {ms(key)} |")
    lines += [
        "",
        "## Per prompt",
        "",
        "IoUs are on the 256x256 low-res mask at SamPredictor's chosen index unless noted; "
        "outline IoU is the app polygon rasterised at full resolution vs SAM's full-res mask.",
        "",
        "| image | prompt | mask | score | area | pts | outline IoU | contour IoU | decoder max\\|d\\| | app fp32 IoU |"
        + (" coreml16 IoU | coreml16 d score |" if has_mil else "") + " onnx-pad IoU | Lanczos IoU |",
        "|---|---|---|---|---|---|---|---|---|---|" + ("---|---|" if has_mil else "") + "---|---|",
    ]
    for r in rows:
        mask = f"{r['k_app']} ({r['mode']})"
        line = (f"| {r['image']} | [{r['prompt']}]({r['file']}) | {mask} | {r['score']:.3f} | {r['area'] * 100:.1f}% "
                f"| {r['vertices']} | {r['outline_iou']:.3f} | {r['contour_iou']:.3f} | {r['dec_maxdiff']:.1e} "
                f"| {r['app_iou']:.4f} |")
        if has_mil:
            line += f" {r['mil_iou']:.4f} | {r['mil_dscore']:.4f} |"
        line += f" {r['onnx_iou']:.3f} | {r['resample_iou']:.3f} |"
        lines.append(line)
    lines += ["", "## Overlays", ""]
    for r in rows:
        lines.append(f"![{r['image']} {r['prompt']}]({r['file']})")
    with open(os.path.join(report_dir, "README.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(report_dir, "results.json"), "w") as f:
        json.dump({"rows": rows, "timings_ms": {k: [round(v * 1000, 1) for v in vs] for k, vs in timings.items()},
                   "fp16_problems": {k: len(v) for k, v in fp16_problems.items()}}, f, indent=1)
        f.write("\n")
    print("\n".join(lines[:40]))


if __name__ == "__main__":
    main()
