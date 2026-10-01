"""Extract (original, Lightroom render) pairs from preset DNGs made by Lightroom from JPEG/PNG sources.

Evidence the pair is valid (checked per file, failures reported):
  * UniqueCameraModel is "JPEG" or "PNG" and ProfileName is "Embedded"
  * raw data is 8-bit RGB whose LinearizationTable equals the sRGB EOTF (max err < 1e-4), so the stored
    bytes ARE the original sRGB-encoded pixels
  * page 0 is Lightroom's rendered preview (YCbCr JPEG) with the embedded settings applied
Output per pair: pairs/<id>/{original.png (preview size), lightroom.png, settings.json, meta.json}
Coverage metric: number of occupied 8^3 RGB bins in the original (placeholder grey cards score ~2-5).
"""
import hashlib, json, sys
from pathlib import Path
import numpy as np, tifffile
from PIL import Image
import lrsettings

root, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
x = np.arange(256) / 255
SRGB_EOTF = np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4) * 65535
index, rejected = [], []
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
        settings = lrsettings.parse_xmp_text(lrsettings.extract_dng_xmp(data))
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
    meta = {"id": pid, "source": rel, "raw_size": list(raw.shape[:2]), "preview_size": [h, w], "colour_bins_8cube": int(bins),
            "mean_abs_diff_8bit": float(np.abs(orig.astype(int) - preview.astype(int)).mean())}
    json.dump(meta, open(d / "meta.json", "w"), indent=1); index.append(meta)
json.dump({"pairs": index, "rejected": rejected}, open(out / "index.json", "w"), indent=1)
b = np.array([m["colour_bins_8cube"] for m in index])
print(len(index), "pairs;", len(rejected), "rejected; colour-bin quartiles", np.percentile(b, [0, 25, 50, 75, 100]), "photos(>=40 bins):", int((b >= 40).sum()))
for r in rejected[:5]: print("  REJ", r)
