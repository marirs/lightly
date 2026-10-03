"""Lightroom export kit for the preset pack v2 validation sample (inputs only; nothing is run in Lightroom here).

    python make_kit_v2.py [--new-version]     -> experiments/presets/lr_kit/kit-v2/ (git-ignored)

Same kit layout, presets, HALD identity, photos and README as make_kit.py (whose functions it reuses), but:
- the Looks are the pack v2 parity presets (shared/fixtures/look-pack/manifest-parity.json), read from
  presets/library through the fixed design catalogue instead of the old 18-Look shortlist;
- the kit's look id IS the pack preset id (look-…), so ingest_kit's report.json keys are exactly the ids
  build_pack.py --validation-report looks up, with no mapping table;
- presets with local masks or a creative-profile stub are left out (and listed in sample.json with the
  reason): the generated kit presets cannot carry those nested structures, so Lightroom would render
  something other than the original and the comparison could not mean anything. Other incomplete presets
  stay in: their global colour can be validated, and ingest_kit fails their full recipe for what is missing.

make_kit.py and its tests are unchanged; this module only adds a second entry point.
"""
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))

import lrsettings  # noqa: E402
import make_kit  # noqa: E402

KIT_V2 = HERE / "kit-v2"
PARITY = REPO / "shared/fixtures/look-pack/manifest-parity.json"
CATALOGUE = REPO / "presets/develop-design-catalogue.json"
LIBRARY_ROOT = REPO / "presets"
# settings_to_xmp writes these itself (or drops them); they are not develop values.
IDENTITY_KEYS = {"Name", "UUID", "Group", "PresetType", "Cluster", "SupportsAmount", "SupportsColor", "SupportsMonochrome",
                 "SupportsHighDynamicRange", "SupportsNormalDynamicRange", "SupportsSceneReferred", "SupportsOutputReferred"}


# Unsupported features stored as nested XMP structures, which make_kit.settings_to_xmp cannot write.
NESTED_CODES = {"local-adjustments", "creative-profile"}


def sample(parity_path: Path = PARITY) -> tuple[list[dict], list[dict]]:
    """(included, excluded) parity presets, in catalogue order."""
    parity = json.loads(parity_path.read_text())
    included, excluded = [], []
    for category in parity["categories"]:
        for preset in category["presets"]:
            record = {"look_id": preset["id"], "category": category["id"], "stop": preset["stop"], "name": preset["displayName"],
                      "completeness": preset["completeness"], "lookVersion": preset["lookVersion"]}
            nested = sorted({u["code"] for u in preset["unsupported"]} & NESTED_CODES)
            if nested:
                excluded.append({**record, "reason": "kit preset cannot carry nested " + ", ".join(nested)})
            else:
                included.append(record)
    return included, excluded


def main(new_version: bool = False) -> Path:
    kit = make_kit.prepare_kit_dir(KIT_V2, new_version)
    bindings = {p["id"]: p for c in json.loads(CATALOGUE.read_text())["categories"] for p in c["presets"]}
    looks, excluded = sample()
    for d in ("identity", "photos", "presets/original", "presets/full", "presets/global", "presets/nograin", "exports/hald", "exports/photos"):
        (kit / d).mkdir(parents=True, exist_ok=True)
    make_kit.write_hald(kit / "identity/hald_64_srgb16.tif")
    for jpg in sorted((REPO / "experiments/lut3d/photos").glob("*.jpg")):
        shutil.copy2(jpg, kit / "photos" / jpg.name)
    make_kit.write_fixtures(kit / "photos")
    entries = []
    for look in looks:
        lid = look["look_id"]
        binding = bindings[lid]
        data = (LIBRARY_ROOT / binding["sourceFile"]).read_bytes()
        parsed = lrsettings.parse_bytes(data, binding["sourceFile"], ".xmp")
        original = kit / "presets/original" / f"{lid}.xmp"
        original.write_bytes(data)  # ingest_kit's recipe digest is taken from this exact file
        variants = ("full", "global") + (("nograin",) if make_kit.needs_nograin(parsed.settings) else ())
        for variant in variants:
            settings = make_kit.kit_preset_settings(parsed.settings, variant)
            path = kit / "presets" / variant / f"{lid}__{variant}.xmp"
            path.write_text(make_kit.settings_to_xmp(settings, f"{lid} [{variant}]"))
            # Round trip, as make_kit does: what Lightroom imports must parse back to the same develop values.
            back = lrsettings.parse_xmp_text(path.read_text())
            mismatched = [k for k, v in settings.items() if isinstance(v, (str, list)) and k not in IDENTITY_KEYS and back.get(k) != v]
            if mismatched:
                raise RuntimeError(f"{lid} [{variant}] does not round-trip: {mismatched[:5]}")
        entries.append({"look_id": lid, "category": look["category"], "stop": look["stop"], "name": look["name"],
                        "source": binding["sourceFile"], "original_file": str(original.relative_to(kit)),
                        "full_xmp": f"presets/full/{lid}__full.xmp", "global_xmp": f"presets/global/{lid}__global.xmp",
                        **({"nograin_xmp": f"presets/nograin/{lid}__nograin.xmp"} if "nograin" in variants else {}),
                        "zeroed_for_global": sorted(k for k in make_kit.LOCAL_KEYS if k in parsed.settings
                                                    and str(parsed.settings[k]).strip("+") not in ("0", "0.00"))})
    json.dump(entries, open(kit / "shortlist.json", "w"), indent=1)
    json.dump({"source": str(PARITY.relative_to(REPO)), "included": looks, "excluded": excluded}, open(kit / "sample.json", "w"), indent=1)
    make_kit.write_inputs(kit)
    n_inputs = len(list((kit / "photos").glob("*.jpg")))
    readme = (HERE / "README_TEMPLATE.md").read_text().replace("{{N}}", str(n_inputs)).replace("{{LOOK_TABLE}}", "\n".join(
        f"| `{e['look_id']}` | {e['category']} | {e['stop']} | {e['name']} | `{e['original_file']}` |" for e in entries))
    (kit / "README.md").write_text("> **Preset pack v2 validation kit** (make_kit_v2.py): the Looks are pack preset ids; "
                                   "see sample.json for the presets left out and why.\n\n" + readme)
    manifest = {str(f.relative_to(kit)): make_kit.sha(f) for f in sorted(kit.rglob("*")) if f.is_file()}
    json.dump(manifest, open(kit / "manifest.json", "w"), indent=1)
    print(f"kit-v2: {len(entries)} looks ({len(excluded)} excluded), {n_inputs} inputs, {len(manifest)} files -> {kit}")
    return kit


if __name__ == "__main__":
    main(new_version="--new-version" in sys.argv)
