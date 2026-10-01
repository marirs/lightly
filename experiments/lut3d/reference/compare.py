"""Comparison sheets and objective statistics: original vs Auto (100%) vs Auto (50% strength).

No ground truth exists for these photos, so stats describe WHAT the model changes, not whether it is better:
  L* mean / p5 / p95 (CIELAB, D65), chroma mean, highlight/shadow clipping (any channel >=254 / all <=1),
  mean CIEDE2000 between original and result.
Sheets: report/sheets/<stem>.jpg (each panel 640 px long edge). Summary: report/auto_stats.csv
"""
import csv, json, os
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from skimage import color
import ia3dlut as ia

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
gold = os.path.join(root, "golden")
sheets = os.path.join(root, "report", "sheets")
os.makedirs(sheets, exist_ok=True)
model = ia.load_reference_model(os.path.join(root, "reference/upstream/pretrained_models/sRGB"))
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)

def stats(rgb8):
    small = np.asarray(Image.fromarray(rgb8).resize((rgb8.shape[1] // 4, rgb8.shape[0] // 4), Image.BILINEAR))
    lab = color.rgb2lab(small)
    L = lab[..., 0]; C = np.hypot(lab[..., 1], lab[..., 2])
    return lab, {"L_mean": L.mean(), "L_p5": np.percentile(L, 5), "L_p95": np.percentile(L, 95), "chroma_mean": C.mean(),
                 "clip_hi": (rgb8 >= 254).any(-1).mean() * 100, "clip_lo": (rgb8 <= 1).all(-1).mean() * 100}

rows = []
for stem in sorted(os.listdir(gold)):
    d = os.path.join(gold, stem)
    if not os.path.isdir(d):
        continue
    meta = json.load(open(os.path.join(d, "meta.json")))
    src = np.asarray(Image.open(os.path.join(d, "source.png")).convert("RGB"))
    full = np.asarray(Image.open(os.path.join(d, "reference.png")).convert("RGB"))
    lut = ia.fuse_luts(model.basis_luts, np.array(meta["weights_deploy"], np.float32))
    half_lut = ia.blend_toward_identity(lut, 0.5)
    guard_lut = ia.blend_toward_identity(ia.endpoint_guardrail(lut), 0.75)
    scale = 640 / max(src.shape[:2])
    size = (round(src.shape[1] * scale), round(src.shape[0] * scale))
    src_s = np.asarray(Image.fromarray(src).resize(size, Image.LANCZOS))
    half_s = ia.to_uint8(ia.apply_lut_reference(half_lut, src_s.astype(np.float32) / 255, 1.0))
    full_s = np.asarray(Image.fromarray(full).resize(size, Image.LANCZOS))
    guard_s = ia.to_uint8(ia.apply_lut_reference(guard_lut, src_s.astype(np.float32) / 255, 1.0))
    guard_full = ia.to_uint8(ia.apply_lut_reference(guard_lut, src[::4, ::4].astype(np.float32) / 255, 1.0))

    lab0, s0 = stats(src); lab1, s1 = stats(full); _, s2 = stats(np.repeat(np.repeat(guard_full, 4, 0), 4, 1)[: src.shape[0], : src.shape[1]])
    de = color.deltaE_ciede2000(lab0, lab1).mean()
    row = {"stem": stem, "category": stem.rsplit("_", 1)[0], **{f"orig_{k}": round(v, 2) for k, v in s0.items()},
           **{f"auto_{k}": round(v, 2) for k, v in s1.items()}, **{f"guard75_{k}": round(v, 2) for k, v in s2.items()}, "deltaE2000_mean": round(de, 2),
           "w0": round(meta["weights_deploy"][0], 3), "w1": round(meta["weights_deploy"][1], 3), "w2": round(meta["weights_deploy"][2], 3),
           "lut_min": round(meta["fused_lut_min"], 3), "lut_max": round(meta["fused_lut_max"], 3)}
    rows.append(row)

    pad, label_h = 12, 34
    W = size[0] * 4 + pad * 5; H = size[1] + pad * 2 + label_h + 40
    sheet = Image.new("RGB", (W, H), (24, 24, 26))
    dr = ImageDraw.Draw(sheet)
    for i, (img, label) in enumerate(((src_s, "Original"), (full_s, "Auto 100%"), (half_s, "Auto 50%"), (guard_s, "Guarded 75% (exp.)"))):
        x = pad + i * (size[0] + pad)
        sheet.paste(Image.fromarray(img), (x, pad + label_h))
        dr.text((x, pad), f"{label}", fill=(235, 235, 235), font=font)
    dr.text((pad, H - 34), f"· {stem} · ΔE00 {de:.1f}", fill=(170, 170, 170), font=font)
    sheet.save(os.path.join(sheets, f"{stem}.jpg"), quality=88)
    print(f"{stem:20s} ΔE={de:5.1f} L {s0['L_mean']:5.1f}->{s1['L_mean']:5.1f}  C {s0['chroma_mean']:5.1f}->{s1['chroma_mean']:5.1f}  clipHi {s0['clip_hi']:5.2f}->{s1['clip_hi']:5.2f}%  clipLo {s0['clip_lo']:5.2f}->{s1['clip_lo']:5.2f}% guard {s2['clip_lo']:5.2f}% hi {s2['clip_hi']:5.2f}%")

with open(os.path.join(root, "report", "auto_stats.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
