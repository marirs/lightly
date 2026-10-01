"""Desktop parity of converted artifacts vs PyTorch, on every golden input256.f32 (Apple M4, macOS).

Weight error alone is hard to interpret, so it is propagated: max 8-bit pixel difference between the
reference LUT result and the result using the converted model's weights, on a 1/4-scale source.
Also: preprocessing sensitivity = upstream full-res bilinear path vs deployment antialiased-256 path.
"""
import json, os, time
import numpy as np, coremltools as ct, onnxruntime as ort
from PIL import Image
import ia3dlut as ia

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
m = ia.load_reference_model(os.path.join(root, "reference/upstream/pretrained_models/sRGB"))
cfgs = {}
for tag in ("fp32", "fp16"):
    for cu_name, cu in (("cpu", ct.ComputeUnit.CPU_ONLY), ("gpu", ct.ComputeUnit.CPU_AND_GPU), ("ane", ct.ComputeUnit.CPU_AND_NE)):
        t0 = time.perf_counter()
        cfgs[f"coreml_{tag}_{cu_name}"] = ("ml", ct.models.MLModel(os.path.join(root, f"models/ia3dlut_classifier_{tag}.mlpackage"), compute_units=cu), time.perf_counter() - t0)
t0 = time.perf_counter()
cfgs["onnxruntime_cpu"] = ("ort", ort.InferenceSession(os.path.join(root, "models/ia3dlut_classifier.onnx"), providers=["CPUExecutionProvider"]), time.perf_counter() - t0)

def pixel_err(src_small, w_a, w_b):
    a = ia.to_uint8(ia.apply_lut_reference(ia.fuse_luts(m.basis_luts, w_a), src_small, 1.0))
    b = ia.to_uint8(ia.apply_lut_reference(ia.fuse_luts(m.basis_luts, w_b), src_small, 1.0))
    return int(np.abs(a.astype(int) - b.astype(int)).max())

summary = {k: {"load_s": round(v[2], 3), "max_w_err": 0.0, "max_px_err": 0, "median_ms": []} for k, v in cfgs.items()}
pre = {"max_w_err": 0.0, "max_px_err": 0, "worst": None}
for stem in sorted(os.listdir(os.path.join(root, "golden"))):
    d = os.path.join(root, "golden", stem)
    if not os.path.isdir(d): continue
    meta = json.load(open(os.path.join(d, "meta.json")))
    w_ref = np.array(meta["weights_deploy"], np.float32)
    x = np.fromfile(os.path.join(d, "input256.f32"), np.float32).reshape(1, 3, 256, 256)
    src = np.asarray(Image.open(os.path.join(d, "source.png")).convert("RGB"))[::4, ::4].astype(np.float32) / 255
    for k, (kind, mdl, _) in cfgs.items():
        times = []
        for _ in range(6):
            t0 = time.perf_counter()
            w = mdl.predict({"image": x})["weights"].reshape(3) if kind == "ml" else mdl.run(None, {"image": x})[0].reshape(3)
            times.append((time.perf_counter() - t0) * 1000)
        s = summary[k]
        s["max_w_err"] = max(s["max_w_err"], float(np.abs(w - w_ref).max()))
        s["max_px_err"] = max(s["max_px_err"], pixel_err(src, w_ref, w))
        s["median_ms"].append(float(np.median(times[1:])))
    w_up = np.array(meta["weights_upstream_fullres"], np.float32)
    e = float(np.abs(w_up - w_ref).max()); px = pixel_err(src, w_ref, w_up)
    if px > pre["max_px_err"]: pre.update(max_px_err=px, worst=stem)
    pre["max_w_err"] = max(pre["max_w_err"], e)
for s in summary.values():
    s["median_ms"] = round(float(np.median(s["median_ms"])), 3); s["max_w_err"] = round(s["max_w_err"], 5)
out = {"hardware": "Apple M4 Mac (desktop) - NOT phone performance", "configs": summary,
       "preprocessing_upstream_fullres_vs_deploy_aa256": pre}
json.dump(out, open(os.path.join(root, "report", "desktop_parity.json"), "w"), indent=2)
print(json.dumps(out, indent=2))
