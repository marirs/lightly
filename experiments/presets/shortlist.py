"""Provisional V1 shortlist: 5 categories x 4 Looks (+ Auto as stop 0), chosen from the user's collection.

Pipeline:
  1. eligibility  - PV2012+, parse OK, no masks / creative profile (Look) / camera profile / Point Color /
                    legacy process; |Clarity| <= 15 and |Texture| <= 15 (spec 4.1: local contrast is experimental)
  2. dedupe       - identical develop settings across packs/formats (desktop xmp vs mobile dng) collapse to one
  3. descriptors  - render with the CALIBRATED APPROXIMATION (lr_model; held-out median dE00 ~4.8 vs Lightroom)
                    on 6 test photos + a colour-patch chart: warmth (d b*), tint (d a*), chroma ratio, contrast,
                    black lift (fade), overall dE vs original, skin hue shift / chroma on portraits
  4. category     - rules below; within a category, 4 stops ordered by strength with diverse character
Outputs: shortlist.json, shortlist.csv, contact_sheets/<category>.jpg
Contact sheets show APPROXIMATE renders, not Lightroom. They support curation, not acceptance.
"""
from __future__ import annotations

import csv, hashlib, json, math, sys
from pathlib import Path
import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFont
from skimage import color
import lrsettings, classify, lr_model as lm

HERE = Path(__file__).parent
ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / "Downloads/Presets - for lightly"
GOLD = HERE.parent / "lut3d/golden"
TEST_STEMS = ["portrait_deep_01", "portrait_light_01", "portrait_medium_01", "sunset_02", "landscape_03", "night_01", "wellexposed_02"]
PORTRAITS = TEST_STEMS[:3]
TILE = 160

C = lm.Calib()
C.load_state_dict({k: torch.tensor(v) for k, v in json.load(open(HERE / "calibration_natural.json"))["constants"].items()})
S = lm.SpatialCalib()
S.load_state_dict({k: torch.tensor(v) for k, v in json.load(open(HERE / "calibration_spatial_natural.json")).items()})
FACES = json.load(open(GOLD / "faces.json"))


def load_tile(stem, size):
    im = Image.open(GOLD / stem / "source.png").convert("RGB")
    s = size / max(im.size)
    return np.asarray(im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS), np.float32) / 255


IMGS = {s: load_tile(s, 128) for s in TEST_STEMS}
SHEET_IMGS = {s: load_tile(s, TILE) for s in TEST_STEMS}
# colour chart: 6 hues x 3 sat x 3 lightness + 10 greys (in sRGB)
_h = np.linspace(0, 1, 7)[:-1]
CHART = np.array([color.hsv2rgb(np.array([[[h, s, v]]]))[0, 0] for h in _h for s in (0.25, 0.5, 0.8) for v in (0.3, 0.6, 0.9)]
                 + [[g, g, g] for g in np.linspace(0.05, 0.95, 10)], np.float32)


def render(img, preset, settings):
    with torch.no_grad():
        out = lm.render(torch.from_numpy(img), preset, C)
        cl, tx = lm._f(settings, "Clarity2012"), lm._f(settings, "Texture")
        if img.ndim == 3 and (cl or tx):
            out = lm.apply_local_contrast(out, cl, tx, S)
    return out.numpy()


def skin_mask(stem, img):
    h, w = img.shape[:2]
    m = np.zeros((h, w), bool)
    for x, y, bw, bh in FACES.get(stem, []):
        m[int((y + .2 * bh) * h):int((y + .8 * bh) * h), int((x + .2 * bw) * w):int((x + .8 * bw) * w)] = True
    return m


def descriptors(preset, settings):
    d = {}
    lab0 = color.rgb2lab(CHART[None]); lab1 = color.rgb2lab(render(CHART, preset, settings)[None])
    grey = slice(len(CHART) - 10, None)
    # White-balance character measured on the NEUTRAL ramp only (saturated patches mask WB shifts).
    d["warmth"] = float((lab1[0, grey, 2] - lab0[0, grey, 2])[2:9].mean())  # + = yellower neutrals
    d["tint"] = float((lab1[0, grey, 1] - lab0[0, grey, 1])[2:9].mean())    # + = magenta neutrals
    c0, c1 = np.hypot(lab0[0, :-10, 1], lab0[0, :-10, 2]), np.hypot(lab1[0, :-10, 1], lab1[0, :-10, 2])
    d["chroma_ratio"] = float(c1.mean() / c0.mean())
    L0, L1 = lab0[0, grey, 0], lab1[0, grey, 0]
    d["contrast"] = float(np.polyfit(L0[2:8], L1[2:8], 1)[0])              # midtone slope of the grey ramp
    d["black_lift"] = float(L1[0] - L0[0])                                 # + = faded blacks
    de, skin_dh, skin_cr, skin_dl = [], [], [], []
    for stem, img in IMGS.items():
        out = render(img, preset, settings)
        la, lb = color.rgb2lab(img), color.rgb2lab(out)
        de.append(color.deltaE_ciede2000(la, lb).mean())
        if stem in PORTRAITS:
            m = skin_mask(stem, img)
            if m.sum() > 20:
                h0 = np.degrees(np.arctan2(la[..., 2], la[..., 1]))[m]; h1 = np.degrees(np.arctan2(lb[..., 2], lb[..., 1]))[m]
                skin_dh.append(float(np.median(((h1 - h0 + 180) % 360) - 180)))
                skin_cr.append(float(np.hypot(lb[..., 1], lb[..., 2])[m].mean() / max(np.hypot(la[..., 1], la[..., 2])[m].mean(), 1e-3)))
                skin_dl.append(float(lb[..., 0][m].mean() - la[..., 0][m].mean()))
    d["strength_dE"] = float(np.mean(de))
    d["skin_dh_max"] = float(max(map(abs, skin_dh))) if skin_dh else 0.0
    d["skin_chroma_max"] = float(max(skin_cr)) if skin_cr else 1.0
    d["skin_dl_min"] = float(min(skin_dl)) if skin_dl else 0.0
    d["skin_dl_max"] = float(max(skin_dl)) if skin_dl else 0.0
    d["grayscale"] = preset.gray
    return d


INELIGIBLE = ("Mask", "Correction", "GradientBased", "CircularGradientBased", "PaintBased", "Local", "Table_")


def eligible(rep, s):
    if rep["kind"] not in ("xmp", "dng", "lrtemplate"):
        return False, "kind"
    if str(s.get("ProcessVersion", "")).split(".")[0] not in ("10", "11", "15"):
        return False, "legacy process"
    ni = set(rep.get("not-implemented", []))
    allowed_ni = {"PostCropVignetteAmount", "PostCropVignetteMidpoint", "PostCropVignetteFeather", "PostCropVignetteRoundness",
                  "PostCropVignetteStyle", "PostCropVignetteHighlightContrast", "GrainAmount", "GrainSize", "GrainFrequency", "GrainSeed"}
    blocking = {k for k in ni - allowed_ni}
    if blocking:
        return False, "not-implemented: " + ",".join(sorted(blocking))
    if abs(lm._f(s, "Clarity2012")) > 15 or abs(lm._f(s, "Texture")) > 15:
        return False, "local contrast > 15"
    return True, ""


def settings_key(s):
    keep = {k: v for k, v in s.items() if k not in classify.METADATA and not k.startswith(("Name", "UUID", "Group"))}
    return hashlib.sha1(json.dumps(keep, sort_keys=True, default=str).encode()).hexdigest()


def main():
    report = {r["source"]: r for r in json.load(open(HERE / "conversion_report.json"))["presets"]}
    pairs = {m["source"]: m for m in json.load(open(HERE / "pairs/index.json"))["pairs"]} if (HERE / "pairs/index.json").exists() else {}
    seen, cands, reasons = {}, [], {}
    for p in lrsettings.walk(ROOT):
        if p.error or p.source not in report:
            continue
        ok, why = eligible(report[p.source], p.settings)
        reasons[why or "eligible"] = reasons.get(why or "eligible", 0) + 1
        if not ok:
            continue
        k = settings_key(p.settings)
        if k in seen:
            seen[k]["duplicates"].append(p.source); continue
        entry = {"source": p.source, "name": p.name, "settings": p.settings, "duplicates": [], "settings_key": k}
        seen[k] = entry; cands.append(entry)
    print("eligibility:", dict(sorted(reasons.items(), key=lambda x: -x[1])[:8]), "unique eligible:", len(cands))
    cache_path = HERE / "descriptors_cache.json"
    cache = json.load(open(cache_path)) if cache_path.exists() else {}
    for i, c in enumerate(cands):
        c["preset"] = lm.Preset(c["settings"], wb_mode="rendered")
        c["d"] = cache.get(c["settings_key"]) or descriptors(c["preset"], c["settings"])
        cache[c["settings_key"]] = c["d"]
        c["has_lr_pair"] = any(src in pairs for src in [c["source"]] + c["duplicates"])
        if i % 200 == 0:
            print(i, "/", len(cands))
    json.dump(cache, open(cache_path, "w"))
    picks = categorise(cands)
    write_outputs(picks)


RESET_NAMES = ("clear", "reset", "zero", "default", "s0 ")


def family_of(c):
    """Preset family = name without trailing numbers/brackets, so 'Drone Forest Tone (6)' and '(7)' share one."""
    import re
    return re.sub(r"[\s_\-]*(\(\d+\)|\d+)\s*$", "", re.sub(r"\.lrtemplate Preset$", "", c["name"])).strip().lower()


def categorise(cands):
    d = lambda c: c["d"]
    # Skin guard for every category: all three skin tones keep hue, chroma and lightness within bounds.
    skin_ok = lambda c: (d(c)["skin_dh_max"] <= 6 and d(c)["skin_chroma_max"] <= 1.3
                         and d(c)["skin_dl_min"] >= -5 and d(c)["skin_dl_max"] <= 7)
    review = json.load(open(HERE / "shortlist_review.json")) if (HERE / "shortlist_review.json").exists() else {"exclude": {}}
    real = lambda c: (d(c)["strength_dE"] >= 1.5 and not any(r in c["name"].lower() for r in RESET_NAMES)
                      and c["name"] not in review["exclude"] and family_of(c) not in review.get("exclude_families", {}))
    base = [c for c in cands if real(c) and skin_ok(c)]
    colour = [c for c in base if not d(c)["grayscale"]]
    pools = {
        # Mono: skin hue/chroma are irrelevant, but skin lightness must not collapse.
        "mono": [c for c in cands if real(c) and d(c)["grayscale"] and d(c)["skin_dl_min"] >= -8],
        "natural": [c for c in colour if abs(d(c)["warmth"]) < 2 and abs(d(c)["tint"]) < 1.5 and 0.92 <= d(c)["chroma_ratio"] <= 1.15
                    and abs(d(c)["black_lift"]) < 2.5 and d(c)["strength_dE"] < 7],
        "warm": [c for c in colour if d(c)["warmth"] >= 3 and abs(d(c)["tint"]) < 3 and d(c)["black_lift"] < 3],
        "cool": [c for c in colour if d(c)["warmth"] <= -3 and abs(d(c)["tint"]) < 3 and d(c)["black_lift"] < 3],
        "film": [c for c in colour if d(c)["black_lift"] >= 3 and 0.75 <= d(c)["chroma_ratio"] <= 1.05 and d(c)["contrast"] <= 1.05],
    }
    picks, used_families = {}, set()
    pinned_first = sorted(pools, key=lambda k: k not in review.get("pin", {}))
    for cat in pinned_first:
        pool = pools[cat]
        pool = sorted(pool, key=lambda c: d(c)["strength_dE"])
        chosen = []
        pinned = review.get("pin", {}).get(cat)
        if pinned:  # human curation decision recorded in shortlist_review.json
            by_name = {c["name"]: c for c in cands}
            chosen = [by_name[n] for n in pinned]
            used_families.update(family_of(c) for c in chosen)
            picks[cat] = {"pool_size": len(pool), "looks": sorted(chosen, key=lambda c: d(c)["strength_dE"]), "pool": pool}
            print(cat, "pool", len(pool), "-> pinned", pinned)
            continue
        n_looks = review.get("max_looks", {}).get(cat, 4)
        for q in ((0.15, 0.4, 0.65, 0.9) if n_looks == 4 else (0.2, 0.55, 0.9)):
            if not pool:
                break
            target = d(pool[min(len(pool) - 1, int(q * (len(pool) - 1)))])["strength_dE"]
            options = [c for c in pool if c not in chosen and family_of(c) not in used_families]
            if not options:
                break
            best = min(options, key=lambda c: abs(d(c)["strength_dE"] - target) - (0.5 if c["has_lr_pair"] else 0))
            chosen.append(best); used_families.add(family_of(best))
        chosen.sort(key=lambda c: d(c)["strength_dE"])
        picks[cat] = {"pool_size": len(pool), "looks": chosen, "pool": pool}
        print(cat, "pool", len(pool), "->", [c["name"] for c in chosen])
    return picks


def describe(c):
    d = c["d"]
    bits = []
    if d["grayscale"]:
        bits.append("monochrome")
    else:
        bits.append("warmer" if d["warmth"] > 1.5 else "cooler" if d["warmth"] < -1.5 else "neutral white balance")
        bits.append(f"chroma x{d['chroma_ratio']:.2f}")
    bits.append("higher contrast" if d["contrast"] > 1.05 else "lower contrast" if d["contrast"] < 0.95 else "contrast kept")
    if d["black_lift"] > 3:
        bits.append(f"faded blacks (+{d['black_lift']:.0f} L*)")
    bits.append(f"skin hue shift <= {d['skin_dh_max']:.1f} deg")
    return "; ".join(bits)


def write_outputs(picks):
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 13)
    big = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 18)
    out_dir = HERE / "contact_sheets"; out_dir.mkdir(exist_ok=True)
    rows, js = [], {}
    for cat, info in picks.items():
        looks = info["looks"]
        n_rows = len(looks) + 1
        W = 220 + len(TEST_STEMS) * (TILE + 6); H = 50 + n_rows * (TILE + 8)
        sheet = Image.new("RGB", (W, H), (24, 24, 26)); dr = ImageDraw.Draw(sheet)
        dr.text((10, 10), f"{cat.title()} — provisional stops (APPROXIMATE render, not Lightroom; applied to originals, not Auto)", fill=(235, 235, 235), font=big)
        entries = [("Original", None)] + [(f"Stop {i + 1}: {c['name']}", c) for i, c in enumerate(looks)]
        for r, (label, c) in enumerate(entries):
            y = 44 + r * (TILE + 8)
            dr.text((10, y + 4), label[:30], fill=(230, 230, 230), font=font)
            if c:
                dr.text((10, y + 22), f"strength dE {c['d']['strength_dE']:.1f}", fill=(160, 160, 160), font=font)
                dr.text((10, y + 40), "LR ref pair: " + ("yes" if c["has_lr_pair"] else "no"), fill=(160, 160, 160), font=font)
            for j, stem in enumerate(TEST_STEMS):
                img = SHEET_IMGS[stem] if c is None else render(SHEET_IMGS[stem], c["preset"], c["settings"])
                tile = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
                sheet.paste(tile, (220 + j * (TILE + 6) + (TILE - tile.width) // 2, y + (TILE - tile.height) // 2))
        sheet.save(out_dir / f"{cat}.jpg", quality=86)
        js[cat] = {"pool_size": info["pool_size"], "looks": []}
        for i, c in enumerate(looks):
            review = json.load(open(HERE / "shortlist_review.json"))
            rec = {"category": cat, "stop": i + 1, "name": c["name"], "source": c["source"], "duplicates": c["duplicates"],
                   "review_flag": review.get("flags", {}).get(c["name"]), "pinned": c["name"] in review.get("pin", {}).get(cat, []),
                   "has_lr_candidate_pair": c["has_lr_pair"], **{k: round(v, 3) if isinstance(v, float) else v for k, v in c["d"].items()},
                   "auto_reason": describe(c)}
            rows.append(rec); js[cat]["looks"].append(rec)
    json.dump(js, open(HERE / "shortlist.json", "w"), indent=1)
    with open(HERE / "shortlist.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=[k for k in rows[0] if k != "duplicates"], extrasaction="ignore"); w.writeheader(); w.writerows(rows)


if __name__ == "__main__":
    main()
