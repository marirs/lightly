"""Codex finding 3: regenerating the kit must never delete Lightroom exports or results."""
import pytest
import make_kit


def test_regeneration_preserves_exports_and_results(tmp_path, monkeypatch):
    kit = tmp_path / "kit"
    (kit / "exports/photos").mkdir(parents=True)
    (kit / "results").mkdir(parents=True)
    export = kit / "exports/photos/natural.1.x__global__night_01.jpg"
    export.write_bytes(b"lightroom output")
    (kit / "results/report.json").write_text("{}")
    monkeypatch.setattr(make_kit, "KIT", kit)
    with pytest.raises(make_kit.KitHasExportsError):
        make_kit.prepare_kit_dir(kit)
    assert export.read_bytes() == b"lightroom output"
    assert (kit / "results/report.json").exists()


def test_new_version_goes_to_a_fresh_directory(tmp_path):
    kit = tmp_path / "kit"
    (kit / "exports/photos").mkdir(parents=True)
    (kit / "exports/photos/a.jpg").write_bytes(b"x")
    fresh = make_kit.prepare_kit_dir(kit, new_version=True)
    assert fresh != kit and fresh.exists() and not any(fresh.rglob("*.jpg"))
    assert (kit / "exports/photos/a.jpg").exists()


def test_main_never_deletes_existing_exports(tmp_path, monkeypatch):
    """Behavioural reproduction: the original main() rmtree'd the whole kit, exports included."""
    kit = tmp_path / "kit"
    (kit / "exports/hald").mkdir(parents=True)
    export = kit / "exports/hald/natural.1.x__global.tif"
    export.write_bytes(b"lightroom output")
    monkeypatch.setattr(make_kit, "KIT", kit)
    monkeypatch.setattr(make_kit, "ROOT", tmp_path / "no-presets-here")
    try:
        make_kit.main()
    except Exception:
        pass  # any failure is fine; destroying the export is not
    assert export.exists(), "make_kit deleted a Lightroom export"
