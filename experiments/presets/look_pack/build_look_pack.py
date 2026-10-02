"""Build the Look pack both apps load (git-ignored output).

    python build_look_pack.py [--collection DIR] [--hald-dir KIT/exports/hald] [--out DIR]

Input: `catalog.json` (committed) and the preset collection. Output (default `out/`):

    manifest.json        categories → ordered stops, per-Look provenance and status
    luts/<lookId>.f32    33³ interleaved RGBA float32, red fastest (same encoding as the golden set)

LUT source per Look, best first:
1. `lightroom-hald`: Lightroom's own render of the Look's global-only preset on the identity HALD
   (export kit, `<kitLookId>__global.tif`). Pixel-exact for the global part; spatial operators
   are still omitted.
2. `lr-model-approximation`: the calibrated Lightroom approximation (held-out median ΔE00 4.8).
   It is a stand-in until the Lightroom exports exist and is labelled as such in the manifest.

Status (format 2). Two validations are tracked separately and never merged into one flag:
- `globalColour`: Lightroom's global-only render vs the Look's LUT (ingest_kit "global").
- `fullRecipe`:   Lightroom's full Look vs Lightly's complete recipe (ingest_kit "full").
Each is {status: not-run | incomplete | failed | validated | stale, evidence: report file name or null},
where `stale` means the report measured a different LUT, preset recipe or (full recipe) renderer
than the one shipped: evidence digests (experiments/presets/evidence.py) must match exactly.
read from `--validation-report <kit>/results/report.json`; this script never runs the comparison.
`conversion` is "complete" only when the LUT is Lightroom's own and no operator is omitted;
approximate colour, or colour with missing effects, is "approximate". The Look's `status` is
promoted only by evidence that applies to the shipped LUT (see promoted_status). Category labels are copied from the catalog with their provisional status.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

import pack_common as pc  # first: puts experiments/presets (evidence, lr_model) on sys.path
import evidence  # noqa: E402

CATALOG = pc.HERE / "catalog.json"
DEFAULT_OUT = pc.HERE / "out"
FORMAT = "lightly-look-pack"
FORMAT_VERSION = 2  # 2: globalColour / fullRecipe / conversion / status replace `validation`


def kit_look_id(category_key: str, stop: int, name: str) -> str:
    """The export kit's ID for a shortlist entry (make_kit.look_id), used only to find its HALD export."""
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:32]
    return f"{category_key}.{stop}.{slug}"


def kit_ids_by_source() -> dict[str, str]:
    shortlist = json.loads((pc.PRESETS / "shortlist.json").read_text())
    return {rec["source"]: kit_look_id(rec["category"], rec["stop"], rec["name"])
            for category in shortlist.values() for rec in category["looks"]}


def look_lut(stop: dict, settings: dict, hald_dir: Path | None, kit_ids: dict[str, str]):
    kit_id = kit_ids.get(stop["source"])
    if hald_dir is not None and kit_id is not None:
        hald = hald_dir / f"{kit_id}__global.tif"
        if hald.exists():
            import ingest_kit  # noqa: PLC0415 (lr_kit is only needed when HALD exports exist)
            return ingest_kit.hald_to_lut(hald), "lightroom-hald", hald.name
    return pc.lr_model_lut(settings), "lr-model-approximation", None


def _coverage_fields(settings: dict, lut_source: str) -> dict:
    coverage = pc.operator_coverage(settings, lut_source)
    return {"omittedOperators": coverage["omitted"], "approximatedGlobally": coverage["approximatedGlobally"]}


NOT_RUN = {"status": "not-run", "evidence": None}


def _validation(report: dict | None, report_name: str | None, kit_id: str | None, kind: str,
                shipped: dict) -> dict:
    """One validation's status for the LUT being shipped.

    A passing result counts only when the report's evidence block names exactly what ships: the same
    LUT bytes and the same original preset recipe, and for the full recipe also the same renderer.
    Anything else is "stale" with the reason, so an edited preset, a re-exported HALD or a changed
    renderer can never inherit an old pass (Codex review of d5690dd, finding 1).
    """
    look = (report or {}).get("looks", {}).get(kit_id or "", {})
    entry = look.get(kind)
    if not entry:
        return dict(NOT_RUN)
    result = {"status": entry["status"], "evidence": report_name}
    mismatch = _evidence_mismatch(look.get("evidence"), shipped, kind)
    if mismatch:
        result["status"] = "stale"
        result["reason"] = mismatch
        result["reportedStatus"] = entry["status"]
    return result


def _evidence_mismatch(recorded: dict | None, shipped: dict, kind: str) -> str | None:
    if not recorded:
        return "report not bound to a LUT or recipe (no evidence digests); re-run ingest_kit"
    keys = ("lutSha256", "recipeSha256") + (("rendererSha256",) if kind == "full" else ())
    differing = [k for k in keys if recorded.get(k) != shipped[k]]
    if differing:
        return "measured a different " + ", ".join(k.removesuffix("Sha256") for k in differing) + " than the one shipped"
    return None


def promoted_status(lut_source: str, omitted: list[str], global_colour: str, full_recipe: str) -> str:
    """The Look's overall status; promotion needs evidence about the LUT that actually ships.

    - validated: Lightroom's own LUT, nothing omitted, and BOTH validations passed.
    - global-colour-validated: Lightroom's own LUT and the global comparison passed. Effects may
      still be missing or the full recipe may differ; the colour transform itself is confirmed.
    - approximate: anything else, including any model-derived LUT whatever a report says, because
      the report measured Lightroom's HALD, not the model's output.
    """
    if lut_source != "lightroom-hald" or global_colour != "validated":
        return "approximate"
    if full_recipe == "validated" and not omitted:
        return "validated"
    return "global-colour-validated"


def _status_fields(kit_id, lut_source: str, settings: dict, report, report_name, lut_bytes: bytes) -> dict:
    shipped = evidence.evidence_block(lut_bytes, settings)
    global_colour = _validation(report, report_name, kit_id, "global", shipped)
    full_recipe = _validation(report, report_name, kit_id, "full", shipped)
    omitted = pc.operator_coverage(settings, lut_source)["omitted"]
    return {
        "conversion": "complete" if lut_source == "lightroom-hald" and not omitted else "approximate",
        "globalColour": global_colour,
        "fullRecipe": full_recipe,
        "status": promoted_status(lut_source, omitted, global_colour["status"], full_recipe["status"]),
    }


def build(collection: Path, out: Path, hald_dir: Path | None = None, catalog_path: Path = CATALOG,
          kit_ids: dict[str, str] | None = None, validation_report: Path | None = None) -> dict:
    """kit_ids maps a preset source to its export-kit ID (defaults to the shortlist's); tests inject it."""
    catalog = json.loads(catalog_path.read_text())
    kit_ids = kit_ids_by_source() if kit_ids is None else kit_ids
    report = json.loads(validation_report.read_text()) if validation_report else None
    report_name = validation_report.name if validation_report else None
    if out.exists():
        shutil.rmtree(out)  # the output is fully derived; never mix Looks from two catalog versions
    (out / "luts").mkdir(parents=True)

    categories = []
    for category in catalog["categories"]:
        stops = []
        for stop in category["stops"]:
            parsed = pc.read_preset(collection, stop["source"])
            lut, lut_source, hald_name = look_lut(stop, parsed.settings, hald_dir, kit_ids)
            data = pc.lut_bytes(lut)
            lut_file = f"luts/{stop['lookId']}.f32"
            (out / lut_file).write_bytes(data)
            digest = hashlib.sha256(data).hexdigest()
            stops.append({
                "lookId": stop["lookId"],
                # Changes whenever the LUT changes, so a saved edit can tell it is replaying different pixels.
                "lookVersion": digest[:12],
                "name": stop["name"],
                "lutFile": lut_file,
                "lutSha256": digest,
                "lutSource": lut_source,
                "lightroomHald": hald_name,
                **_coverage_fields(parsed.settings, lut_source),
                **_status_fields(kit_ids.get(stop["source"]), lut_source, parsed.settings, report, report_name, data),
            })
        categories.append({
            "id": category["id"],
            "label": category["label"],
            "labelStatus": category.get("labelStatus", "provisional"),
            "stops": stops,
        })

    manifest = {
        "format": FORMAT,
        "formatVersion": FORMAT_VERSION,
        "catalogVersion": catalog["catalogVersion"],
        "lutDimension": pc.LUT_DIMENSION,
        "lutEncoding": "rgba-float32-red-fastest",
        "categories": categories,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--collection", type=Path, default=pc.DEFAULT_COLLECTION)
    parser.add_argument("--hald-dir", type=Path, default=None)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--validation-report", type=Path, default=None,
                        help="ingest_kit's <kit>/results/report.json; without it every validation is not-run")
    args = parser.parse_args()
    manifest = build(args.collection, args.out, args.hald_dir, validation_report=args.validation_report)
    for category in manifest["categories"]:
        statuses = sorted({s["status"] for s in category["stops"]})
        print(f"{category['label']:8s} {len(category['stops'])} stops  status: {', '.join(statuses)}")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
