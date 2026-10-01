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
    photos = sorted((kit / "photos").glob("*.jpg"))
    report = {"neutrality": {}, "looks": {}}
    # 1. neutrality: Lightroom with no preset must reproduce the input
    for ph in photos:
        e = kit / "exports/photos" / f"none__{ph.stem}.jpg"
        if e.exists():
            report["neutrality"][ph.stem] = dict(zip(("mean", "p95"), de_stats(load(ph), load(e))))
    neutral_ok = bool(report["neutrality"]) and all(v["mean"] <= 1.0 for v in report["neutrality"].values())
    for L in looks:
        lid = L["look_id"]; entry = {"category": L["category"], "stop": L["stop"], "name": L["name"], "photos": {}, "missing": []}
        for variant in ("full", "global"):
            h = kit / "exports/hald" / f"{lid}__{variant}.tif"
            if not h.exists():
                entry["missing"].append(h.name); continue
            lut = hald_to_lut(h)
            np.save(res / "luts" / f"{lid}__{variant}.npy", lut)
            write_cube(lut, res / "luts" / f"{lid}__{variant}.cube", f"{lid} {variant}")
        gpath = res / "luts" / f"{lid}__global.npy"
        if gpath.exists():
            lut = np.load(gpath)
            for ph in photos:
                e = kit / "exports/photos" / f"{lid}__{ph.stem}.jpg"
                if not e.exists():
                    entry["missing"].append(e.name); continue
                src = load(ph); lr = load(e)
                if lr.shape != src.shape:
                    entry["photos"][ph.stem] = {"error": f"size mismatch {lr.shape} vs {src.shape}"}; continue
                ours = ia.to_uint8(ia.apply_lut_reference(lut, src.astype(np.float32) / 255, 1.0))
                mean, p95 = de_stats(ours[::2, ::2], lr[::2, ::2])
                entry["photos"][ph.stem] = {"mean": round(mean, 2), "p95": round(p95, 2), "pass": mean <= MEAN_MAX and p95 <= P95_MAX}
                if not entry["photos"][ph.stem]["pass"]:
                    s = 360 / max(src.shape[:2]); sz = (round(src.shape[1] * s), round(src.shape[0] * s))
                    sheet = Image.new("RGB", (sz[0] * 3 + 20, sz[1]), (24, 24, 26))
                    for i, im in enumerate((src, ours, lr)):
                        sheet.paste(Image.fromarray(im).resize(sz), (i * (sz[0] + 10), 0))
                    sheet.save(res / "sheets" / f"{lid}__{ph.stem}.jpg", quality=85)
        ok = entry["photos"] and not entry["missing"] and all(v.get("pass") for v in entry["photos"].values())
        entry["status"] = "validated" if ok and neutral_ok else ("incomplete" if entry["missing"] else "failed")
        report["looks"][lid] = entry
    report["neutral_baseline_ok"] = neutral_ok
    json.dump(report, open(res / "report.json", "w"), indent=1)
    lines = ["# Lightroom export validation", "", f"Neutral baseline OK: {neutral_ok}", "", "| Look | Status | Photos passing | Worst mean dE00 | Worst p95 |", "|---|---|---|---|---|"]
    for lid, e in report["looks"].items():
        vals = [v for v in e["photos"].values() if "mean" in v]
        lines.append(f"| `{lid}` | {e['status']} | {sum(v['pass'] for v in vals)}/{len(photos)} | "
                     f"{max((v['mean'] for v in vals), default=float('nan')):.2f} | {max((v['p95'] for v in vals), default=float('nan')):.2f} |")
    (res / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
