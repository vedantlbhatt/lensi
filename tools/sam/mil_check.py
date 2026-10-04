"""Numpy interpreter for the MIL programs in LensiSAMEncoder/Decoder.mlpackage.

Core ML cannot run on Linux, so this executes the converted program op by op instead. It covers
exactly the ops these two models use. With fp16=True every float16 intermediate is rounded to
float16 (each op computes in float32), which emulates fp16 storage on the GPU / Neural Engine,
and the report lists anything that would break there:

  * non-finite float16 values (overflow past 65504, NaN),
  * reductions / layer norms whose sums leave float16 range,
  * layer norms whose var + eps falls below float16's normal range (eps flushed -> 0/0),
  * linear / matmul / conv outputs whose partial-sum bound sum(|x| * |w|) exceeds float16
    (only with bounds=True), i.e. an fp16 accumulator could overflow in some order.

Used by evaluate.py; also handy after any reconversion:
    python tools/sam/mil_check.py --models OUT_DIR --image some.jpg
"""

from __future__ import annotations

import argparse
import collections
import math
import os
import sys

import numpy as np

FP16_MAX = 65504.0
FP16_MIN_NORMAL = 6.103515625e-05


def load_program(path: str):
    import coremltools as ct
    from coremltools.converters.mil.frontend.milproto.load import load as milproto_load

    model = ct.models.MLModel(path, skip_model_load=True)
    spec = model.get_spec()
    return milproto_load(spec, specification_version=spec.specificationVersion,
                         file_weights_dir=model.weights_dir)


def _np_dtype(var):
    from coremltools.converters.mil.mil import types

    t = var.dtype
    if types.is_tensor(t):
        t = t.get_primitive()
    return types.nptype_from_builtin(t)


def _scalar(x):
    x = np.asarray(x)
    return x.item() if x.size == 1 else x


def _ints(x) -> list[int]:
    return [int(v) for v in np.asarray(x).reshape(-1)]


def _erf(x: np.ndarray) -> np.ndarray:
    """Abramowitz & Stegun 7.1.26 (|error| < 1.5e-7, far below float16 resolution)."""
    s = np.sign(x)
    a = np.abs(x)
    t = 1.0 / (1.0 + 0.3275911 * a)
    y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t
               + 0.254829592) * t * np.exp(-a * a)
    return s * y


def _conv2d(x, w, b, strides, pads, dil, groups):
    n, cin, h, wd = x.shape
    cout, cin_g, kh, kw = w.shape
    sh, sw = strides
    dh, dw = dil
    pt, pb, pl, pr = pads
    xp = np.pad(x, ((0, 0), (0, 0), (pt, pb), (pl, pr)))
    oh = (h + pt + pb - dh * (kh - 1) - 1) // sh + 1
    ow = (wd + pl + pr - dw * (kw - 1) - 1) // sw + 1
    out = np.zeros((n, cout, oh, ow), np.float32)

    def window(src, i, j):
        return src[:, :, i * dh: i * dh + sh * (oh - 1) + 1: sh, j * dw: j * dw + sw * (ow - 1) + 1: sw]

    if groups == cin == cout and cin_g == 1:  # depthwise
        for i in range(kh):
            for j in range(kw):
                out += window(xp, i, j) * w[None, :, 0, i, j, None, None]
    else:
        cout_g = cout // groups
        for g in range(groups):
            xg = xp[:, g * cin_g:(g + 1) * cin_g]
            wg = w[g * cout_g:(g + 1) * cout_g]
            for i in range(kh):
                for j in range(kw):
                    out[:, g * cout_g:(g + 1) * cout_g] += np.einsum(
                        "nchw,oc->nohw", window(xg, i, j), wg[:, :, i, j], optimize=True)
    if b is not None:
        out += b[None, :, None, None]
    return out


def run(prog, feeds: dict, fp16: bool = True, bounds: bool = False, report=None):
    """Executes prog's main function. Returns ({output name: float32 array}, report), where
    report maps a problem description to a list of (op name, value) entries."""
    func = prog.functions["main"]
    rep = report if report is not None else collections.defaultdict(list)
    env = {name: np.asarray(feeds[name]).astype(_np_dtype(var)) for name, var in func.inputs.items()}

    def flag(kind, op, value):
        rep[kind].append((op.name, float(value)))

    def note_max(kind, value):
        prev = rep[kind][0][1] if rep.get(kind) else 0.0
        rep[kind] = [("all ops", max(prev, float(value)))]

    for op in func.operations:
        t = op.op_type
        if t == "const":
            continue
        a = {}
        for k, v in op.inputs.items():
            if isinstance(v, (list, tuple)):
                a[k] = [np.asarray(x.val) if x.val is not None else env[x.name] for x in v]
            else:
                a[k] = np.asarray(v.val) if v.val is not None else env[v.name]

        def f32(name):
            return np.asarray(a[name]).astype(np.float32)

        if t == "cast":
            target = str(_scalar(a["dtype"]))
            if target == "fp16" and not fp16:
                target = "fp32"
            res = [np.asarray(a["x"]).astype(
                {"fp16": np.float16, "fp32": np.float32, "int32": np.int32, "bool": bool}[target])]
        elif t in ("add", "sub", "mul", "real_div", "pow", "maximum", "minimum"):
            fn = {"add": np.add, "sub": np.subtract, "mul": np.multiply, "real_div": np.divide,
                  "pow": np.power, "maximum": np.maximum, "minimum": np.minimum}[t]
            with np.errstate(over="ignore", invalid="ignore", divide="ignore"):
                res = [fn(f32("x"), f32("y"))]
        elif t in ("equal", "not_equal", "less", "greater", "less_equal", "greater_equal"):
            fn = {"equal": np.equal, "not_equal": np.not_equal, "less": np.less,
                  "greater": np.greater, "less_equal": np.less_equal,
                  "greater_equal": np.greater_equal}[t]
            res = [fn(np.asarray(a["x"]), np.asarray(a["y"]))]
        elif t in ("conv", "conv_transpose"):
            x, w = f32("x"), f32("weight")
            b = f32("bias") if "bias" in a else None
            strides = _ints(a.get("strides", [1, 1]))
            dil = _ints(a.get("dilations", [1, 1]))
            groups = int(_scalar(a.get("groups", 1)))
            pad_type = str(_scalar(a.get("pad_type", "valid")))
            pads = _ints(a["pad"]) if pad_type == "custom" else [0, 0, 0, 0]
            if pad_type not in ("custom", "valid"):
                raise NotImplementedError(f"conv pad_type {pad_type}")
            if t == "conv":
                res = [_conv2d(x, w, b, strides, pads, dil, groups)]
                if fp16 and bounds:
                    bound = _conv2d(np.abs(x), np.abs(w), None if b is None else np.abs(b),
                                    strides, pads, dil, groups).max()
                    note_max("max partial-sum bound (conv)", bound)
                    if bound > FP16_MAX:
                        flag("conv partial-sum bound > fp16 max", op, bound)
            else:
                # Only the kernel == stride, no-padding case SAM's output_upscaling uses.
                n, cin, h, wd = x.shape
                _, cout, kh, kw = w.shape  # [C_in, C_out, kH, kW]
                if groups != 1 or pads != [0, 0, 0, 0] or [kh, kw] != strides:
                    raise NotImplementedError("conv_transpose variant")
                y = np.einsum("nchw,cokl->nohkwl", x, w, optimize=True).reshape(n, cout, h * kh, wd * kw)
                res = [y if b is None else y + b[None, :, None, None]]
        elif t == "gelu":
            x = f32("x").astype(np.float64)
            mode = str(_scalar(a.get("mode", "EXACT")))
            if mode == "EXACT":
                y = 0.5 * x * (1 + _erf(x / math.sqrt(2)))
            elif mode == "TANH_APPROXIMATION":
                y = 0.5 * x * (1 + np.tanh(math.sqrt(2 / math.pi) * (x + 0.044715 * x ** 3)))
            else:
                y = x / (1 + np.exp(-1.702 * x))
            res = [y.astype(np.float32)]
        elif t == "relu":
            res = [np.maximum(f32("x"), 0)]
        elif t in ("sqrt", "sin", "cos", "exp", "abs", "tanh"):
            fn = {"sqrt": np.sqrt, "sin": np.sin, "cos": np.cos, "exp": np.exp, "abs": np.abs,
                  "tanh": np.tanh}[t]
            with np.errstate(over="ignore", invalid="ignore"):
                res = [fn(f32("x"))]
        elif t == "rsqrt":
            # The encoder's channel norms: rsqrt(var + eps). Same hazard as layer_norm's eps.
            x = f32("x") + float(_scalar(a.get("epsilon", 1e-12)))
            if fp16 and (x < FP16_MIN_NORMAL).any():
                flag("rsqrt input below fp16 normal range", op, x.min())
            with np.errstate(divide="ignore", invalid="ignore"):
                res = [1.0 / np.sqrt(x)]
        elif t == "reshape":
            res = [np.asarray(a["x"]).reshape(_ints(a["shape"]))]
        elif t == "transpose":
            res = [np.transpose(np.asarray(a["x"]), _ints(a["perm"]))]
        elif t == "expand_dims":
            x = np.asarray(a["x"])
            for ax in sorted(_ints(a["axes"])):
                x = np.expand_dims(x, ax)
            res = [x]
        elif t == "squeeze":
            axes = tuple(_ints(a["axes"])) if "axes" in a else None
            res = [np.squeeze(np.asarray(a["x"]), axis=axes)]
        elif t == "pad":
            x = np.asarray(a["x"])
            p = _ints(a["pad"])
            if str(_scalar(a.get("mode", "constant"))) != "constant":
                raise NotImplementedError("pad mode")
            k = len(p) // 2  # pads the last k dims, (before, after) pairs in dim order
            widths = [(0, 0)] * (x.ndim - k) + [(p[2 * i], p[2 * i + 1]) for i in range(k)]
            res = [np.pad(x, widths, constant_values=float(_scalar(a.get("constant_val", 0.0))))]
        elif t == "layer_norm":
            x = f32("x")
            axes = tuple(_ints(a["axes"]))
            eps = np.float32(_scalar(a.get("epsilon", 1e-5)))
            if fp16:
                eps = np.float32(np.float16(eps))
            u = x.mean(axis=axes, keepdims=True)
            d2 = (x - u) ** 2
            if fp16:
                if d2.max() > FP16_MAX:
                    flag("layer_norm (x-mean)^2 > fp16 max", op, d2.max())
                total = d2.sum(axis=axes).max()
                if total > FP16_MAX:
                    flag("layer_norm sum((x-mean)^2) > fp16 max", op, total)
            var = d2.mean(axis=axes, keepdims=True)
            if fp16 and (var + eps).min() < FP16_MIN_NORMAL:
                flag("layer_norm var+eps < fp16 normal range (NaN if eps is flushed)", op, (var + eps).min())
            y = (x - u) / np.sqrt(var + eps)
            if "gamma" in a:
                y = y * f32("gamma")
            if "beta" in a:
                y = y + f32("beta")
            res = [y]
        elif t == "batch_norm":
            x = f32("x")
            shape = [1, -1] + [1] * (x.ndim - 2)
            eps = np.float32(_scalar(a.get("epsilon", 1e-5)))
            y = (x - f32("mean").reshape(shape)) / np.sqrt(f32("variance").reshape(shape) + eps)
            if "gamma" in a:
                y = y * f32("gamma").reshape(shape)
            if "beta" in a:
                y = y + f32("beta").reshape(shape)
            res = [y]
        elif t in ("linear", "matmul"):
            if t == "linear":
                x, y = f32("x"), f32("weight").T
            else:
                x, y = f32("x"), f32("y")
                if bool(_scalar(a.get("transpose_x", False))):
                    x = np.swapaxes(x, -1, -2)
                if bool(_scalar(a.get("transpose_y", False))):
                    y = np.swapaxes(y, -1, -2)
            out = np.matmul(x, y)
            if t == "linear" and "bias" in a:
                out = out + f32("bias")
            res = [out]
            if fp16 and bounds:
                bound = np.matmul(np.abs(x), np.abs(y)).max()
                note_max(f"max partial-sum bound ({t})", bound)
                if bound > FP16_MAX:
                    flag(f"{t} partial-sum bound > fp16 max", op, bound)
        elif t == "softmax":
            x = f32("x")
            ax = int(_scalar(a.get("axis", -1)))
            e = np.exp(x - x.max(axis=ax, keepdims=True))
            res = [e / e.sum(axis=ax, keepdims=True)]
        elif t == "split":
            x = np.asarray(a["x"])
            ax = int(_scalar(a["axis"]))
            if "split_sizes" in a:
                res = np.split(x, np.cumsum(_ints(a["split_sizes"]))[:-1], axis=ax)
            else:
                res = np.split(x, int(_scalar(a["num_splits"])), axis=ax)
        elif t == "slice_by_index":
            x = np.asarray(a["x"])
            nd = x.ndim
            begin, end = _ints(a["begin"]), _ints(a["end"])
            stride = _ints(a["stride"]) if "stride" in a else [1] * nd
            bmask = [bool(v) for v in np.asarray(a.get("begin_mask", [False] * nd)).reshape(-1)]
            emask = [bool(v) for v in np.asarray(a.get("end_mask", [False] * nd)).reshape(-1)]
            smask = [bool(v) for v in np.asarray(a.get("squeeze_mask", [False] * nd)).reshape(-1)]
            index = []
            for i in range(nd):
                if smask[i]:
                    index.append(begin[i])
                else:
                    index.append(slice(None if bmask[i] else begin[i], None if emask[i] else end[i], stride[i]))
            res = [x[tuple(index)]]
        elif t in ("reduce_mean", "reduce_max", "reduce_sum", "reduce_min"):
            x = f32("x")
            axes = tuple(_ints(a["axes"])) if "axes" in a else None
            keep = bool(_scalar(a.get("keep_dims", False)))
            if t in ("reduce_mean", "reduce_sum") and fp16:
                total = np.abs(x.sum(axis=axes)).max()
                if total > FP16_MAX:
                    flag(f"{t} |sum| > fp16 max", op, total)
            fn = {"reduce_mean": np.mean, "reduce_max": np.max, "reduce_sum": np.sum,
                  "reduce_min": np.min}[t]
            res = [fn(x, axis=axes, keepdims=keep)]
        elif t == "concat":
            res = [np.concatenate([np.asarray(v) for v in a["values"]], axis=int(_scalar(a["axis"])))]
        elif t == "stack":
            res = [np.stack([np.asarray(v) for v in a["values"]], axis=int(_scalar(a["axis"])))]
        elif t == "clip":
            res = [np.clip(f32("x"), float(_scalar(a["alpha"])), float(_scalar(a["beta"])))]
        elif t == "tile":
            res = [np.tile(np.asarray(a["x"]), _ints(a["reps"]))]
        elif t == "select":
            res = [np.where(np.asarray(a["cond"]).astype(bool), f32("a"), f32("b"))]
        else:
            raise NotImplementedError(f"MIL op {t} is not implemented in mil_check.py")

        for var, value in zip(op.outputs, res):
            dt = _np_dtype(var)
            if dt == np.float16 and not fp16:
                dt = np.float32
            with np.errstate(over="ignore", invalid="ignore"):
                arr = np.asarray(value).astype(dt)
            if fp16 and dt == np.float16 and not np.isfinite(arr).all():
                flag(f"non-finite fp16 output ({t})", op, (~np.isfinite(arr)).sum())
            if var.shape is not None and tuple(arr.shape) != tuple(var.shape):
                raise RuntimeError(f"{t} {op.name}: got shape {arr.shape}, program says {var.shape}")
            env[var.name] = arr
    return {v.name: np.asarray(env[v.name]).astype(np.float32) for v in func.outputs}, rep


def problems(report) -> dict:
    """The report entries that are actual problems (not the informational maxima)."""
    return {k: v for k, v in report.items() if not k.startswith("max ")}


def main() -> None:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import sam_common as sc

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models", required=True, help="directory with the two .mlpackage files")
    ap.add_argument("--image", required=True)
    ap.add_argument("--point", type=float, nargs=2, default=[0.5, 0.5], help="normalised x y")
    args = ap.parse_args()

    canvas, params = sc.preprocess(sc.load_rgb(args.image))
    enc = load_program(os.path.join(args.models, "LensiSAMEncoder.mlpackage"))
    dec = load_program(os.path.join(args.models, "LensiSAMDecoder.mlpackage"))
    rep = collections.defaultdict(list)
    out, rep = run(enc, {"image": canvas.transpose(2, 0, 1)[None].astype(np.float32)}, bounds=True, report=rep)
    coords, labels = sc.pack_prompt([tuple(args.point)], [1], None, params)
    res, rep = run(dec, {"image_embeddings": out["image_embeddings"], "point_coords": coords,
                         "point_labels": labels}, bounds=True, report=rep)
    k = sc.choose_mask(res["scores"][0], [1], False)
    print(f"scores {np.round(res['scores'][0], 4)}, chosen mask {k}, "
          f"area {(res['masks'][0, k] > 0).mean():.3f} of the 256 grid")
    for key, entries in rep.items():
        print(f"{key}: {entries[:4]}{' ...' if len(entries) > 4 else ''}")
    sys.exit(1 if problems(rep) else 0)


if __name__ == "__main__":
    main()
