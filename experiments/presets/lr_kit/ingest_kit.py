"""Ingest Lightroom exports from the kit: HALD -> LUT, then validate the LUT against Lightroom photo exports.

Usage: python ingest_kit.py <kit dir>  ->  <kit>/results/{luts/*.cube, luts/*.f32, report.json, report.md, sheets/*.jpg}

Per Look and photo, compares   Lightly = LUT(original) [+ experimental local contrast if the preset uses it]
                       against Lightroom photo export.
Acceptance (proposed in docs/m1/preset-conversion.md): mean dE00 <= 2 and p95 <= 5 on every photo.
A Look is reported 'validated' only if all 22 photos pass; otherwise 'failed' with the failing photos listed.
Also checks the neutrality export (no preset): Lightroom's rendering of an untouched JPEG must equal the input,
otherwise the comparison baseline itself is off and every result is flagged.
"""
from __future__ import annotations

import io, json, sys
from pathlib import Path
import numpy as np
import tifffile
from PIL import Image, ImageCms, ImageOps
from skimage import color

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lut3d/reference"))
import ia3dlut as ia  # noqa: E402
import lrsettings  # noqa: E402

PRESETS = Path(__file__).resolve().parents[1]

MEAN_MAX, P95_MAX = 2.0, 5.0


def hald_to_lut(path: Path, out_dim=33) -> np.ndarray:
    """Read an exported HALD (level 8, 64^3) and resample to the contract's 33^3 LUT[c,b,g,r]."""
    img = tifffile.imread(path).astype(np.float64)
    img = img / (65535.0 if img.max() > 255 else 255.0)
    side = img.shape[0]; n = round(side ** (2 / 3))
    assert img.shape[:2] == (side, side) and n ** 3 == side * side, img.shape
    cube = img[..., :3].reshape(n, n, n, 3)  # [b, g, r, ch] since index = r + g*n + b*n^2
    lut64 = np.moveaxis(cube, -1, 0).astype(np.float32)
    g = np.moveaxis(ia.identity_lut(out_dim), 0, -1).reshape(-1, 1, 3)
    out = ia.apply_lut_reference(lut64, g.astype(np.float32), binsize_numerator=1.0).reshape(out_dim, out_dim, out_dim, 3)
    return np.moveaxis(out, -1, 0).astype(np.float32)


def write_cube(lut: np.ndarray, path: Path, title: str):
    n = lut.shape[-1]
    with open(path, "w") as f:
        f.write(f'TITLE "{title}"\nLUT_3D_SIZE {n}\n')
        for b in range(n):
            for g in range(n):
                for r in range(n):
                    f.write("%.6f %.6f %.6f\n" % tuple(lut[:, b, g, r]))


def sha256_file(p: Path) -> str:
    import hashlib
    return hashlib.sha256(p.read_bytes()).hexdigest()


def calibration():
    import lr_model as lm, torch
    C = lm.Calib()
    C.load_state_dict({k: torch.tensor(v) for k, v in json.load(open(PRESETS / "calibration_natural.json"))["constants"].items()})
    return C


def spatial_calibration():
    import lr_model as lm, torch
    S = lm.SpatialCalib()
    S.load_state_dict({k: torch.tensor(v) for k, v in json.load(open(PRESETS / "calibration_spatial_natural.json")).items()})
    return S


def preset_paths(look: dict):
    lid = look["look_id"]
    return [look.get("full_xmp", f"presets/full/{lid}__full.xmp"), look.get("global_xmp", f"presets/global/{lid}__global.xmp")]


def verify_presets(kit: Path, look: dict, recorded: dict) -> list:
    """Every preset file the Look was rendered with must exist and match the hash recorded at kit creation."""
    problems = []
    for rel in preset_paths(look):
        p = kit / rel
        if rel not in recorded:
            problems.append(f"{Path(rel).name} not recorded in inputs.json")
        elif not p.exists():
            problems.append(f"{Path(rel).name} missing")
        elif sha256_file(p) != recorded[rel]:
            problems.append(f"{Path(rel).name} changed since kit creation")
    return problems


def load_full_settings(kit: Path, look: dict) -> dict:
    """No silent fallback: callers verify presence and hash first (verify_presets)."""
    return lrsettings.parse_xmp_text((kit / preset_paths(look)[0]).read_text())


def blocked(missing_hald, preset_problems, missing_inputs):
    missing = [f"input {s}" for s in missing_inputs] + list(preset_problems)
    if missing_hald is not None:
        missing.append(missing_hald.name)
    return {"photos": {}, "missing": missing, "status": "incomplete", "unimplemented": [], "approximated": []}


def apply_global(lut, src8):
    return ia.to_uint8(ia.apply_lut_reference(lut, src8.astype(np.float32) / 255, 1.0))


SEPARATED_TONE = ("Highlights2012", "Shadows2012", "Whites2012", "Blacks2012", "Dehaze")


def full_recipe(lut, settings):
    """Lightly's complete recipe for a Look: separated adaptive-tone operators (calibrated GLOBAL approximation
    from lr_model, applied before the LUT as Lightroom applies basic tone before curves/colour), then the global
    LUT from the global-only HALD, then experimental local contrast (Clarity/Texture). Returns (fn, unimplemented,
    approximated) where unimplemented lists every non-default parameter Lightly cannot render."""
    import classify, lr_model as lm, torch
    rep = classify.classify(lrsettings.ParsedPreset("kit", "xmp", "kit", settings))
    unimplemented = sorted(rep.get("not-implemented", []))
    approximated = sorted(set(rep.get("approximated", [])) | set(rep.get("experimental", [])))
    tone_only = {k: settings[k] for k in SEPARATED_TONE if k in settings}
    tone = lm.Preset(tone_only, wb_mode="rendered") if any(lm._f(tone_only, k) for k in tone_only) else None
    clarity, texture = lm._f(settings, "Clarity2012"), lm._f(settings, "Texture")
    C = calibration() if tone else None
    S = spatial_calibration() if (clarity or texture) else None

    def recipe(src8):
        x = src8.astype(np.float32) / 255
        if tone is not None:
            with torch.no_grad():
                x = lm.render(torch.from_numpy(x), tone, C).numpy()
        y = ia.apply_lut_reference(lut, np.clip(x, 0, 1).astype(np.float32), 1.0)
        with torch.no_grad():
            t = torch.from_numpy(np.clip(y, 0, 1).astype(np.float32))
            if S is not None:
                t = lm.apply_local_contrast(t, clarity, texture, S)
            t = lm.apply_vignette(t, settings)
            # Seed from image content so the recipe is deterministic per photo; any seed is equally valid.
            t = lm.apply_grain(t, settings, seed=int(src8[::97, ::89].sum()) % (2 ** 31))
            y = t.numpy()
        return ia.to_uint8(y)
    return recipe, unimplemented, approximated


def grain_sigma_frac(settings):
    """Blur scale (fraction of the long edge) that hides grain texture but keeps the image's tone and colour."""
    import lr_model as lm
    if not lm._f(settings, "GrainAmount"):
        return None
    size = lm._f(settings, "GrainSize", 25) / 100
    grains_long = max(8, round(lm.GRAIN_REF_LONG / (1 + 4 * size)))
    return 2.0 / grains_long


def _blur(img8, sigma_px):
    from PIL import ImageFilter
    return np.asarray(Image.fromarray(img8).filter(ImageFilter.GaussianBlur(sigma_px)))


GRAIN_MIN_SMOOTH_PX = 4000      # minimum smooth-region pixels for a grain measurement
GRAIN_MIN_SMOOTH_FRAC = 0.02
GRAIN_MIN_SIGNAL = 0.8           # Lightroom grain contribution (8-bit levels) below this is not measurable


def _luma(img8):
    return img8.astype(np.float32) @ np.array([0.2126, 0.7152, 0.0722], np.float32)


def _highpass(img8, sigma_px):
    return _luma(img8) - _luma(_blur(img8, sigma_px))


def smooth_mask(grain_free8, sigma_px):
    """Pixels where the grain-free render is itself smooth at grain scale and in midtones: there, high-pass
    energy in the full render is grain, not image detail (re-review issue 1)."""
    hp = np.abs(_highpass(grain_free8, sigma_px))
    local = _luma(_blur(np.repeat(np.clip(hp * 20, 0, 255).astype(np.uint8)[..., None], 3, -1), sigma_px * 3)) / 20
    y = _luma(_blur(grain_free8, sigma_px))
    return (local < 0.6) & (y > 40) & (y < 215)


def grain_contribution(full8, grain_free8, mask, sigma_px):
    """Grain energy added by the full render over its grain-free counterpart, in the smooth mask."""
    a = float(_highpass(full8, sigma_px)[mask].std())
    b = float(_highpass(grain_free8, sigma_px)[mask].std())
    return float(np.sqrt(max(a * a - b * b, 0.0)))


def validate(kit, res, inputs, photos, missing_inputs, inputs_ok, report, neutral_ok, prefix, missing_hald, render, grain_frac=None,
             grain_free_prefix=None, grain_free_render=None):
    """One validation (global or full) with the complete-evidence rules of Codex finding 6."""
    out = {"photos": {}, "missing": [f"input photo {s}.jpg" for s in missing_inputs]}
    if missing_hald is not None:
        out["missing"].append(missing_hald.name)
    for ph in photos:
        e = kit / "exports/photos" / f"{prefix}__{ph.stem}.jpg"
        if not e.exists():
            out["missing"].append(e.name); continue
        if missing_hald is not None:
            continue
        src, lr = load(ph), load(e)
        if lr.shape != src.shape:
            out["photos"][ph.stem] = {"error": f"size mismatch {lr.shape} vs {src.shape}"}; continue
        ours = render(src)
        rec = {}
        if grain_frac:
            # Grain is random: compare tone/colour after hiding grain texture, and measure grain separately as
            # its contribution over the grain-free render, in smooth regions only (re-review issue 1).
            sigma = grain_frac * max(src.shape[:2])
            # Tone/colour comparison blurs at 3x grain scale so the coarse (roughness) component is hidden too.
            mean, p95 = de_stats(_blur(ours, 3 * sigma)[::2, ::2], _blur(lr, 3 * sigma)[::2, ::2])
            gf_path = kit / "exports/photos" / f"{grain_free_prefix}__{ph.stem}.jpg"
            if not gf_path.exists():
                out["missing"].append(gf_path.name); continue
            lr_free, ours_free = load(gf_path), grain_free_render(src)
            mask = smooth_mask(lr_free, sigma)
            n = int(mask.sum())
            g_lr = grain_contribution(lr, lr_free, mask, sigma) if n else 0.0
            if n < max(GRAIN_MIN_SMOOTH_PX, GRAIN_MIN_SMOOTH_FRAC * mask.size):
                rec.update(grain="insufficient", smooth_px=n)  # not enough smooth area to see grain at all
            else:
                g_ours = grain_contribution(ours, ours_free, mask, sigma)
                if g_lr < GRAIN_MIN_SIGNAL:
                    # Lightroom shows no measurable grain here: Lightly must not add any either.
                    verdict = "pass" if g_ours < GRAIN_MIN_SIGNAL else "fail"
                    ratio = None
                else:
                    ratio = g_ours / g_lr
                    verdict = "pass" if 0.6 <= ratio <= 1.6 else "fail"
                rec.update(grain=verdict, grain_ratio=None if ratio is None else round(ratio, 2),
                           grain_lr=round(g_lr, 2), grain_ours=round(g_ours, 2), smooth_px=n)
        else:
            mean, p95 = de_stats(ours[::2, ::2], lr[::2, ::2])
        ok = mean <= MEAN_MAX and p95 <= P95_MAX and rec.get("grain") != "fail"
        out["photos"][ph.stem] = {"mean": round(mean, 2), "p95": round(p95, 2), "pass": ok, **rec}
        if not ok:
            s = 360 / max(src.shape[:2]); sz = (round(src.shape[1] * s), round(src.shape[0] * s))
            sheet = Image.new("RGB", (sz[0] * 3 + 20, sz[1]), (24, 24, 26))
            for i, im in enumerate((src, ours, lr)):
                sheet.paste(Image.fromarray(im).resize(sz), (i * (sz[0] + 10), 0))
            sheet.save(res / "sheets" / f"{prefix}__{ph.stem}.jpg", quality=85)
    complete = not out["missing"] and len(out["photos"]) == len(inputs)
    passed = complete and all(v.get("pass") for v in out["photos"].values())
    out["status"] = ("incomplete" if not complete or not inputs_ok or report["missing_neutral"]
                     else "validated" if passed and neutral_ok else "failed")
    if grain_frac and out["status"] == "validated" and not any(v.get("grain") == "pass" for v in out["photos"].values()):
        # No photo allowed grain to be measured: absence of a failure is not evidence of a pass.
        out["status"] = "incomplete"
        out["reason"] = "insufficient grain evidence (no input had enough smooth area)"
    return out


def de_stats(a8, b8):
    de = color.deltaE_ciede2000(color.rgb2lab(a8), color.rgb2lab(b8))
    return float(de.mean()), float(np.percentile(de, 95))


_SRGB = ImageCms.createProfile("sRGB")


def load(p):
    """Decode as Lightroom exports are compared: EXIF-upright and converted to sRGB (Codex finding 4).

    Lightroom colour-manages its input and exports sRGB, so an original tagged Display P3 / Adobe RGB must be
    converted (relative colorimetric) before a LUT is applied or a difference is scored. Untagged images are
    treated as sRGB, matching Lightroom's assumption for untagged JPEGs.
    """
    im = Image.open(p)
    icc = im.info.get("icc_profile")
    im = ImageOps.exif_transpose(im).convert("RGB")
    if icc:
        src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        if "srgb" not in ImageCms.getProfileDescription(src).lower():
            im = ImageCms.profileToProfile(im, src, _SRGB, renderingIntent=ImageCms.Intent.RELATIVE_COLORIMETRIC, outputMode="RGB")
    return np.asarray(im)


def main(kit: Path):
    looks = json.load(open(kit / "shortlist.json"))
    res = kit / "results"; (res / "luts").mkdir(parents=True, exist_ok=True); (res / "sheets").mkdir(exist_ok=True)
    # The expected inputs come from the kit's record, never from the folder contents (Codex finding 6).
    inputs_path = kit / "inputs.json"
    if not inputs_path.exists():
        raise FileNotFoundError(f"{inputs_path} missing: not a kit produced by make_kit.py; refusing to validate")
    record = json.load(open(inputs_path))
    inputs = record["photos"]
    missing_inputs = [s for s in inputs if not (kit / "photos" / f"{s}.jpg").exists()]
    changed_inputs = [s for s in inputs if s not in missing_inputs and sha256_file(kit / "photos" / f"{s}.jpg") != inputs[s]]
    # Identity image and preset files must be present and unchanged (re-review issue 3).
    hald_path = kit / "identity/hald_64_srgb16.tif"
    if not record.get("hald_sha256") or not hald_path.exists():
        missing_inputs.append("identity/hald_64_srgb16.tif")
    elif sha256_file(hald_path) != record["hald_sha256"]:
        changed_inputs.append("identity/hald_64_srgb16.tif")
    preset_hashes = record.get("presets", {})
    photos = [kit / "photos" / f"{s}.jpg" for s in sorted(inputs) if s not in missing_inputs]
    report = {"neutrality": {}, "looks": {}, "missing_inputs": missing_inputs, "changed_inputs": changed_inputs, "missing_neutral": []}
    # 1. neutrality: Lightroom with no preset must reproduce EVERY input
    for stem in sorted(inputs):
        e = kit / "exports/photos" / f"none__{stem}.jpg"
        if stem in missing_inputs or not e.exists():
            report["missing_neutral"].append(e.name); continue
        report["neutrality"][stem] = dict(zip(("mean", "p95"), de_stats(load(kit / "photos" / f"{stem}.jpg"), load(e))))
    inputs_ok = not missing_inputs and not changed_inputs
    neutral_ok = (inputs_ok and not report["missing_neutral"] and len(report["neutrality"]) == len(inputs)
                  and all(v["mean"] <= 1.0 for v in report["neutrality"].values()))
    for L in looks:
        lid = L["look_id"]
        entry = {"category": L["category"], "stop": L["stop"], "name": L["name"]}
        h = kit / "exports/hald" / f"{lid}__global.tif"
        lut = None
        if h.exists():
            lut = hald_to_lut(h)
            np.save(res / "luts" / f"{lid}__global.npy", lut)
            write_cube(lut, res / "luts" / f"{lid}__global.cube", f"{lid} global")
        preset_problems = verify_presets(kit, L, preset_hashes)
        settings = load_full_settings(kit, L) if not preset_problems else None
        # 1. global-transform validation: LUT(original) vs Lightroom's GLOBAL-ONLY photo exports
        if lut is None or settings is None:
            entry["global"] = blocked(h if lut is None else None, preset_problems, missing_inputs)
            entry["full"] = blocked(h if lut is None else None, preset_problems, missing_inputs)
            report["looks"][lid] = entry
            continue
        entry["global"] = validate(kit, res, inputs, photos, missing_inputs, inputs_ok, report, neutral_ok,
                                   f"{lid}__global", h if lut is None else None,
                                   lambda src: apply_global(lut, src))
        # 2. full-recipe validation: Lightly's complete recipe vs Lightroom's FULL photo exports
        recipe, unimplemented, approximated = full_recipe(lut, settings)
        full = validate(kit, res, inputs, photos, missing_inputs, inputs_ok, report, neutral_ok,
                        f"{lid}__full", h if lut is None else None, recipe, grain_frac=grain_sigma_frac(settings),
                        grain_free_prefix=f"{lid}__global", grain_free_render=full_recipe(lut, {k: v for k, v in settings.items() if not k.startswith("Grain")})[0])
        full["unimplemented"] = unimplemented
        full["approximated"] = approximated
        if unimplemented and full["status"] == "validated":
            full["status"] = "failed"  # numbers can't validate a recipe Lightly cannot render
            full["reason"] = "operators not implemented by Lightly: " + ", ".join(unimplemented)
        entry["full"] = full
        report["looks"][lid] = entry
    report["neutral_baseline_ok"] = neutral_ok
    json.dump(report, open(res / "report.json", "w"), indent=1)
    lines = ["# Lightroom export validation", "", f"Neutral baseline OK: {neutral_ok}", "",
             "| Look | Global status | Global worst mean / p95 | Full-recipe status | Full worst mean / p95 | Not implemented |",
             "|---|---|---|---|---|---|"]
    def worst(v):
        vals = [x for x in v["photos"].values() if "mean" in x]
        return f"{max((x['mean'] for x in vals), default=float('nan')):.2f} / {max((x['p95'] for x in vals), default=float('nan')):.2f}"
    for lid, e in report["looks"].items():
        lines.append(f"| `{lid}` | {e['global']['status']} | {worst(e['global'])} | {e['full']['status']} | {worst(e['full'])} | "
                     f"{', '.join(e['full']['unimplemented']) or '-'} |")
    (res / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
