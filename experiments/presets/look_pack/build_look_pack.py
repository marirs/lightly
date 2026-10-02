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

Every Look is `validation: "unvalidated"` until ingest_kit reports it validated; this script does
not run that comparison. Category labels are copied from the catalog with their provisional status.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

import pack_common as pc

CATALOG = pc.HERE / "catalog.json"
DEFAULT_OUT = pc.HERE / "out"
FORMAT = "lightly-look-pack"
FORMAT_VERSION = 1


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


def build(collection: Path, out: Path, hald_dir: Path | None = None, catalog_path: Path = CATALOG,
          kit_ids: dict[str, str] | None = None) -> dict:
    """kit_ids maps a preset source to its export-kit ID (defaults to the shortlist's); tests inject it."""
    catalog = json.loads(catalog_path.read_text())
    kit_ids = kit_ids_by_source() if kit_ids is None else kit_ids
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
                "validation": "unvalidated",
                **_coverage_fields(parsed.settings, lut_source),
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
    args = parser.parse_args()
    manifest = build(args.collection, args.out, args.hald_dir)
    for category in manifest["categories"]:
        sources = {s["lutSource"] for s in category["stops"]}
        print(f"{category['label']:8s} {len(category['stops'])} stops  {', '.join(sorted(sources))}")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
