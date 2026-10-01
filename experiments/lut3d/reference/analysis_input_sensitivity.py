"""Codex M1 finding 2: how much do Auto weights / output depend on the analysis-input path?

Paths compared against the canonical definition C (full decoded frame -> antialiased resize to 256x256):
  proxy_N: frame first reduced to an N-px long edge (Lanczos, like a screen-sized proxy), then -> 256
  lsb:     +-1 LSB random perturbation of the decoded frame (models decoder differences), then -> 256
Effect is reported as max |dw| and max 8-bit pixel difference of the resulting Auto output.
"""
import glob, json, os
import numpy as np
from PIL import Image
import ia3dlut as ia

HERE = os.path.dirname(os.path.abspath(__file__))
m = ia.load_reference_model(os.path.join(HERE, "upstream/pretrained_models/sRGB"))
rng = np.random.default_rng(0)
rows = {k: [] for k in ("proxy_2732", "proxy_2048", "proxy_1024", "proxy_512", "lsb")}
for d in sorted(glob.glob(os.path.join(HERE, "../golden/*/")))[:23]:
    src = np.asarray(Image.open(d + "source.png").convert("RGB"))
    w0 = ia.predict_weights_from_256(m, ia.prepare_256_antialiased(src))
    test = (src[::8, ::8].astype(np.float32) / 255)
    out0 = ia.apply_lut_reference(ia.fuse_luts(m.basis_luts, w0), test, 1.0)
    variants = {}
    for n in (2732, 2048, 1024, 512):
        s = n / max(src.shape[:2])
        variants[f"proxy_{n}"] = np.asarray(Image.fromarray(src).resize((round(src.shape[1] * s), round(src.shape[0] * s)), Image.LANCZOS))
    variants["lsb"] = np.clip(src.astype(np.int16) + rng.integers(-1, 2, src.shape), 0, 255).astype(np.uint8)
    for k, img in variants.items():
        w = ia.predict_weights_from_256(m, ia.prepare_256_antialiased(img))
        out = ia.apply_lut_reference(ia.fuse_luts(m.basis_luts, w), test, 1.0)
        rows[k].append((float(np.abs(w - w0).max()), float(np.abs(ia.to_uint8(out).astype(int) - ia.to_uint8(out0).astype(int)).max())))
res = {k: {"max_dw": round(max(r[0] for r in v), 4), "max_px": max(r[1] for r in v)} for k, v in rows.items()}
json.dump(res, open(os.path.join(HERE, "../report/analysis_input_sensitivity.json"), "w"), indent=1)
print(json.dumps(res, indent=1))
