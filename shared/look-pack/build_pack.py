"""Build the shared Look pack v2 (manifest formatVersion 3) that both apps bundle.

    python shared/look-pack/build_pack.py [--presets-dir presets] [--out shared/look-pack/out]
                                          [--validation-report KIT/results/report.json] [--hald-dir KIT/exports/hald]

Inputs (never modified):
- presets/develop-design-ui.json          categories, ids, display names, stops: copied exactly, never reordered
- presets/develop-design-catalogue.json   private bindings: sourceFile under presets/library, settingsSha256
- presets/library/                        the source XMP files

Output (`out/`, git-ignored, fully derived and deterministic):
- manifest.json   format "lightly-look-pack", formatVersion 3: per preset the converted recipe, its operators,
                  approximated / unsupported / notApplied records, effects flags, validation bound to evidence
- luts/<id>.f32   only for a preset whose Lightroom HALD LUT is validated by bound evidence (none today)
- unconverted.json  every unsupported / not-applied source setting, verbatim, keyed by preset id (not bundled
                  by the apps; kept so a later converter never needs the private library)

The pack is PROVISIONAL until the native ports prove recipe→LUT parity and browsing performance on both
platforms (docs/v1/preset-pack.md §Parity); the manifest says so in `status`.

Recipes, not LUTs (docs/v1/plan.md decision 1): the apps bake the global LUT on the device from the recipe.
Every preset is verified while building: its recipe, rendered by reference_model, must reproduce
lr_model.render on the original Lightroom settings, so the recipe provably carries everything the model reads.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from collections import Counter
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path[:0] = [str(HERE), str(REPO / "experiments/presets/look_pack")]

import convert  # noqa: E402  (also puts experiments/presets on sys.path)
import reference_model as rm  # noqa: E402
import build_look_pack as legacy_pack  # noqa: E402  (validation semantics shared with format 2)
import evidence  # noqa: E402
import lrsettings  # noqa: E402

FORMAT = "lightly-look-pack"
FORMAT_VERSION = 3  # 3: recipes instead of LUTs, coverage records, all 2,591 catalogue presets
GENERATOR = {"name": "shared/look-pack/build_pack.py", "version": "1.0.0"}
# Product decision: the recipe architecture is not final for the full catalogue until both native ports
# prove recipe→LUT parity (golden vectors) and browsing performance. Apps must surface nothing as final.
PACK_STATUS = {"state": "provisional", "until": "native recipe→LUT parity and browsing performance are proven on iOS "
               "and Android (docs/v1/preset-pack.md, Parity)", "paritySubset": "shared/fixtures/look-pack/manifest-parity.json"}
DEFAULT_PRESETS = REPO / "presets"
DEFAULT_OUT = HERE / "out"
# The recipe must reproduce lr_model within float32 noise (measured worst case 3.7e-4 over the collection).
RECIPE_VERIFY_TOLERANCE = 1e-3
# Same identity fields the design catalogue strips before hashing (scripts/build_design_catalogue.py).
CATALOGUE_DISPLAY_METADATA = {"Name", "ShortName", "SortName", "Group", "UUID", "Copyright", "ContactInfo", "Description"}


class PackBuildError(RuntimeError):
    """The inputs disagree with each other; nothing is written."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def catalogue_settings_sha256(settings: dict) -> str:
    """settingsSha256 exactly as scripts/build_design_catalogue.py computes it."""
    kept = {k: v for k, v in settings.items() if k not in CATALOGUE_DISPLAY_METADATA}
    return sha256_bytes(json.dumps(kept, sort_keys=True, ensure_ascii=False).encode())


# ------------------------------------------------------------------ verification

def _probe_set() -> np.ndarray:
    grid = rm.lut_grid(9).reshape(-1, 3)
    rng = np.random.default_rng(20261003)
    return np.concatenate([grid, rng.random((256, 3))])


PROBES = _probe_set()


class ModelOracle:
    """lr_model (PyTorch), the calibrated source of truth, loaded once with the contract's constants."""

    def __init__(self, develop_model: dict):
        import torch  # noqa: PLC0415
        import lr_model  # noqa: PLC0415
        torch.set_num_threads(4)
        self.torch, self.lr_model = torch, lr_model
        self.calib = lr_model.Calib()
        self.calib.load_state_dict({k: torch.tensor(v) for k, v in develop_model["constants"].items()})

    def render(self, settings: dict, rgb: np.ndarray) -> np.ndarray:
        with self.torch.no_grad():
            preset = self.lr_model.Preset(settings, wb_mode="rendered")
            return self.lr_model.render(self.torch.from_numpy(rgb.astype(np.float32)), preset, self.calib).numpy()

    def model_lut_bytes(self, settings: dict) -> bytes:
        """33³ RGBA float32 bytes of the model LUT (the encoding evidence.lut_digest hashes)."""
        import pack_common  # noqa: PLC0415
        return pack_common.lut_bytes(pack_common.lr_model_lut(settings))


def verify_recipe(recipe: dict, settings: dict, model: dict, oracle: ModelOracle) -> float:
    ours = rm.develop_global(PROBES, recipe, model)
    theirs = oracle.render(settings, PROBES)
    return float(np.abs(ours - theirs).max())


# ------------------------------------------------------------------ versions and validation

def look_version(recipe: dict, model: dict, override_sha256: str | None) -> str:
    """rendering-v2.json lookVersion: changes whenever the pixels the Look renders could change."""
    body = {"recipeVersion": convert.RECIPE_VERSION, "recipe": recipe,
            "developModel": {"id": model["id"], "version": model["version"], "constantsSha256": model["constantsSha256"]},
            "globalOverrideSha256": override_sha256}
    return sha256_bytes(canonical_json(body))[:12]


def validation_block(preset_id: str, settings: dict, report: dict | None, report_name: str | None,
                     global_stage: str, lut_bytes_fn, unsupported: list) -> dict:
    """Validation bound to evidence digests (experiments/presets/evidence.py), format-2 semantics.

    The model LUT digest is computed only when a report mentions this preset: without a report every
    validation is not-run and no digest is needed.
    """
    mentioned = bool((report or {}).get("looks", {}).get(preset_id))
    lut_sha = evidence.lut_digest(lut_bytes_fn()) if mentioned else None
    shipped = {"lutSha256": lut_sha, "recipeSha256": evidence.recipe_digest(settings),
               "rendererSha256": evidence.renderer_digest()}
    global_colour = legacy_pack._validation(report, report_name, preset_id, "global", shipped)
    full_recipe = legacy_pack._validation(report, report_name, preset_id, "full", shipped)
    lut_source = "lightroom-hald" if global_stage == "lightroom-hald" else "lr-model-approximation"
    omitted = [entry["code"] for entry in unsupported]
    return {
        "globalColour": global_colour,
        "fullRecipe": full_recipe,
        "conversion": "complete" if lut_source == "lightroom-hald" and not omitted else "approximate",
        "status": legacy_pack.promoted_status(lut_source, omitted, global_colour["status"], full_recipe["status"]),
        "binding": {"globalStage": global_stage, "recipeSha256": shipped["recipeSha256"],
                    "rendererSha256": shipped["rendererSha256"], "lutSha256": lut_sha},
    }


def hald_override(preset_id: str, hald_dir: Path | None, report: dict | None, report_name: str | None,
                  settings: dict, unsupported: list):
    """A Lightroom HALD LUT replaces the model bake only when its global-colour evidence is bound and passed."""
    if hald_dir is None:
        return None
    hald = hald_dir / f"{preset_id}__global.tif"
    if not hald.exists():
        return None
    import ingest_kit  # noqa: PLC0415 (lr_kit, only needed when HALD exports exist)
    import pack_common  # noqa: PLC0415
    data = pack_common.lut_bytes(ingest_kit.hald_to_lut(hald))
    block = validation_block(preset_id, settings, report, report_name, "lightroom-hald", lambda: data, unsupported)
    if block["globalColour"]["status"] != "validated":
        return None
    return data, block


# ------------------------------------------------------------------ build

def load_catalogue(presets_dir: Path) -> tuple[dict, dict, dict]:
    ui_bytes = (presets_dir / "develop-design-ui.json").read_bytes()
    bindings_bytes = (presets_dir / "develop-design-catalogue.json").read_bytes()
    ui, bindings = json.loads(ui_bytes), json.loads(bindings_bytes)
    by_id = {}
    for ui_cat, b_cat in zip(ui["categories"], bindings["categories"], strict=True):
        if (ui_cat["id"], ui_cat["name"]) != (b_cat["id"], b_cat["name"]):
            raise PackBuildError(f"category mismatch: {ui_cat['id']} vs {b_cat['id']}")
        for ui_p, b_p in zip(ui_cat["presets"], b_cat["presets"], strict=True):
            if (ui_p["id"], ui_p["displayName"], ui_p["stop"]) != (b_p["id"], b_p["displayName"], b_p["stop"]):
                raise PackBuildError(f"preset mismatch in {ui_cat['id']}: {ui_p['id']} vs {b_p['id']}")
            by_id[ui_p["id"]] = b_p
    hashes = {"uiSha256": sha256_bytes(ui_bytes), "bindingsSha256": sha256_bytes(bindings_bytes)}
    return ui, by_id, hashes


def convert_preset(ui_preset: dict, binding: dict, presets_dir: Path, model: dict, oracle: ModelOracle,
                   report, report_name, hald_dir, out: Path) -> dict:
    preset_id = ui_preset["id"]
    source = presets_dir / binding["sourceFile"]
    data = source.read_bytes()
    if sha256_bytes(data) != binding["sourceAssetId"]:
        raise PackBuildError(f"{preset_id}: source file bytes do not match sourceAssetId")
    parsed = lrsettings.parse_bytes(data, binding["sourceFile"], ".xmp")
    if parsed.error:
        raise PackBuildError(f"{preset_id}: {parsed.error}")
    settings = parsed.settings
    if catalogue_settings_sha256(settings) != binding["settingsSha256"]:
        raise PackBuildError(f"{preset_id}: parsed settings do not match the catalogue's settingsSha256")
    xmp_text = data.decode("utf-8", "ignore")
    recipe, operators, malformed = convert.build_recipe(settings, preset_id)
    overridden = convert.check_no_nested_override(settings, xmp_text, operators)
    if overridden:
        raise PackBuildError(f"{preset_id}: nested value overrides consumed settings {overridden}")
    error = verify_recipe(recipe, settings, model, oracle)
    if error > RECIPE_VERIFY_TOLERANCE:
        raise PackBuildError(f"{preset_id}: recipe does not reproduce lr_model (max |Δ| {error:.2e})")
    cov = convert.coverage(settings, operators, malformed, convert.iso_dependent_keys(xmp_text))
    verbatim = convert.unconverted_verbatim(xmp_text, settings, cov)

    override = hald_override(preset_id, hald_dir, report, report_name, settings, cov["unsupported"])
    global_override = None
    if override is not None:
        lut_data, validation = override
        lut_file = f"luts/{preset_id}.f32"
        (out / lut_file).write_bytes(lut_data)
        global_override = {"source": "lightroom-hald", "lutFile": lut_file, "lutSha256": sha256_bytes(lut_data),
                           "lutDimension": 33, "lutEncoding": "rgba-float32-red-fastest",
                           "note": "develop.global = model restricted to toneSliders and dehaze, then this LUT"}
    else:
        validation = validation_block(preset_id, settings, report, report_name, "lr-model",
                                      lambda: oracle.model_lut_bytes(settings), cov["unsupported"])
    finishing = recipe["finishing"]
    return {
        "id": preset_id,
        "displayName": ui_preset["displayName"],
        "stop": ui_preset["stop"],
        "sourceAssetId": binding["sourceAssetId"],
        "settingsSha256": binding["settingsSha256"],
        "processVersion": str(settings.get("ProcessVersion", "")),
        "recipeVersion": convert.RECIPE_VERSION,
        "lookVersion": look_version(recipe, model, global_override and global_override["lutSha256"]),
        "operators": operators,
        "recipe": recipe,
        # Representation, not fidelity: never read as validated (validation is the separate block below).
        "completeness": convert.completeness(cov),
        "approximated": cov["approximated"],
        "unsupported": cov["unsupported"],
        "notApplied": cov["notApplied"],
        # Drives the approved "added on top, not replaced" notice in Effects; from the real settings.
        "effects": {"grain": "grain" in finishing, "vignette": "vignette" in finishing},
        "validation": validation,
        "globalOverride": global_override,
        "_verifyMaxAbs": error,
        "_unconverted": verbatim,
    }


def summarise(entries: list[dict]) -> dict:
    ops = Counter(op for e in entries for op in e["operators"])
    codes = {kind: Counter(c["code"] for e in entries for c in e[kind]) for kind in ("approximated", "unsupported", "notApplied")}
    return {
        "presets": len(entries),
        "operators": {op: ops[op] for op in convert.ALL_OPERATORS},
        "approximated": dict(sorted(codes["approximated"].items())),
        "unsupported": dict(sorted(codes["unsupported"].items())),
        "notApplied": dict(sorted(codes["notApplied"].items())),
        "presetsWithUnsupported": sum(1 for e in entries if e["unsupported"]),
        "completeness": dict(sorted(Counter(e["completeness"] for e in entries).items())),
        "effects": {"grain": sum(e["effects"]["grain"] for e in entries), "vignette": sum(e["effects"]["vignette"] for e in entries)},
        "validationStatus": dict(Counter(e["validation"]["status"] for e in entries)),
        "globalOverrides": sum(1 for e in entries if e["globalOverride"]),
        "grayscale": sum(1 for e in entries if "grayscale" in e["operators"]),
        "processVersions": dict(sorted(Counter(e["processVersion"] for e in entries).items())),
    }


def build(presets_dir: Path = DEFAULT_PRESETS, out: Path = DEFAULT_OUT, validation_report: Path | None = None,
          hald_dir: Path | None = None, contract_path: Path = rm.RENDERING_CONTRACT, log=print) -> dict:
    ui, bindings, catalogue_hashes = load_catalogue(presets_dir)
    contract = json.loads(Path(contract_path).read_text())
    model = contract["developModel"]
    report = json.loads(validation_report.read_text()) if validation_report else None
    report_name = validation_report.name if validation_report else None
    oracle = ModelOracle(model)
    staging = out.with_name(out.name + ".partial")
    if staging.exists():
        shutil.rmtree(staging)
    (staging / "luts").mkdir(parents=True)

    categories, entries, worst, unconverted = [], [], 0.0, {}
    for category in ui["categories"]:
        presets = []
        for ui_preset in category["presets"]:
            entry = convert_preset(ui_preset, bindings[ui_preset["id"]], presets_dir, model, oracle,
                                   report, report_name, hald_dir, staging)
            worst = max(worst, entry.pop("_verifyMaxAbs"))
            verbatim = entry.pop("_unconverted")
            if verbatim:
                unconverted[entry["id"]] = verbatim
            presets.append(entry)
            entries.append(entry)
        categories.append({"id": category["id"], "name": category["name"], "presets": presets})
        log(f"{category['name']:14s} {len(presets):4d} presets")

    manifest = {
        "format": FORMAT,
        "formatVersion": FORMAT_VERSION,
        "status": PACK_STATUS,
        "generator": GENERATOR,
        "catalogue": {**catalogue_hashes, "schemaVersion": ui["schemaVersion"], "orderRule": ui["orderRule"]},
        "baseStop": ui["baseStop"],
        "recipeVersion": convert.RECIPE_VERSION,
        "renderingContract": {"version": contract["version"], "file": "shared/contracts/rendering-v2.json"},
        "developModel": {"id": model["id"], "version": model["version"], "constantsSha256": model["constantsSha256"]},
        "operatorOrder": {"global": list(convert.GLOBAL_OPERATORS), "spatial": list(convert.SPATIAL_OPERATORS),
                          "finishing": list(convert.FINISHING_OPERATORS)},
        "coverageCodes": {code: {"kind": kind, "reason": reason, **({"assumption": True} if code in convert.ASSUMPTION_CODES else {})}
                          for code, (kind, reason) in sorted(convert.COVERAGE_CODES.items())},
        "verification": {"maxAbsVsLrModel": worst, "tolerance": RECIPE_VERIFY_TOLERANCE,
                         "probes": f"{len(PROBES)} RGB values (9³ grid + 256 seeded random)"},
        "summary": summarise(entries),
        "categories": categories,
    }
    (staging / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, separators=(",", ":")) + "\n")
    (staging / "unconverted.json").write_text(json.dumps(
        {"format": "lightly-look-pack-unconverted", "formatVersion": 1, "catalogue": catalogue_hashes,
         "note": "verbatim source properties that the recipe does not convert (unsupported and notApplied records, "
                 "ISO-adaptive data); keyed by preset id", "presets": unconverted},
        ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n")
    if out.exists():
        shutil.rmtree(out)  # fully derived: never mix presets from two builds
    staging.rename(out)
    return manifest


def directory_size(path: Path) -> int:
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--presets-dir", type=Path, default=DEFAULT_PRESETS)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--validation-report", type=Path, default=None,
                        help="ingest_kit's <kit>/results/report.json; without it every validation is not-run")
    parser.add_argument("--hald-dir", type=Path, default=None, help="<kit>/exports/hald (Lightroom global-only HALD exports)")
    args = parser.parse_args()
    manifest = build(args.presets_dir, args.out, args.validation_report, args.hald_dir)
    print(json.dumps(manifest["summary"], indent=1))
    print(f"recipe vs lr_model max |Δ| {manifest['verification']['maxAbsVsLrModel']:.2e}")
    print(f"wrote {args.out} ({directory_size(args.out) / 1e6:.2f} MB)")


if __name__ == "__main__":
    main()
