"""Build the Look catalog (committed) from the curated preset shortlist.

    python build_catalog.py [--collection DIR]

Reads `../shortlist.json` (presets chosen from the curated collection, docs/m1/shortlist.md) and
writes `catalog.json`:

- categories: an ordered list. Each has an opaque `id` and a display `label`. Labels are
  provisional ("Natural", "Warm", ...): renaming, merging or splitting a category is a catalog
  edit, and neither app hard-codes any category.
- stops: each category's presets in browse order (see ordering.py), with the measured step sizes
  and the reason for the order. `orderOverride` in an existing catalog is kept: a human-chosen
  order wins over the computed one and is marked as such.

The catalog names presets by their source path in the collection; the pack builder resolves them.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image
from skimage import color

import pack_common as pc
from ordering import NEAR_DUPLICATE_STEP_DE, shortest_browse_path

CATALOG = pc.HERE / "catalog.json"
SHORTLIST = pc.PRESETS / "shortlist.json"
GOLDEN = pc.PRESETS.parent / "lut3d/golden"
# The shortlist's own measurement photos: three skin tones, sunset, landscape, night, well exposed.
REFERENCE_STEMS = ["portrait_deep_01", "portrait_light_01", "portrait_medium_01", "sunset_02", "landscape_03", "night_01", "wellexposed_02"]
REFERENCE_LONG_EDGE = 256

# Provisional labels and category order, keyed by the shortlist's category keys. The order puts the
# least transformative category first; it is a catalog value, editable like the labels.
PROVISIONAL_CATEGORIES = [("natural", "Natural"), ("warm", "Warm"), ("cool", "Cool"), ("film", "Film"), ("mono", "Mono")]


def reference_photos() -> list[np.ndarray]:
    photos = []
    for stem in REFERENCE_STEMS:
        image = Image.open(GOLDEN / stem / "source.png").convert("RGB")
        scale = REFERENCE_LONG_EDGE / max(image.size)
        image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
        photos.append(np.asarray(image, dtype=np.float32) / 255.0)
    return photos


def mean_de(renders_a: list[np.ndarray], renders_b: list[np.ndarray]) -> float:
    per_photo = [color.deltaE_ciede2000(color.rgb2lab(a), color.rgb2lab(b)).mean() for a, b in zip(renders_a, renders_b)]
    return float(np.mean(per_photo))


def order_category(looks: list[dict], photos: list[np.ndarray]) -> dict:
    renders = [[pc.apply_lut(look["lut"], p) for p in photos] for look in looks]
    from_auto = [mean_de(photos, r) for r in renders]
    pairwise = [[0.0 if i == j else mean_de(renders[i], renders[j]) for j in range(len(looks))] for i in range(len(looks))]
    names = [look["name"] for look in looks]
    path = shortest_browse_path(from_auto, pairwise, names)
    return {"path": path, "from_auto": from_auto}


def existing_overrides() -> dict:
    if not CATALOG.exists():
        return {}
    previous = json.loads(CATALOG.read_text())
    return {c["id"]: c["orderOverride"] for c in previous.get("categories", []) if c.get("orderOverride")}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--collection", type=Path, default=pc.DEFAULT_COLLECTION)
    args = parser.parse_args()

    shortlist = json.loads(SHORTLIST.read_text())
    overrides = existing_overrides()
    photos = reference_photos()
    categories = []
    for key, label in PROVISIONAL_CATEGORIES:
        looks = []
        for rec in shortlist[key]["looks"]:
            parsed = pc.read_preset(args.collection, rec["source"])
            looks.append({
                "lookId": pc.stable_look_id(rec["name"], rec["source"]),
                "name": pc.display_name(rec["name"]),
                "source": rec["source"],
                "lut": pc.lr_model_lut(parsed.settings),
            })
        measured = order_category(looks, photos)
        path = measured["path"]
        computed = [looks[i]["lookId"] for i in path.order]
        category_id = f"cat-{key}"
        override = overrides.get(category_id)
        if override and sorted(override) != sorted(computed):
            raise SystemExit(f"{category_id}: orderOverride does not list exactly the category's presets")
        ordered_ids = override or computed
        by_id = {look["lookId"]: look for look in looks}
        stops = []
        previous_lut = None
        for position, look_id in enumerate(ordered_ids):
            look = by_id[look_id]
            step = mean_de(photos if previous_lut is None else [pc.apply_lut(previous_lut, p) for p in photos],
                           [pc.apply_lut(look["lut"], p) for p in photos])
            stops.append({
                "lookId": look_id,
                "name": look["name"],
                "source": look["source"],
                "stepFromPreviousDE": round(step, 2),
                "nearDuplicateOfPrevious": step < NEAR_DUPLICATE_STEP_DE,
            })
            previous_lut = look["lut"]
        categories.append({
            "id": category_id,
            "label": label,
            "labelStatus": "provisional",
            "orderMethod": "override" if override else "shortest-visual-path-from-auto",
            "orderOverride": override,
            "totalPathDE": round(sum(s["stepFromPreviousDE"] for s in stops), 2),
            "stops": stops,
        })
        print(f"{label:8s} " + " -> ".join(f"{s['name']} ({s['stepFromPreviousDE']})" for s in stops))

    catalog = {
        "catalogVersion": 1,
        "description": (
            "Lightly Look catalog. Categories are provisional groupings of the curated presets; labels and "
            "membership are data, not code. Within a category the slider shows the base stop ("Auto" when an Auto correction is applied, "Original" otherwise), then each preset as a "
            "discrete stop in browse order: the shortest visual path from Auto through every preset "
            "(mean CIEDE2000 on the reference photos), not an intensity ramp."
        ),
        "referencePhotos": REFERENCE_STEMS,
        "nearDuplicateStepDE": NEAR_DUPLICATE_STEP_DE,
        "categories": categories,
    }
    CATALOG.write_text(json.dumps(catalog, indent=1, ensure_ascii=False) + "\n")
    print(f"wrote {CATALOG}")


if __name__ == "__main__":
    main()
