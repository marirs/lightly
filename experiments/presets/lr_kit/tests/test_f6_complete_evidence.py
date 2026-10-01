"""Codex finding 6: 'validated' only with complete evidence.

The expected photo set must come from the kit's recorded inputs (not whatever files remain), every neutral
(no-preset) export must exist, and every required Look export must exist. Anything missing -> 'incomplete'.
"""
import json
import numpy as np
from PIL import Image
import ingest_kit, make_kit
from test_kit_roundtrip import build


def _report(kit):
    ingest_kit.main(kit)
    return json.load(open(kit / "results/report.json"))


def test_missing_neutral_export_blocks_validation(tmp_path):
    kit, _ = build(tmp_path)
    (kit / "exports/photos/none__sunset_02.jpg").unlink()
    rep = _report(kit)
    assert rep["neutral_baseline_ok"] is False
    assert all(rep["looks"]["test.1.x"][v]["status"] != "validated" for v in ("global", "full"))


def test_input_photo_removed_from_folder_is_detected(tmp_path):
    kit, _ = build(tmp_path)
    # Remove an input AND its exports: the old ingest derived the photo set from the folder and validated anyway.
    for p in [kit / "photos/sunset_02.jpg", kit / "exports/photos/none__sunset_02.jpg"] + list((kit / "exports/photos").glob("*__sunset_02.jpg")):
        p.unlink(missing_ok=True)
    rep = _report(kit)
    for v in ("global", "full"):
        assert rep["looks"]["test.1.x"][v]["status"] == "incomplete"
        assert any("sunset_02" in m for m in rep["looks"]["test.1.x"][v]["missing"])


def test_modified_input_photo_is_detected(tmp_path):
    kit, _ = build(tmp_path)
    img = np.asarray(Image.open(kit / "photos/sunset_02.jpg")).copy(); img[:5] = 0
    Image.fromarray(img).save(kit / "photos/sunset_02.jpg", quality=100)
    rep = _report(kit)
    assert all(rep["looks"]["test.1.x"][v]["status"] != "validated" for v in ("global", "full"))
    assert "sunset_02" in json.dumps(rep.get("changed_inputs", []))
