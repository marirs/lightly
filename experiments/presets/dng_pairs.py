"""Extract (original, Lightroom render) pairs from preset DNGs made by Lightroom from JPEG/PNG sources.

Evidence the pair is valid (checked per file, failures reported):
  * UniqueCameraModel is "JPEG" or "PNG" and ProfileName is "Embedded"
  * raw data is 8-bit RGB whose LinearizationTable equals the sRGB EOTF (max err < 1e-4), so the stored
    bytes ARE the original sRGB-encoded pixels
  * page 0 is Lightroom's rendered preview (YCbCr JPEG) with the embedded settings applied
Provenance checks (Codex M1 finding 7), recorded per pair in meta.json["checks"]; any failure -> rejected:
  * preview_app: PreviewApplicationName is Lightroom / Camera Raw
  * preview_colour_space: PreviewColorSpace == 2 (sRGB), so preview pixels are read as sRGB
  * preview_fresh: |XMP MetadataDate - PreviewDateTime| <= 10 s (settings were not edited after the preview
    was rendered). PreviewSettingsDigest is Adobe-proprietary and cannot be recomputed: recorded, NOT verified
  * geometry: Orientation == 1, no crs crop, and preview aspect ratio == raw default-crop aspect (+-1 px)
  * alignment: correlation of luminance-gradient magnitude between resized original and preview >= 0.5
    (tone/colour changes keep edges; a different or shifted image does not), and higher than for the
    90-degree-rotated and mirrored original
These pairs are CANDIDATE references only: they rest on the assumptions above, not on a controlled export.
Output per pair: pairs/<id>/{original.png (preview size), lightroom.png, settings.json, meta.json}
Coverage metric: number of occupied 8^3 RGB bins in the original (placeholder grey cards score ~2-5).
"""
import datetime, hashlib, json, re, sys
from pathlib import Path
import numpy as np, tifffile
from PIL import Image
import lrsettings

root, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
x = np.arange(256) / 255
SRGB_EOTF = np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4) * 65535
index, rejected = [], []


def _grad(img):
    y = img.astype(np.float32) @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    gx = np.abs(np.diff(y, axis=1))[:-1]; gy = np.abs(np.diff(y, axis=0))[:, :-1]
    return (gx + gy).ravel()


def _corr(a, b):
    a = a - a.mean(); b = b - b.mean()
    return float((a * b).sum() / (np.sqrt((a * a).sum() * (b * b).sum()) + 1e-9))


def _parse_time(t):
    try:
        return datetime.datetime.fromisoformat(t)
    except (TypeError, ValueError):
        return None


def provenance_checks(prov, settings, raw, preview, orig):
    c = {}
    c["preview_app"] = {"pass": bool(prov["app"]) and ("Lightroom" in prov["app"] or "Camera Raw" in prov["app"]), "value": prov["app"]}
    c["preview_colour_space"] = {"pass": prov["colour_space"] == 2, "value": prov["colour_space"]}
    t_prev, t_meta = _parse_time(prov["preview_time"]), _parse_time(prov["metadata_time"])
    gap = abs((t_meta - t_prev).total_seconds()) if t_prev and t_meta else None
    c["preview_fresh"] = {"pass": gap is not None and gap <= 10, "value_s": gap, "note": "settings digest not verifiable"}
    crop = prov["crop_size"]
    # DefaultCropSize is two RATIONALs: (w_num, w_den, h_num, h_den)
    ar_raw = ((crop[0] / crop[1]) / (crop[2] / crop[3])) if crop and len(crop) == 4 else raw.shape[1] / raw.shape[0]
    ar_prev = preview.shape[1] / preview.shape[0]
    has_crop = str(settings.get("HasCrop", "False")) == "True"
    c["geometry"] = {"pass": prov["orientation"] == 1 and not has_crop and abs(ar_raw * preview.shape[0] - preview.shape[1]) <= 1.5,
                     "orientation": prov["orientation"], "has_crop": has_crop, "aspect_raw": round(ar_raw, 4), "aspect_preview": round(ar_prev, 4)}
    g_prev = _grad(preview)
    r_same = _corr(_grad(orig), g_prev)
    r_rot = _corr(_grad(np.rot90(orig).copy()), g_prev) if orig.shape[0] == orig.shape[1] else -1.0
    r_flip = _corr(_grad(orig[:, ::-1].copy()), g_prev)
    c["alignment"] = {"pass": r_same >= 0.5 and r_same > max(r_rot, r_flip), "r": round(r_same, 3), "r_rot90": round(r_rot, 3), "r_mirror": round(r_flip, 3)}
    return c
for f in sorted(p for p in root.rglob("*.dng") if not p.name.startswith("._")):
    rel = str(f.relative_to(root))
    try:
        data = f.read_bytes()
        with tifffile.TiffFile(f) as t:
            p0 = t.pages[0]
            model = p0.tags["UniqueCameraModel"].value
            prof = p0.tags["ProfileName"].value if "ProfileName" in p0.tags else None
            raw_page = p0.pages[0]
            lin = np.array(raw_page.tags["LinearizationTable"].value, float)
            if model not in ("JPEG", "PNG") or prof != "Embedded" or lin.shape != (256,) or np.abs(lin - SRGB_EOTF).max() / 65535 > 1e-4:
                rejected.append({"source": rel, "reason": f"model={model} profile={prof} lin={lin.shape}"}); continue
            preview = p0.asarray(); raw = raw_page.asarray()
            tag = lambda name: p0.tags[name].value if name in p0.tags else None
            prov = {"app": tag("PreviewApplicationName"), "colour_space": tag("PreviewColorSpace"), "preview_time": tag("PreviewDateTime"),
                    "digest": (tag("PreviewSettingsDigest") or b"").hex(), "orientation": int(tag("Orientation") or 1),
                    "crop_size": list(raw_page.tags["DefaultCropSize"].value) if "DefaultCropSize" in raw_page.tags else None}
        xmp_text = lrsettings.extract_dng_xmp(data)
        settings = lrsettings.parse_xmp_text(xmp_text)
        md = re.search(r'xmp:MetadataDate="([^"]+)"', xmp_text)
        prov["metadata_time"] = md.group(1) if md else None
    except Exception as e:  # reported, not swallowed
        rejected.append({"source": rel, "reason": f"{type(e).__name__}: {e}"}); continue
    pid = hashlib.sha1(rel.encode()).hexdigest()[:10]
    d = out / pid; d.mkdir(exist_ok=True)
    h, w = preview.shape[:2]
    # preview is a centred square/aspect-preserving reduction of the full frame; resize original to match
    orig = np.asarray(Image.fromarray(raw).resize((w, h), Image.LANCZOS))
    Image.fromarray(orig).save(d / "original.png"); Image.fromarray(preview).save(d / "lightroom.png")
    json.dump(settings, open(d / "settings.json", "w"), indent=1)
    bins = len(np.unique((orig // 32).reshape(-1, 3), axis=0))
    checks = provenance_checks(prov, settings, raw, preview, orig)
    meta = {"id": pid, "source": rel, "raw_size": list(raw.shape[:2]), "preview_size": [h, w], "colour_bins_8cube": int(bins),
            "mean_abs_diff_8bit": float(np.abs(orig.astype(int) - preview.astype(int)).mean()),
            "provenance": prov, "checks": checks, "status": "candidate" if all(c["pass"] for c in checks.values()) else "rejected"}
    json.dump(meta, open(d / "meta.json", "w"), indent=1); index.append(meta)
json.dump({"pairs": index, "rejected": rejected}, open(out / "index.json", "w"), indent=1)
import collections
fails = collections.Counter(k for m in index for k, c in m["checks"].items() if not c["pass"])
print("provenance: candidate", sum(m["status"] == "candidate" for m in index), "rejected-by-checks", sum(m["status"] == "rejected" for m in index), dict(fails))
b = np.array([m["colour_bins_8cube"] for m in index])
print(len(index), "pairs;", len(rejected), "rejected; colour-bin quartiles", np.percentile(b, [0, 25, 50, 75, 100]), "photos(>=40 bins):", int((b >= 40).sum()))
for r in rejected[:5]: print("  REJ", r)
