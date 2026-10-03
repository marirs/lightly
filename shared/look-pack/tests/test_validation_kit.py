"""make_kit_v2: the Lightroom validation kit for the pack v2 sample (inputs only)."""
import json

import pytest

import make_kit_v2


def test_sample_is_the_parity_set_minus_nested_structures():
    included, excluded = make_kit_v2.sample()
    parity = json.loads(make_kit_v2.PARITY.read_text())
    ids = [p["id"] for c in parity["categories"] for p in c["presets"]]
    assert sorted(e["look_id"] for e in included + excluded) == sorted(ids)
    assert excluded and all(e["reason"].startswith("kit preset cannot carry nested") for e in excluded)
    assert any(e["completeness"] == "incomplete" for e in included), "scalar-only gaps stay in the sample"
    assert len(included) >= 30


@pytest.mark.skipif(not make_kit_v2.CATALOGUE.exists(), reason="needs the private preset library")
def test_kit_uses_pack_ids_and_records_its_inputs(tmp_path, monkeypatch):
    monkeypatch.setattr(make_kit_v2, "KIT_V2", tmp_path / "kit-v2")
    kit = make_kit_v2.main()
    shortlist = json.loads((kit / "shortlist.json").read_text())
    included, _ = make_kit_v2.sample()
    assert [e["look_id"] for e in shortlist] == [e["look_id"] for e in included]
    inputs = json.loads((kit / "inputs.json").read_text())
    assert inputs["hald_sha256"] and len(inputs["photos"]) >= 20
    for entry in shortlist:
        assert (kit / entry["original_file"]).exists() and (kit / entry["global_xmp"]).exists()
