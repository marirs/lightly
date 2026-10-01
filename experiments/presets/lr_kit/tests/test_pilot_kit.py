"""The pilot kit is a small, complete kit for checking the Lightroom import/export workflow before the full run."""
import json
import make_kit


def test_pilot_selection_is_small_and_covers_the_risks():
    looks, photos = make_kit.PILOT["looks"], make_kit.PILOT["photos"]
    assert len(looks) == 2 and len(photos) <= 4
    assert "fixture_smooth" in photos                       # grain evidence
    assert {"landscape_01", "wellexposed_02"} <= set(photos)  # Display P3 + Adobe RGB colour management
    shortlist = json.load(open(make_kit.PRESETS / "shortlist.json"))
    ids = {make_kit.look_id(r): r for c in shortlist.values() for r in c["looks"]}
    assert set(looks) <= set(ids), set(looks) - set(ids)


def test_pilot_kit_contains_only_the_pilot_inputs(tmp_path, monkeypatch):
    monkeypatch.setattr(make_kit, "KIT", tmp_path / "kit-pilot")
    kit = make_kit.main(pilot=True)
    inputs = json.load(open(kit / "inputs.json"))
    assert sorted(inputs["photos"]) == sorted(make_kit.PILOT["photos"])
    assert sorted(e["look_id"] for e in json.load(open(kit / "shortlist.json"))) == sorted(make_kit.PILOT["looks"])
    assert "PILOT" in (kit / "README.md").read_text()


def test_readme_counts_match_the_kit(tmp_path, monkeypatch):
    monkeypatch.setattr(make_kit, "KIT", tmp_path / "kit-pilot")
    kit = make_kit.main(pilot=True)
    text = (kit / "README.md").read_text()
    assert "{{" not in text and "1 HALD + 4 global-only photos" in text
