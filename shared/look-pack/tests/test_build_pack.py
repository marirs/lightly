"""build_pack on a synthetic catalogue (no private files), plus a check of the real pack when it has been built."""
import hashlib
import json
from pathlib import Path

import pytest

import build_pack
import evidence

CURVE = '<crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>90, 70</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>'
MASK = ('<crs:MaskGroupBasedCorrections><rdf:Seq><rdf:li><rdf:Description crs:What="Correction" crs:LocalExposure2012="0.5"/>'
        '</rdf:li></rdf:Seq></crs:MaskGroupBasedCorrections>')
PRESETS = {
    "look-aaaaaaaaaaaaaaaaaaaa": ('crs:Exposure2012="+0.30" crs:Contrast2012="+20" crs:GrainAmount="15"', CURVE),
    "look-bbbbbbbbbbbbbbbbbbbb": ('crs:Saturation="-100" crs:ConvertToGrayscale="True" crs:GrayMixerRed="-20"', ""),
    "look-cccccccccccccccccccc": ('crs:Exposure2012="-0.20" crs:PostCropVignetteAmount="-30"', MASK),
}
LAYOUT = [("warm", "Warm", ["look-aaaaaaaaaaaaaaaaaaaa", "look-cccccccccccccccccccc"]), ("mono", "Mono", ["look-bbbbbbbbbbbbbbbbbbbb"])]


def xmp(attributes: str, body: str) -> bytes:
    return f"""<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
   crs:ProcessVersion="11.0" crs:UUID="0123" {attributes}>
   {body}
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
""".encode()


def make_catalogue(root: Path, tamper: str | None = None) -> Path:
    import lrsettings
    presets_dir = root / "presets"
    ui = {"schemaVersion": 1, "purpose": "test", "baseStop": {"stop": 0, "labelRule": "x"}, "orderRule": "natural", "categories": []}
    bindings = json.loads(json.dumps(ui))
    for cat_id, name, ids in LAYOUT:
        ui_presets, bound = [], []
        for stop, preset_id in enumerate(ids, 1):
            data = xmp(*PRESETS[preset_id])
            digest = hashlib.sha256(data).hexdigest()
            rel = f"library/{digest[:2]}/{digest}/{preset_id}.xmp"
            (presets_dir / rel).parent.mkdir(parents=True, exist_ok=True)
            (presets_dir / rel).write_bytes(data)
            settings = lrsettings.parse_bytes(data, rel, ".xmp").settings
            ui_presets.append({"id": preset_id, "displayName": f"Preset {preset_id[5:8]}", "stop": stop})
            bound.append({**ui_presets[-1], "sourceAssetId": digest, "sourceFile": rel,
                          "settingsSha256": build_pack.catalogue_settings_sha256(settings)})
        ui["categories"].append({"id": cat_id, "name": name, "presets": ui_presets})
        bindings["categories"].append({"id": cat_id, "name": name, "presets": bound})
    if tamper == "settings":
        bindings["categories"][0]["presets"][0]["settingsSha256"] = "0" * 64
    if tamper == "order":
        ui["categories"][0]["presets"].reverse()
    (presets_dir / "develop-design-ui.json").write_text(json.dumps(ui))
    (presets_dir / "develop-design-catalogue.json").write_text(json.dumps(bindings))
    return presets_dir


@pytest.fixture(scope="module")
def built(tmp_path_factory):
    root = tmp_path_factory.mktemp("pack")
    presets_dir = make_catalogue(root)
    manifest = build_pack.build(presets_dir, root / "out", log=lambda *_: None)
    return root, presets_dir, manifest


def test_manifest_format_and_provisional_status(built):
    _, _, manifest = built
    assert (manifest["format"], manifest["formatVersion"]) == ("lightly-look-pack", 3)
    assert manifest["status"]["state"] == "provisional"
    assert set(manifest["catalogue"]) >= {"uiSha256", "bindingsSha256"}
    assert manifest["generator"]["version"]


def test_categories_are_the_ui_catalogue_exactly(built):
    _, presets_dir, manifest = built
    ui = json.loads((presets_dir / "develop-design-ui.json").read_text())
    projected = [{"id": c["id"], "name": c["name"], "presets": [{k: p[k] for k in ("id", "displayName", "stop")} for p in c["presets"]]}
                 for c in manifest["categories"]]
    assert projected == ui["categories"]


def test_entries_carry_recipe_coverage_effects_and_unvalidated_status(built):
    _, _, manifest = built
    entries = {p["id"]: p for c in manifest["categories"] for p in c["presets"]}
    a, b, c = (entries[i] for i in PRESETS)
    assert a["operators"] == ["exposure", "toneSliders", "toneCurve", "grain"]
    assert a["effects"] == {"grain": True, "vignette": False} and c["effects"] == {"grain": False, "vignette": True}
    assert "grayscale" in b["operators"]
    assert c["completeness"] == "incomplete" and c["unsupported"][0]["code"] == "local-adjustments"
    for entry in entries.values():
        v = entry["validation"]
        assert (v["globalColour"]["status"], v["fullRecipe"]["status"], v["status"]) == ("not-run", "not-run", "approximate")
        assert v["binding"]["globalStage"] == "lr-model" and v["binding"]["recipeSha256"]
        assert entry["globalOverride"] is None and len(entry["lookVersion"]) == 12


def test_unconverted_side_file_keeps_the_mask_verbatim(built):
    root, presets_dir, _ = built
    side = json.loads((root / "out/unconverted.json").read_text())
    element = side["presets"]["look-cccccccccccccccccccc"]["MaskGroupBasedCorrections"]["element"]
    assert element == MASK


def test_build_is_deterministic(built, tmp_path):
    root, presets_dir, _ = built
    build_pack.build(presets_dir, tmp_path / "again", log=lambda *_: None)
    for name in ("manifest.json", "unconverted.json"):
        assert (tmp_path / "again" / name).read_bytes() == (root / "out" / name).read_bytes()


@pytest.mark.parametrize("tamper", ["settings", "order"])
def test_inputs_that_disagree_stop_the_build(tmp_path, tamper):
    presets_dir = make_catalogue(tmp_path, tamper)
    with pytest.raises(build_pack.PackBuildError):
        build_pack.build(presets_dir, tmp_path / "out", log=lambda *_: None)
    assert not (tmp_path / "out").exists()


def test_a_report_about_something_else_is_stale_and_never_promotes(built, tmp_path):
    _, presets_dir, _ = built
    report = {"looks": {"look-aaaaaaaaaaaaaaaaaaaa": {"global": {"status": "validated"}, "full": {"status": "validated"},
                                                      "evidence": {"lutSha256": "1" * 64, "recipeSha256": "2" * 64,
                                                                   "rendererSha256": evidence.renderer_digest()}}}}
    path = tmp_path / "report.json"
    path.write_text(json.dumps(report))
    manifest = build_pack.build(presets_dir, tmp_path / "out", validation_report=path, log=lambda *_: None)
    entry = manifest["categories"][0]["presets"][0]
    assert entry["validation"]["globalColour"]["status"] == "stale"
    assert entry["validation"]["status"] == "approximate"


def test_hald_override_only_with_bound_validated_evidence(built, tmp_path):
    import ingest_kit
    import lrsettings
    import make_kit
    import pack_common
    _, presets_dir, _ = built
    preset_id = "look-aaaaaaaaaaaaaaaaaaaa"
    hald_dir = tmp_path / "hald"
    hald_dir.mkdir()
    make_kit.write_hald(hald_dir / f"{preset_id}__global.tif")
    lut_sha = evidence.lut_digest(pack_common.lut_bytes(ingest_kit.hald_to_lut(hald_dir / f"{preset_id}__global.tif")))
    data = xmp(*PRESETS[preset_id])
    settings = lrsettings.parse_bytes(data, "x.xmp", ".xmp").settings
    good = {"lutSha256": lut_sha, "recipeSha256": evidence.recipe_digest(settings), "rendererSha256": evidence.renderer_digest()}
    for bound, expected in ((good, "lightroom-hald"), ({**good, "lutSha256": "0" * 64}, None)):
        report = {"looks": {preset_id: {"global": {"status": "validated"}, "full": {"status": "not-run"}, "evidence": bound}}}
        path = tmp_path / "report.json"
        path.write_text(json.dumps(report))
        manifest = build_pack.build(presets_dir, tmp_path / "out", validation_report=path, hald_dir=hald_dir, log=lambda *_: None)
        entry = manifest["categories"][0]["presets"][0]
        if expected:
            assert entry["globalOverride"]["source"] == expected
            assert (tmp_path / "out" / entry["globalOverride"]["lutFile"]).exists()
            assert entry["validation"]["status"] == "global-colour-validated"
        else:
            assert entry["globalOverride"] is None and entry["validation"]["status"] == "approximate"


REAL_PACK = build_pack.DEFAULT_OUT / "manifest.json"


@pytest.mark.skipif(not REAL_PACK.exists(), reason="real pack not built (needs the private library)")
def test_real_pack_matches_the_fixed_catalogue():
    manifest = json.loads(REAL_PACK.read_text())
    ui = json.loads((build_pack.DEFAULT_PRESETS / "develop-design-ui.json").read_text())
    projected = [{"id": c["id"], "name": c["name"], "presets": [{k: p[k] for k in ("id", "displayName", "stop")} for p in c["presets"]]}
                 for c in manifest["categories"]]
    assert projected == ui["categories"]
    assert manifest["summary"]["presets"] == 2591
    assert manifest["catalogue"]["uiSha256"] == hashlib.sha256((build_pack.DEFAULT_PRESETS / "develop-design-ui.json").read_bytes()).hexdigest()
    assert all(p["validation"]["status"] == "approximate" for c in manifest["categories"] for p in c["presets"])
    assert manifest["verification"]["maxAbsVsLrModel"] <= build_pack.RECIPE_VERIFY_TOLERANCE
    size = sum(p.stat().st_size for p in REAL_PACK.parent.rglob("*") if p.is_file() and p.name != "unconverted.json")
    assert size < 15e6
