"""Look catalog and Look pack: browse order, stable IDs, data-driven categories, pack contents.

Run: python -m pytest tests -q   (from experiments/presets/look_pack)
"""
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
import pytest

LOOK_PACK = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LOOK_PACK))

import build_look_pack  # noqa: E402
import pack_common as pc  # noqa: E402
from ordering import MAX_EXACT_STOPS, NEAR_DUPLICATE_STEP_DE, shortest_browse_path  # noqa: E402
import make_kit  # noqa: E402  (on sys.path via pack_common)

LUT_BYTES = 33 ** 3 * 4 * 4


# --- Browse order --------------------------------------------------------------------------------

def test_browse_order_follows_similarity_not_strength():
    # Strength from Auto: A 2, B 5, C 6. B and A are far apart; C sits between them visually.
    from_auto = [2.0, 5.0, 6.0]
    pairwise = [[0, 6, 1], [6, 0, 1], [1, 1, 0]]
    path = shortest_browse_path(from_auto, pairwise, ["A", "B", "C"])
    assert path.order == (0, 2, 1), "A → C → B: each step is the smallest change, not A → B → C by strength"
    assert path.step_de == (2.0, 1.0, 1.0)
    assert path.total_de == 4.0


def test_browse_order_is_the_exact_shortest_path():
    rng = np.random.default_rng(7)
    points = rng.normal(size=(6, 3)) * 4
    from_auto = list(np.linalg.norm(points, axis=1))
    pairwise = [[float(np.linalg.norm(a - b)) for b in points] for a in points]
    path = shortest_browse_path(from_auto, pairwise, [f"p{i}" for i in range(6)])
    from itertools import permutations
    best = min(from_auto[o[0]] + sum(pairwise[a][b] for a, b in zip(o, o[1:])) for o in permutations(range(6)))
    assert path.total_de == pytest.approx(best)


def test_browse_order_ties_are_broken_by_name():
    path = shortest_browse_path([1.0, 1.0], [[0, 1], [1, 0]], ["Zeta", "Alpha"])
    assert path.order == (1, 0)


def test_near_duplicate_steps_are_reported():
    path = shortest_browse_path([3.0, 3.5], [[0, NEAR_DUPLICATE_STEP_DE / 2], [NEAR_DUPLICATE_STEP_DE / 2, 0]], ["A", "B"])
    assert path.near_duplicate_steps() == [1]


def test_a_category_is_a_handful_of_stops():
    count = MAX_EXACT_STOPS + 1
    with pytest.raises(ValueError):
        shortest_browse_path([1.0] * count, [[0.0] * count for _ in range(count)], [str(i) for i in range(count)])


# --- IDs and names -------------------------------------------------------------------------------

def test_look_id_does_not_depend_on_category_or_stop():
    source = "Pack.zip -> Trending/Nordic/Nordic Tone  (10).dng"
    assert pc.stable_look_id("Nordic Tone  (10)", source) == pc.stable_look_id("Nordic Tone (10)", source)
    assert pc.stable_look_id("Nordic Tone (10)", source).startswith("nordic-tone-10-")
    assert pc.stable_look_id("Nordic Tone (10)", source) != pc.stable_look_id("Nordic Tone (10)", source + "x")


def test_display_name_is_the_preset_name():
    assert pc.display_name("  Nordic Tone  (10) ") == "Nordic Tone (10)"
    assert pc.display_name("S1 - Vibes") == "S1 - Vibes"


# --- Pack ----------------------------------------------------------------------------------------

def _write_preset(collection: Path, name: str, settings: dict) -> str:
    source = f"{name}.xmp"
    (collection / source).write_text(make_kit.settings_to_xmp({"ProcessVersion": "11.0", **settings}, name))
    return source


def _catalog(path: Path, categories: list[tuple[str, str, list[tuple[str, str]]]]) -> Path:
    catalog = {"catalogVersion": 1, "categories": [
        {"id": cid, "label": label, "labelStatus": "provisional",
         "stops": [{"lookId": pc.stable_look_id(name, source), "name": pc.display_name(name), "source": source}
                   for name, source in stops]}
        for cid, label, stops in categories]}
    path.write_text(json.dumps(catalog))
    return path


@pytest.fixture
def collection(tmp_path):
    root = tmp_path / "collection"
    root.mkdir()
    return root


def test_pack_follows_the_catalog_categories_and_order(tmp_path, collection):
    warm = _write_preset(collection, "Warm One", {"Temperature": "+20", "Vibrance": "10"})
    faded = _write_preset(collection, "Faded", {"ParametricShadows": "30", "Contrast2012": "-20"})
    grainy = _write_preset(collection, "Grainy", {"Saturation": "-30", "GrainAmount": "25", "Clarity2012": "10"})
    # Labels are arbitrary data: nothing in the pack knows "Natural/Warm/...".
    catalog = _catalog(tmp_path / "catalog.json", [
        ("cat-b", "Second label", [("Grainy", grainy), ("Faded", faded)]),
        ("cat-a", "First label", [("Warm One", warm)]),
    ])
    out = tmp_path / "pack"
    manifest = build_look_pack.build(collection, out, catalog_path=catalog, kit_ids={})

    assert [c["label"] for c in manifest["categories"]] == ["Second label", "First label"]
    assert [s["name"] for s in manifest["categories"][0]["stops"]] == ["Grainy", "Faded"], "catalog order is kept"
    assert all(c["labelStatus"] == "provisional" for c in manifest["categories"])
    for stop in (s for c in manifest["categories"] for s in c["stops"]):
        data = (out / stop["lutFile"]).read_bytes()
        assert len(data) == LUT_BYTES
        assert stop["lutSha256"] == hashlib.sha256(data).hexdigest()
        assert stop["lookVersion"] == stop["lutSha256"][:12]
        assert stop["lutSource"] == "lr-model-approximation"
        assert stop["status"] == "approximate" and stop["globalColour"]["status"] == "not-run"
    grainy_stop = manifest["categories"][0]["stops"][0]
    assert grainy_stop["omittedOperators"] == ["clarity", "grain"]
    assert json.loads((out / "manifest.json").read_text()) == manifest


def test_look_version_changes_with_the_lut(tmp_path, collection):
    source = _write_preset(collection, "Look", {"Saturation": "-20"})
    catalog = _catalog(tmp_path / "catalog.json", [("cat", "Label", [("Look", source)])])
    first = build_look_pack.build(collection, tmp_path / "a", catalog_path=catalog, kit_ids={})
    _write_preset(collection, "Look", {"Saturation": "-40"})
    second = build_look_pack.build(collection, tmp_path / "b", catalog_path=catalog, kit_ids={})
    a, b = first["categories"][0]["stops"][0], second["categories"][0]["stops"][0]
    assert a["lookId"] == b["lookId"]
    assert a["lookVersion"] != b["lookVersion"]


def test_lightroom_hald_is_preferred_and_changes_what_is_omitted(tmp_path, collection):
    source = _write_preset(collection, "Hazy", {"Dehaze": "20", "Saturation": "-10"})
    catalog = _catalog(tmp_path / "catalog.json", [("cat", "Label", [("Hazy", source)])])
    hald_dir = tmp_path / "hald"
    hald_dir.mkdir()
    make_kit.write_hald(hald_dir / "kit.1.hazy__global.tif")  # an identity "Lightroom render"
    manifest = build_look_pack.build(collection, tmp_path / "pack", hald_dir=hald_dir, catalog_path=catalog,
                                     kit_ids={source: "kit.1.hazy"})
    stop = manifest["categories"][0]["stops"][0]
    assert stop["lutSource"] == "lightroom-hald"
    assert stop["lightroomHald"] == "kit.1.hazy__global.tif"
    assert stop["omittedOperators"] == ["dehaze"] and stop["approximatedGlobally"] == []
    rgba = np.frombuffer((tmp_path / "pack" / stop["lutFile"]).read_bytes(), dtype=np.float32).reshape(33, 33, 33, 4)
    identity = np.moveaxis(pc.ia.identity_lut(33), 0, -1)
    assert np.abs(rgba[..., :3] - identity).max() < 1e-3


def test_rebuilding_never_mixes_two_catalog_versions(tmp_path, collection):
    first = _write_preset(collection, "First", {"Saturation": "-20"})
    second = _write_preset(collection, "Second", {"Saturation": "20"})
    out = tmp_path / "pack"
    build_look_pack.build(collection, out, catalog_path=_catalog(tmp_path / "c1.json", [("c", "L", [("First", first)])]), kit_ids={})
    build_look_pack.build(collection, out, catalog_path=_catalog(tmp_path / "c2.json", [("c", "L", [("Second", second)])]), kit_ids={})
    assert [p.name for p in (out / "luts").iterdir()] == [f"{pc.stable_look_id('Second', second)}.f32"]


# --- The committed catalog -----------------------------------------------------------------------

def test_committed_catalog_is_consistent_with_the_shortlist():
    catalog = json.loads((LOOK_PACK / "catalog.json").read_text())
    shortlist = json.loads((LOOK_PACK.parent / "shortlist.json").read_text())
    shortlist_sources = {rec["source"] for c in shortlist.values() for rec in c["looks"]}
    ids = [s["lookId"] for c in catalog["categories"] for s in c["stops"]]
    assert len(ids) == len(set(ids)), "a preset appears in one category only"
    assert {s["source"] for c in catalog["categories"] for s in c["stops"]} == shortlist_sources
    for category in catalog["categories"]:
        assert category["labelStatus"] == "provisional"
        assert 1 <= len(category["stops"]) <= MAX_EXACT_STOPS
        assert category["orderMethod"] in ("shortest-visual-path-from-auto", "override")
        for stop in category["stops"]:
            assert stop["lookId"] == pc.stable_look_id(stop["name"], stop["source"])


# --- Status: global colour and full recipe are separate (format 2) -------------------------------

def _report(path: Path, looks: dict) -> Path:
    path.write_text(json.dumps({"looks": looks}))
    return path


def _one_look_pack(tmp_path, collection, settings, report=None, hald=False):
    source = _write_preset(collection, "Look", settings)
    catalog = _catalog(tmp_path / "catalog.json", [("cat", "Label", [("Look", source)])])
    hald_dir = None
    if hald:
        hald_dir = tmp_path / "hald"
        hald_dir.mkdir()
        make_kit.write_hald(hald_dir / "kit.1.look__global.tif")
    manifest = build_look_pack.build(collection, tmp_path / "pack", hald_dir=hald_dir, catalog_path=catalog,
                                     kit_ids={source: "kit.1.look"}, validation_report=report)
    return manifest["categories"][0]["stops"][0], manifest


def test_format_2_has_no_single_validation_flag(tmp_path, collection):
    stop, manifest = _one_look_pack(tmp_path, collection, {"Saturation": "-20"})
    assert manifest["formatVersion"] == 2
    assert "validation" not in stop
    assert stop["globalColour"] == {"status": "not-run", "evidence": None}
    assert stop["fullRecipe"] == {"status": "not-run", "evidence": None}
    assert stop["status"] == "approximate"
    assert stop["conversion"] == "approximate"


def test_global_colour_pass_alone_never_promotes_to_validated(tmp_path, collection):
    report = _report(tmp_path / "report.json", {"kit.1.look": {"global": {"status": "validated"}, "full": {"status": "failed"}}})
    stop, _ = _one_look_pack(tmp_path, collection, {"Saturation": "-20"}, report=report, hald=True)
    assert stop["globalColour"]["status"] == "validated"
    assert stop["fullRecipe"]["status"] == "failed"
    assert stop["status"] == "global-colour-validated"


def test_global_colour_from_the_model_is_not_evidence(tmp_path, collection):
    # A report can only vouch for the LUT it measured: Lightroom's HALD. A model LUT stays approximate.
    report = _report(tmp_path / "report.json", {"kit.1.look": {"global": {"status": "validated"}, "full": {"status": "validated"}}})
    stop, _ = _one_look_pack(tmp_path, collection, {"Saturation": "-20"}, report=report, hald=False)
    assert stop["lutSource"] == "lr-model-approximation"
    assert stop["status"] == "approximate"


def test_missing_effects_keep_conversion_unfinished_even_if_numbers_pass(tmp_path, collection):
    report = _report(tmp_path / "report.json", {"kit.1.look": {"global": {"status": "validated"}, "full": {"status": "validated"}}})
    stop, _ = _one_look_pack(tmp_path, collection, {"Saturation": "-20", "GrainAmount": "20"}, report=report, hald=True)
    assert stop["omittedOperators"] == ["grain"]
    assert stop["conversion"] == "approximate"
    assert stop["status"] == "global-colour-validated", "full recipe cannot be validated while an effect is missing"


def test_everything_passing_with_nothing_missing_is_validated(tmp_path, collection):
    report = _report(tmp_path / "report.json", {"kit.1.look": {"global": {"status": "validated"}, "full": {"status": "validated"}}})
    stop, _ = _one_look_pack(tmp_path, collection, {"Saturation": "-20"}, report=report, hald=True)
    assert stop["conversion"] == "complete"
    assert stop["status"] == "validated"
    assert stop["globalColour"]["evidence"] == "report.json"
