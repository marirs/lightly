"""Scene-specific evaluation against the product objective (reference: Arsenal 2 'Deep Color').

Objective: image-specific development that stands on its own. Saturation/brightness gains are NOT
treated as improvement. Each scene class gets criteria that test PRESERVATION as well as correction:

  skin (faces via Apple Vision): hue shift |dh| in LCh, chroma ratio, lightness change of face skin pixels
  sunset: warmth of the brightest warm pixels - chroma ratio and hue shift (no neutralising, no oversaturation)
  night: mood - mean L* lift and shadow (p5) behaviour; black clipping growth
  backlit: subject (face box or darkest 30%) lightness gain vs highlight (top 10%) change & clipping
  already-good: overall mean CIEDE2000 (should be small)

Variants (all at 1/4 resolution for speed):
  auto100      upstream model, full strength
  guard75      endpoint guardrail, 75% strength
  guard75_hp   + warm-hue (skin/sunset) protection in LUT space
  local_g75hp  + low-frequency local exposure (backlit-type addition) before the LUT
Outputs: report/eval_rubric.csv, report/eval_sheets/<stem>.jpg
"""
import csv, json, os
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from skimage import color
import ia3dlut as ia

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
gold = os.path.join(root, "golden")
outdir = os.path.join(root, "report", "eval_sheets"); os.makedirs(outdir, exist_ok=True)
faces = json.load(open(os.path.join(gold, "faces.json")))
model = ia.load_reference_model(os.path.join(root, "reference/upstream/pretrained_models/sRGB"))
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 20)

def lch(rgb8):
    lab = color.rgb2lab(rgb8)
    return lab[..., 0], np.hypot(lab[..., 1], lab[..., 2]), np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360, lab

def hue_diff(a, b):
    return ((b - a + 180) % 360) - 180

def metrics(cat, stem, src8, out8):
    L0, C0, H0, lab0 = lch(src8); L1, C1, H1, lab1 = lch(out8)
    m = {"dE00": float(color.deltaE_ciede2000(lab0, lab1).mean()),
         "dL_mean": float(L1.mean() - L0.mean()), "chroma_ratio_all": float(C1.mean() / max(C0.mean(), 1e-3)),
         "clipLo_pp": float(((out8 <= 1).all(-1).mean() - (src8 <= 1).all(-1).mean()) * 100),
         "clipHi_pp": float(((out8 >= 254).any(-1).mean() - (src8 >= 254).any(-1).mean()) * 100)}
    h, w = L0.shape
    boxes = faces.get(stem, [])
    if boxes:  # skin = central 60% of each face box with skin-like hue/chroma in the ORIGINAL
        mask = np.zeros((h, w), bool)
        for x, y, bw, bh in boxes:
            x0, y0 = int((x + 0.2 * bw) * w), int((y + 0.2 * bh) * h)
            mask[y0:int(y0 + 0.6 * bh * h), x0:int(x0 + 0.6 * bw * w)] = True
        mask &= (H0 > 10) & (H0 < 90) & (C0 > 5) & (L0 > 8)
        if mask.sum() > 50:
            m.update(skin_dh=float(np.median(hue_diff(H0[mask], H1[mask]))), skin_chroma_ratio=float(C1[mask].mean() / C0[mask].mean()),
                     skin_dL=float(L1[mask].mean() - L0[mask].mean()))
    if cat == "sunset":
        warm = (H0 > 20) & (H0 < 95) & (C0 > 20) & (L0 > np.percentile(L0, 60))
        m.update(warm_chroma_ratio=float(C1[warm].mean() / C0[warm].mean()), warm_dh=float(np.median(hue_diff(H0[warm], H1[warm]))))
    if cat == "night":
        m.update(night_p5_dL=float(np.percentile(L1, 5) - np.percentile(L0, 5)), night_p50_dL=float(np.median(L1) - np.median(L0)))
    if cat == "backlit":
        if boxes:
            x, y, bw, bh = boxes[0]
            subj = np.zeros((h, w), bool); subj[int(y * h):int((y + bh) * h), int(x * w):int((x + bw) * w)] = True
        else:
            subj = L0 <= np.percentile(L0, 30)
        hi = L0 >= np.percentile(L0, 90)
        m.update(subject_dL=float(L1[subj].mean() - L0[subj].mean()), highlight_dL=float(L1[hi].mean() - L0[hi].mean()))
    return m

def render(variant, src01, lut):
    if variant == "auto100":
        return ia.to_uint8(ia.apply_lut_reference(lut, src01, 1.0))
    g = ia.blend_toward_identity(ia.endpoint_guardrail(lut), 0.75)
    if variant == "guard75":
        return ia.to_uint8(ia.apply_lut_reference(g, src01, 1.0))
    ghp = ia.warm_hue_protection(g)
    if variant == "guard75_hp":
        return ia.to_uint8(ia.apply_lut_reference(ghp, src01, 1.0))
    if variant == "local_g75hp":
        pre = np.clip(ia.local_exposure_gain(src01, strength=0.35), 0, 1)
        return ia.to_uint8(ia.apply_lut_reference(ghp, pre, 1.0))

VARIANTS = ["auto100", "guard75", "guard75_hp", "local_g75hp"]
rows = []
for stem in sorted(d for d in os.listdir(gold) if os.path.isdir(os.path.join(gold, d))):
    cat = stem.rsplit("_", 1)[0].replace("_light", "").replace("_medium", "").replace("_deep", "")
    meta = json.load(open(os.path.join(gold, stem, "meta.json")))
    src = Image.open(os.path.join(gold, stem, "source.png")).convert("RGB")
    src = src.resize((src.width // 4, src.height // 4), Image.LANCZOS)
    src8 = np.asarray(src); src01 = src8.astype(np.float32) / 255
    lut = ia.fuse_luts(model.basis_luts, np.array(meta["weights_deploy"], np.float32))
    panels = [("Original", src8)]
    for v in VARIANTS:
        out8 = render(v, src01, lut)
        panels.append((v, out8))
        rows.append({"stem": stem, "category": cat, "variant": v, **{k: round(val, 2) for k, val in metrics(cat, stem, src8, out8).items()}})
    # sheet
    sc = 360 / max(src8.shape[:2]); sz = (round(src8.shape[1] * sc), round(src8.shape[0] * sc)); pad = 10
    sheet = Image.new("RGB", (len(panels) * (sz[0] + pad) + pad, sz[1] + 2 * pad + 30), (24, 24, 26)); dr = ImageDraw.Draw(sheet)
    for i, (label, img) in enumerate(panels):
        x = pad + i * (sz[0] + pad); sheet.paste(Image.fromarray(img).resize(sz, Image.LANCZOS), (x, pad + 30)); dr.text((x, pad), label, fill=(235, 235, 235), font=font)
    sheet.save(os.path.join(outdir, f"{stem}.jpg"), quality=86)

keys = sorted({k for r in rows for k in r}, key=lambda k: (k not in ("stem", "category", "variant"), k))
with open(os.path.join(root, "report", "eval_rubric.csv"), "w", newline="") as f:
    wr = csv.DictWriter(f, fieldnames=keys); wr.writeheader(); wr.writerows(rows)

# compact summary per category x variant
import collections
agg = collections.defaultdict(lambda: collections.defaultdict(list))
for r in rows:
    for k, v in r.items():
        if isinstance(v, float): agg[(r["category"], r["variant"])][k].append(v)
for (cat, v), d in sorted(agg.items()):
    print(f"{cat:12s} {v:12s} " + " ".join(f"{k}={np.mean(x):+.2f}" for k, x in sorted(d.items())))
