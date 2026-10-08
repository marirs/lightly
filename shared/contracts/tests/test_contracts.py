"""Shared contracts: rendering-v2.json is generated and current, edit-recipe-v1 examples validate.

Run: python -m pytest shared/contracts/tests -q
"""
import json
import sys
from pathlib import Path

import pytest

CONTRACTS = Path(__file__).resolve().parents[1]
REPO = CONTRACTS.parents[1]
sys.path.insert(0, str(CONTRACTS))

import build_rendering_v2  # noqa: E402
import make_edit_recipe_examples as examples  # noqa: E402
import schema_check  # noqa: E402

RECIPES = REPO / "shared/fixtures/edit-recipe"


# --- rendering-v2 ---------------------------------------------------------------------------------

def test_rendering_contract_json_is_generated_and_current():
    assert build_rendering_v2.main(["--check"]) == 0, "run shared/contracts/build_rendering_v2.py"


def test_contract_constants_are_the_calibration_files_verbatim():
    contract = json.loads((CONTRACTS / "rendering-v2.json").read_text())
    model = contract["developModel"]
    calibration = json.loads((REPO / "experiments/presets/calibration_natural.json").read_text())
    spatial = json.loads((REPO / "experiments/presets/calibration_spatial_natural.json").read_text())
    assert model["constants"] == calibration["constants"]
    assert model["spatialConstants"] == spatial


def test_stage_order_is_the_whole_edit_pipeline():
    stages = json.loads((CONTRACTS / "rendering-v2.json").read_text())["stages"]
    # Revision 2 (contract fixes 2): Remove on the source first (C1); geometry after the layered stages (C2).
    assert [s["id"] for s in stages] == [
        "edit.remove", "auto", "develop.global", "develop.spatial", "edit.adjust",
        "background.replace", "background.focus", "portrait", "edit.geometry", "effects", "border", "watermark"]
    assert [s["order"] for s in stages] == list(range(1, 13))
    frames = {s["id"]: s["frame"] for s in stages}
    assert all(frames[i].startswith("source") for i in ("edit.remove", "edit.adjust", "background.replace",
                                                         "background.focus", "portrait"))
    assert frames["edit.geometry"] == "source → frame" and frames["effects"] == "frame"
    effects = next(s for s in stages if s["id"] == "effects")
    assert [o["id"] for o in effects["operators"]] == ["lightLeak", "selectiveColour", "presetVignette", "userVignette", "presetGrain", "userGrain"]


def test_contract_is_revision_6_with_continuous_light_leak():
    contract = json.loads((CONTRACTS / "rendering-v2.json").read_text())
    assert (contract["version"], contract["revision"]) == (2, 6)
    effects = next(s for s in contract["stages"] if s["id"] == "effects")
    leak = next(o for o in effects["operators"] if o["id"] == "lightLeak")["constants"]
    assert [stop["position"] for stop in leak["stops"]] == [0.0, 0.30, 0.55]
    assert [stop["alpha"] for stop in leak["stops"]] == ["intensity/130", "intensity/400", 0]
    assert "farthest-corner" in leak["shape"]


def test_every_operator_parameter_has_a_range_and_default():
    stages = json.loads((CONTRACTS / "rendering-v2.json").read_text())["stages"]
    for stage in stages:
        for operator in stage["operators"]:
            for name, spec in operator.get("params", {}).items():
                if spec.get("type") in ("number", "integer"):
                    assert spec["min"] <= spec["default"] <= spec["max"], (stage["id"], operator["id"], name)
                    assert spec["unit"], (stage["id"], operator["id"], name)


# --- edit-recipe-v1 -------------------------------------------------------------------------------

def test_examples_are_generated_and_current():
    assert examples.main(["--check"]) == 0, "run shared/contracts/make_edit_recipe_examples.py"


VALID = sorted(p for p in RECIPES.glob("*.json") if not p.name.startswith("invalid-"))
INVALID = sorted(RECIPES.glob("invalid-*.json"))


@pytest.mark.parametrize("path", VALID, ids=lambda p: p.stem)
def test_valid_example_passes_schema_and_reader_rules(path):
    state = json.loads(path.read_bytes())
    assert schema_check.validate_edit_recipe(state) == []


@pytest.mark.parametrize("path", INVALID, ids=lambda p: p.stem)
def test_invalid_example_is_rejected(path):
    assert schema_check.validate_edit_recipe(json.loads(path.read_bytes())) != []


@pytest.mark.parametrize("path", VALID + INVALID, ids=lambda p: p.stem)
def test_examples_are_canonical_bytes(path):
    data = path.read_bytes()
    assert not data.endswith(b"\n")
    assert examples.encode(json.loads(data)) == data


def test_every_prototype_tool_is_covered_by_an_example():
    """Each tool state in docs/ui/app/app.js newSession changes from neutral in at least one example."""
    neutral = json.loads((RECIPES / "neutral.json").read_bytes())
    changed = set()

    def walk(a, b, path):
        if isinstance(a, dict) and isinstance(b, dict):
            for key in a:
                walk(a[key], b.get(key), f"{path}.{key}")
        elif a != b:
            changed.add(path)

    for path in VALID:
        walk(json.loads(path.read_bytes()), neutral, "")
    required = [
        ".look", ".auto", ".tools.background.replacement", ".tools.background.subject.matte", ".tools.background.subject.refinements",
        ".tools.background.focus.blur", ".tools.background.focus.depthOfField", ".tools.background.focus.style",
        ".tools.background.focus.bokeh", ".tools.background.focus.styleAmount", ".tools.background.focus.target",
        ".tools.background.focus.depth.source", ".tools.background.focus.depth.map", ".tools.background.focus.depth.focusDepth",
        ".tools.portrait.faces", ".tools.edit.geometry.quarterTurns", ".tools.edit.geometry.flipHorizontal",
        ".tools.edit.geometry.perspective.vertical", ".tools.edit.geometry.straighten", ".tools.edit.geometry.crop.aspect",
        ".tools.edit.geometry.crop.rect", ".tools.edit.adjust.exposure", ".tools.edit.adjust.noise", ".tools.edit.remove.strokes",
        ".tools.effects.lightLeak.enabled", ".tools.effects.grain.enabled", ".tools.effects.vignette.enabled",
        ".tools.watermark.type", ".tools.watermark.signature", ".tools.watermark.text", ".tools.watermark.logo",
        ".tools.watermark.placement", ".tools.watermark.offset", ".tools.border.type", ".tools.border.spacing",
    ]
    missing = [p for p in required if not any(c == p or c.startswith(p + ".") or c.startswith(p + "[") for c in changed)]
    assert missing == []


def test_schema_2_documents_migrate_without_reinterpreting_anything():
    v2 = json.loads((REPO / "shared/fixtures/edit-state/v2-with-look.json").read_text())
    migrated = json.loads((RECIPES / "migrated-from-v2-with-look.json").read_bytes())
    for key in ("source", "auto", "look", "revision"):
        assert migrated[key] == v2[key]
    neutral = examples.neutral_tools()
    neutral["effects"]["grain"]["seed"] = migrated["tools"]["effects"]["grain"]["seed"]
    assert migrated["tools"] == neutral
    assert (migrated["schema"], migrated["recipeVersion"]) == (3, 1)


def test_demo_matches_the_approved_combined_edit():
    demo = json.loads((RECIPES / "demo-combined.json").read_bytes())
    tools = demo["tools"]
    assert demo["look"]["lookId"] == "look-d8704f3622765f1c77c4"   # Portrait stop 13 (design DEMO step 1)
    assert tools["background"]["replacement"]["scale"] == 120 and tools["background"]["focus"]["blur"] == 55
    assert tools["portrait"]["faces"][0]["skin"]["smoothing"] == 22 and tools["portrait"]["faces"][0]["underEye"]["brighten"] == 15
    assert tools["effects"]["vignette"]["enabled"] and tools["effects"]["grain"]["amount"] == 25
    assert (tools["border"]["type"], tools["watermark"]["type"], tools["watermark"]["placement"]) == ("polaroid", "signature", "border")
    ui = json.loads((REPO / "presets/develop-design-ui.json").read_text())
    portrait = next(c for c in ui["categories"] if c["id"] == "portrait")
    assert portrait["presets"][12]["id"] == demo["look"]["lookId"]


def test_validator_rejects_unsupported_schema_keywords():
    with pytest.raises(ValueError):
        schema_check.Validator({"type": "object", "patternProperties": {}}).errors({})
