"""Codex finding 4: ingest must convert embedded ICC profiles to sRGB and apply EXIF orientation before
applying LUTs or scoring, because Lightroom exports are sRGB and upright."""
import io, json
from pathlib import Path
import numpy as np
from PIL import Image, ImageCms
import ingest_kit

P3 = "/System/Library/ColorSync/Profiles/Display P3.icc"


def _write_p3_photo(path):
    # Smooth content + no chroma subsampling, so JPEG coding does not dominate the comparison.
    y, x = np.mgrid[0:64, 0:96]
    px = np.stack([40 + 2 * x, 60 + 2 * y, 200 - x], -1).clip(0, 255).astype(np.uint8)
    px[:, :32] = [235, 40, 40]  # saturated red: differs most between P3 and sRGB encodings
    Image.fromarray(px).save(path, quality=100, subsampling=0, icc_profile=open(P3, "rb").read())
    srgb = ImageCms.profileToProfile(Image.fromarray(px), ImageCms.getOpenProfile(P3), ImageCms.createProfile("sRGB"), outputMode="RGB")
    return np.asarray(srgb)


def _write_rotated_photo(path):
    upright = np.zeros((40, 80, 3), np.uint8); upright[:, :20] = [250, 250, 250]   # white bar on the left
    stored = np.rot90(upright, k=1).copy()  # stored rotated; EXIF 6 (rotate 90 CW on display) restores upright
    exif = Image.Exif(); exif[0x0112] = 6
    Image.fromarray(stored).save(path, quality=100, subsampling=0, exif=exif)
    return upright


def test_load_converts_icc_to_srgb(tmp_path):
    expected = _write_p3_photo(tmp_path / "p3.jpg")
    got = ingest_kit.load(tmp_path / "p3.jpg")
    diff = np.abs(got.astype(int) - expected.astype(int))
    # JPEG coding leaves <= ~4 levels at edges; the unconverted P3 bug produced 40.
    assert diff.max() <= 5 and np.percentile(diff, 99) <= 2, (diff.max(), np.percentile(diff, 99))


def test_load_applies_exif_orientation(tmp_path):
    upright = _write_rotated_photo(tmp_path / "rot.jpg")
    got = ingest_kit.load(tmp_path / "rot.jpg")
    assert got.shape == upright.shape
    assert got[:, :20].mean() > 200 and got[:, 40:].mean() < 50


def test_neutral_baseline_uses_colour_managed_originals(tmp_path):
    kit = tmp_path / "kit"
    for d in ("photos", "exports/photos", "exports/hald"):
        (kit / d).mkdir(parents=True)
    srgb = _write_p3_photo(kit / "photos/p3.jpg")
    Image.fromarray(srgb).save(kit / "exports/photos/none__p3.jpg", quality=100, subsampling=0)  # what Lightroom exports in sRGB
    json.dump([], open(kit / "shortlist.json", "w"))
    import make_kit
    (kit / "identity").mkdir(exist_ok=True); make_kit.write_hald(kit / "identity/hald_64_srgb16.tif")
    make_kit.write_inputs(kit)
    ingest_kit.main(kit)
    rep = json.load(open(kit / "results/report.json"))
    assert rep["neutral_baseline_ok"], rep["neutrality"]
