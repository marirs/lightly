#!/usr/bin/env python3
"""Turn the owner's curated preset shortlist into the design catalogue build_pack.py reads (owner, 2026-10-11:
"ship just these 513").

    python shared/look-pack/curate_catalogue.py --shortlist .preset-review/shortlist.json \
        --aurelius-presets "<dir>/Aurelius Preset Collection - 125 Presets" \
        --aurelius-luts "<dir>/Aurelius LUTs Collection - 200 LUTs"

Inputs:
- the review page's shortlist (.preset-review/shortlist.json, not committed): nine collections; per look its kind
  (library, aurelius-preset or lut) and `dupOf` for a near-duplicate, which is left out;
- the review renders (.preset-review/img, originals): measured to order each collection and name new looks;
- the current bindings (presets/develop-design-catalogue.json) for the kept library looks;
- the purchased Aurelius folders, outside the repository.

Outputs:
- presets/library/aurelius/… and presets/library/aurelius-luts/… : copies of the purchased sources (git-ignored, as
  the rest of presets/library, so the purchase never enters the repository);
- presets/develop-design-ui.json (committed) and presets/develop-design-catalogue.json (git-ignored bindings);
- shared/look-pack/names/display-names.json: exactly the shipped looks. Kept library looks keep their names; a new
  look is named from what it measurably does (see `name_for`), in the catalogue's existing words.

Order inside a collection: from the subtlest change to the strongest, measured on the review photos, so the gallery
reads as a progression. A look's id is "look-" + the first 20 hex digits of its source file's SHA-256, as the library.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shutil
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path[:0] = [str(HERE)]
import build_pack  # noqa: E402  (settingsSha256 exactly as the builder checks it)
import lrsettings  # noqa: E402
import reference_model as rm  # noqa: E402

PRESETS = REPO / "presets"
NAMES = HERE / "names/display-names.json"

# The nine collections, in the approved order; ids are what the apps key on (Portrait stays "portrait": the editor
# hides it when no person is found).
COLLECTIONS = {"Essentials": "essentials", "Cinema": "cinema", "Film": "film", "Daylight": "daylight",
               "Golden Hour": "golden-hour", "Night": "night", "Moody": "moody", "Portrait": "portrait",
               "Black & White": "black-white"}

# Naming vocabulary: the words the existing catalogue already uses (names/display-names.json), so new looks read
# like the rest. First word: tone; middle: the tint the look adds; last: the collection's light.
FIRST = {"bright": ["Luminous", "Clear", "Bright"], "dark": ["Deep", "Low", "Dim"],
         "soft": ["Soft", "Quiet", "Still", "Calm", "Subdued"], "punchy": ["Bold", "Pure", "Clear"],
         "even": ["Natural", "Pure", "Gentle"]}
TINTS = [  # OKLab hue of the added tint (degrees, atan2(b, a)) → words
    (20, 70, ["Amber", "Honey", "Saffron", "Ochre", "Copper"]),
    (70, 110, ["Gold", "Wheat", "Brass", "Sand"]),
    (110, 160, ["Sage", "Moss", "Olive"]),
    (160, 220, ["Seafoam", "Jade", "Lagoon"]),
    (220, 260, ["Teal", "Aqua", "Turquoise", "Marine"]),
    (260, 300, ["Cobalt", "Azure", "Glacier", "Steel"]),
    (300, 340, ["Plum", "Lilac", "Orchid"]),
    (340, 380, ["Rose", "Coral", "Clay"]),
]
NEUTRAL = ["Pearl", "Linen", "Stone", "Ivory", "Silk", "Quartz", "Opal"]
MONO = ["Silver", "Slate", "Graphite", "Charcoal", "Ink", "Ash", "Smoke", "Pewter"]
LAST = {"essentials": ["Light", "Calm", "Definition", "Air", "Clarity"],
        "cinema": ["Mood", "Edge", "Depth", "Contrast", "Frame", "Scene"],
        "film": ["Fade", "Matte", "Wash", "Haze", "Print"],
        "daylight": ["Daylight", "Air", "Breeze", "Light", "Sky"],
        "golden-hour": ["Glow", "Dawn", "Dusk", "Sunset", "Hour"],
        "night": ["Night", "Shade", "Neon", "Dusk", "Dark"],
        "moody": ["Mood", "Veil", "Mist", "Shade", "Storm"],
        "portrait": ["Glow", "Silk", "Softness", "Veil", "Light"],
        "black-white": ["Contrast", "Fade", "Matte", "Tone", "Print"]}
TINT_THRESHOLD = 0.006   # OKLab |Δa, Δb| below which a look adds no visible tint


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def oklab(path: Path) -> np.ndarray:
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0
    return rm.linear_to_oklab(rm.srgb_to_linear(rgb)).reshape(-1, 3)


def measure(review: Path, review_id: str) -> dict:
    """Over the six review photos: how much the look changes them, and in which direction (OKLab)."""
    change, d_l, contrast, tint = [], [], [], []
    for i in range(6):
        before, after = oklab(review / "originals" / f"{i}.jpg"), oklab(review / "img" / f"{review_id}_{i}.jpg")
        if before.shape != after.shape:
            raise SystemExit(f"{review_id}: review render {i} does not match the original's size")
        change.append(np.abs(after - before).mean())
        d_l.append(after[:, 0].mean() - before[:, 0].mean())
        contrast.append(after[:, 0].std() / max(before[:, 0].std(), 1e-6))
        tint.append(after[:, 1:].mean(0) - before[:, 1:].mean(0))
    da, db = np.mean(tint, 0)
    return {"change": float(np.mean(change)), "dL": float(np.mean(d_l)), "contrast": float(np.mean(contrast)),
            "tint": float(math.hypot(da, db)), "hue": float(math.degrees(math.atan2(db, da)) % 360)}


def name_for(look_id: str, collection_id: str, m: dict, taken: set[str]) -> str:
    """[tone] [tint] [light]: deterministic per id (its hash picks among the fitting words), unique, no digits."""
    if m["dL"] > 0.03:
        tone = "bright"
    elif m["dL"] < -0.04:
        tone = "dark"
    elif m["contrast"] < 0.92:
        tone = "soft"
    elif m["contrast"] > 1.12:
        tone = "punchy"
    else:
        tone = "even"
    if collection_id == "black-white":
        middles = MONO
    elif m["tint"] < TINT_THRESHOLD:
        middles = NEUTRAL
    else:
        hue = m["hue"] if m["hue"] >= 20 else m["hue"] + 360
        middles = next(words for low, high, words in TINTS if low <= hue < high)
    seed = int(look_id[5:13], 16)
    firsts, lasts = FIRST[tone], LAST[collection_id]
    candidates = []
    for k in range(len(firsts) * len(middles) * len(lasts)):
        first = firsts[(seed + k) % len(firsts)]
        middle = middles[(seed // 7 + k // len(firsts)) % len(middles)]
        last = lasts[(seed // 13 + k // (len(firsts) * len(middles))) % len(lasts)]
        candidates.append(f"{first} {middle} {last}")
    candidates += [f"{m_} {l_}" for m_ in middles for l_ in lasts]
    for name in candidates:
        if len(name) <= 30 and name.casefold() not in taken:
            return name
    raise SystemExit(f"{look_id}: no free name in {collection_id}")


def find_source(item: dict, presets_root: Path, luts_root: Path) -> Path:
    if item["kind"] == "aurelius-preset":
        pack = item["source"].split(" · ")[0]
        matches = [p for p in presets_root.glob(f"{pack}/Desktop*/*.xmp") if p.stem == item["name"]]
    else:
        pack = item["source"].split(" · ")[0]
        matches = [p for p in luts_root.rglob("*.cube") if p.stem == item["name"] and p.parent.name == pack]
    if len(matches) != 1:
        raise SystemExit(f"{item['id']}: expected one source file, found {len(matches)}")
    return matches[0]


def new_binding(item: dict, source: Path, copy_root: str, collection: str) -> tuple[str, dict]:
    data = source.read_bytes()
    asset = sha256(data)
    look_id = "look-" + asset[:20]
    relative = Path("library") / copy_root / source.parent.parent.name / source.name if item["kind"] == "aurelius-preset" \
        else Path("library") / copy_root / source.parent.name / source.name
    target = PRESETS / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    if item["kind"] == "aurelius-preset":
        parsed = lrsettings.parse_bytes(data, str(relative), ".xmp")
        if parsed.error:
            raise SystemExit(f"{source}: {parsed.error}")
        settings_sha, kind = build_pack.catalogue_settings_sha256(parsed.settings), "xmp"
    else:
        settings_sha, kind = asset, "cube"   # a table has no settings; the bytes are its identity
    return look_id, {"id": look_id, "category": collection, "sourceAssetId": asset, "sourceFile": str(relative),
                     "sourceKind": kind, "settingsSha256": settings_sha,
                     "assignmentReason": f"Owner-curated shortlist 2026-10-11 ({item['source'].split(' · ')[0]})",
                     "equivalentAssetIds": [], "renderValidation": "not-validated"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--shortlist", type=Path, default=REPO / ".preset-review/shortlist.json")
    parser.add_argument("--aurelius-presets", type=Path, required=True)
    parser.add_argument("--aurelius-luts", type=Path, required=True)
    args = parser.parse_args()
    review = args.shortlist.parent
    shortlist = json.loads(args.shortlist.read_text())
    old_ui = json.loads((PRESETS / "develop-design-ui.json").read_text())
    old_bindings = {p["id"]: p for c in json.loads((PRESETS / "develop-design-catalogue.json").read_text())["categories"]
                    for p in c["presets"]}
    old_names = json.loads(NAMES.read_text())["names"]

    collections = []  # (collection id, name, [(look id, display name, binding, change)])
    names: dict[str, str] = {}
    pending_new = []
    for collection_name, items in shortlist.items():
        collection_id = COLLECTIONS[collection_name]
        looks = []
        for item in items:
            if item.get("dupOf"):
                continue   # a near-duplicate of another shortlisted look: left out
            item = {**item, "kind": item.get("kind", "library")}
            m = measure(review, item["id"])
            if item["kind"] == "library":
                binding = dict(old_bindings[item["id"]], category=collection_name)
                look_id = item["id"]
                names[look_id] = old_names[look_id]
            else:
                root = "aurelius" if item["kind"] == "aurelius-preset" else "aurelius-luts"
                look_id, binding = new_binding(item, find_source(item, args.aurelius_presets, args.aurelius_luts), root, collection_name)
                pending_new.append((look_id, collection_id, m))
            if any(look_id == other[0] for c in collections for other in c[2]) or any(look_id == o[0] for o in looks):
                raise SystemExit(f"{look_id} is listed twice")
            looks.append((look_id, binding, m["change"]))
        collections.append((collection_id, collection_name, looks))

    taken = {n.casefold() for n in names.values()}
    for look_id, collection_id, m in pending_new:
        names[look_id] = name_for(look_id, collection_id, m, taken)
        taken.add(names[look_id].casefold())

    ui_categories, binding_categories = [], []
    for collection_id, collection_name, looks in collections:
        looks.sort(key=lambda look: (look[2], look[0]))   # subtle → strong; id breaks ties deterministically
        ui_presets, b_presets = [], []
        for stop, (look_id, binding, _) in enumerate(looks, start=1):
            ui_presets.append({"id": look_id, "displayName": names[look_id], "stop": stop})
            b_presets.append({**binding, "displayName": names[look_id], "stop": stop})
        ui_categories.append({"id": collection_id, "name": collection_name, "presets": ui_presets})
        binding_categories.append({"id": collection_id, "name": collection_name, "presets": b_presets})

    header = {"schemaVersion": old_ui["schemaVersion"],
              "purpose": "Owner-curated catalogue (2026-10-11): 513 distinct looks in nine collections",
              "baseStop": old_ui["baseStop"],
              "orderRule": "Within a collection: subtlest to strongest change, measured on the review photos"}
    (PRESETS / "develop-design-ui.json").write_text(json.dumps({**header, "categories": ui_categories}, ensure_ascii=False, indent=1) + "\n")
    (PRESETS / "develop-design-catalogue.json").write_text(json.dumps({**header, "categories": binding_categories}, ensure_ascii=False, indent=1) + "\n")
    NAMES.write_text(json.dumps({"formatVersion": 1, "names": dict(sorted(names.items()))}, ensure_ascii=False, indent=1) + "\n")
    total = sum(len(c[2]) for c in collections)
    print(f"{total} looks: " + ", ".join(f"{c[1]} {len(c[2])}" for c in collections))
    print(f"new looks named: {len(pending_new)}; kept library names: {total - len(pending_new)}")


if __name__ == "__main__":
    main()
