"""Round-trip self-test of the export kit without Lightroom.

Simulates 'Lightroom' with a known LUT: renders the identity HALD and two photos through it (JPEG q100 for
photos, 16-bit TIFF for the HALD), runs ingest_kit, and requires (a) the extracted LUT to match the known LUT
and (b) the look to be reported 'validated'. Also checks that a wrong export is reported 'failed'.
Run: python -m pytest test_kit_roundtrip.py -q
"""
import json, shutil, sys
from pathlib import Path
import numpy as np, tifffile
from PIL import Image

HERE = Path(__file__).resolve().parents[1]  # lr_kit/
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent)); sys.path.insert(0, str(HERE.parents[1] / "lut3d/reference"))
import make_kit, ingest_kit, ia3dlut as ia


def known_lut():
    g = np.moveaxis(ia.identity_lut(), 0, -1)
    y = np.clip(g ** 0.9 * np.array([1.05, 1.0, 0.92]) + 0.02, 0, 1)
    return np.moveaxis(y, -1, 0).astype(np.float32)


def build(tmp: Path, corrupt=False):
    kit = tmp / "kit"
    for d in ("photos", "exports/hald", "exports/photos"):
        (kit / d).mkdir(parents=True, exist_ok=True)
    L = known_lut()
    hald = make_kit.hald_identity().astype(np.float32) / 65535
    side = hald.shape[0]
    out = ia.apply_lut_reference(L, hald.reshape(-1, 1, 3), 1.0).reshape(side, side, 3)
    tifffile.imwrite(kit / "exports/hald/test.1.x__global.tif", np.round(np.clip(out, 0, 1) * 65535).astype(np.uint16))
    for stem in ("portrait_deep_01", "sunset_02"):
        src = Image.open(HERE.parents[1] / f"lut3d/golden/{stem}/source.png").convert("RGB").resize((600, 400))
        src.save(kit / "photos" / f"{stem}.jpg", quality=100)
        s = np.asarray(Image.open(kit / "photos" / f"{stem}.jpg"))
        lr = ia.to_uint8(ia.apply_lut_reference(L if not corrupt else ia.blend_toward_identity(L, -1.5), s.astype(np.float32) / 255, 1.0))
        for variant in ("global", "full"):  # no separated operators in this preset, so both match the LUT
            Image.fromarray(lr).save(kit / "exports/photos" / f"test.1.x__{variant}__{stem}.jpg", quality=100)
        Image.fromarray(s).save(kit / "exports/photos" / f"none__{stem}.jpg", quality=100)
    json.dump([{"look_id": "test.1.x", "category": "test", "stop": 1, "name": "x"}], open(kit / "shortlist.json", "w"))
    make_kit.write_inputs(kit)
    return kit, L


def test_roundtrip_validates(tmp_path):
    kit, L = build(tmp_path)
    ingest_kit.main(kit)
    lut = np.load(kit / "results/luts/test.1.x__global.npy")
    assert np.abs(lut - L).max() < 2 / 255
    rep = json.load(open(kit / "results/report.json"))
    look = rep["looks"]["test.1.x"]
    assert rep["neutral_baseline_ok"] and look["global"]["status"] == "validated" and look["full"]["status"] == "validated"


def test_wrong_export_fails(tmp_path):
    kit, _ = build(tmp_path, corrupt=True)
    ingest_kit.main(kit)
    look = json.load(open(kit / "results/report.json"))["looks"]["test.1.x"]
    assert look["global"]["status"] == "failed" and look["full"]["status"] == "failed"
