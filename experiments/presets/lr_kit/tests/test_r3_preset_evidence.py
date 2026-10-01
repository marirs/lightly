"""Codex re-review issue 3: missing or altered preset evidence must block 'validated'.

ingest used to load the full XMP with a silent `{}` fallback, and integrity checks covered photos only, so a kit
without its preset files (or with an edited preset / identity image) could still validate.
"""
import json
import make_kit
from test_kit_roundtrip import build


def _status(kit):
    import ingest_kit
    ingest_kit.main(kit)
    look = json.load(open(kit / "results/report.json"))["looks"]["test.1.x"]
    return look["global"]["status"], look["full"]["status"], look


def test_baseline_kit_validates(tmp_path):
    kit, _ = build(tmp_path)
    assert _status(kit)[:2] == ("validated", "validated")


def test_deleted_full_xmp_blocks_validation(tmp_path):
    kit, _ = build(tmp_path)
    (kit / "presets/full/test.1.x__full.xmp").unlink()
    g, f, look = _status(kit)
    assert f == "incomplete" and any("__full.xmp" in m for m in look["full"]["missing"]), look["full"]


def test_edited_preset_is_detected(tmp_path):
    kit, _ = build(tmp_path)
    p = kit / "presets/global/test.1.x__global.xmp"
    p.write_text(p.read_text().replace('crs:Exposure2012="0"', 'crs:Exposure2012="+1.00"'))
    g, f, look = _status(kit)
    assert g != "validated" and f != "validated"


def test_modified_identity_image_is_detected(tmp_path):
    kit, _ = build(tmp_path)
    p = kit / "identity/hald_64_srgb16.tif"
    data = bytearray(p.read_bytes()); data[-10] ^= 0xFF; p.write_bytes(bytes(data))
    g, f, _ = _status(kit)
    assert g != "validated" and f != "validated"
