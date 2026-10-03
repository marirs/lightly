"""Nominate PH-1 review candidates from PD12M Commons CC0 rows (eval shards 000-011 only; training uses other
shards), keep unedited phone captures (camera fallback for portrait/backlit), download them and render local
review thumbnails.

  python -m data_tools.pd12m_eval_candidates
  python -m data_tools.pd12m_eval_candidates --pass2 portrait|backlit   # appends stricter-pattern candidates

Output: data/pd12m/eval_candidates.json (row + header EXIF + nominated classes), originals under
data/pd12m/eval_originals/, review thumbnails under data/commons/thumbs/<id>.jpg.
"""
from __future__ import annotations

import json
import os
import random
import re
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

from PIL import Image, ImageOps

from data_tools.commons import EDIT_SOFTWARE, phone_brand
from data_tools.pd12m import NOMINATION_PATTERNS, NOT_A_PHOTO, PD12M_DIR, S3_WORKERS, _session, download_verified, headers_for, load_rows

AUTO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EVAL_SHARDS = list(range(0, 12))
HEADER_SAMPLE = {"portrait": 4000, "landscape": 1500, "indoor_mixed": 2000, "night": 2206, "sunset": 1041, "backlit": 905}
DOWNLOAD_CAP = {"portrait": 160, "backlit": 140, "night": 140, "sunset": 110, "landscape": 80, "indoor_mixed": 110}
CAMERA_FALLBACK = {"portrait", "backlit"}
THUMB_DIR = os.path.join(AUTO_ROOT, "data", "commons", "thumbs")
# Second pass for portraits: the broad pattern yielded ~15 real portraits in 160 phone downloads, because
# captions mention people in street scenes. This stricter pattern targets people posing / facing the camera.
BACKLIT_STRICT = (r"\bsilhouett|\bbacklit\b|\bsun (?:is )?(?:shining|setting|rising|peeking) (?:behind|through)\b|"
                  r"\bsunlight (?:is )?(?:streaming|shining|filtering) through\b|\bagainst (?:a|the) (?:bright|setting|evening) sky\b|"
                  r"\bsun (?:is )?(?:visible )?in the background\b|\bthrough the window\b")
PORTRAIT_STRICT = (r"\bposing\b|\blooking (?:at|into) the camera\b|\bselfie\b|\bportrait of (?:a|an|the) "
                   r"(?:young |old |smiling |middle-aged )?(?:woman|man|girl|boy|person|child|couple)\b|"
                   r"\bsmiling (?:woman|man|girl|boy|person)\b|\b(?:woman|man|girl|boy) (?:is )?smiling\b")


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--pass2", choices=["portrait", "backlit"], help="append strict-pattern candidates for one class")
    args = parser.parse_args(argv)
    out_path = os.path.join(PD12M_DIR, "eval_candidates.json")
    previous = json.load(open(out_path)) if args.pass2 else []
    previous_ids = {e["id"] for e in previous}
    rows = [r for r in load_rows(EVAL_SHARDS, ("Wikimedia Commons",))
            if not NOT_A_PHOTO.search(r["caption"] or "") and min(r["width"], r["height"]) >= 1000
            and r["id"] not in previous_ids]
    rng = random.Random(20261003)
    nominated: dict[str, list[dict]] = {}
    strict = {"portrait": PORTRAIT_STRICT, "backlit": BACKLIT_STRICT}
    patterns = {args.pass2: strict[args.pass2]} if args.pass2 else NOMINATION_PATTERNS
    if args.pass2:
        HEADER_SAMPLE[args.pass2], DOWNLOAD_CAP[args.pass2] = 100000, 400
    for rubric_class, pattern in patterns.items():
        matches = [r for r in rows if re.search(pattern, r["caption"] or "", re.I)]
        matches.sort(key=lambda r: r["id"])
        rng.shuffle(matches)
        nominated[rubric_class] = matches[:HEADER_SAMPLE[rubric_class]]
    unique = {r["id"]: r for rs in nominated.values() for r in rs}
    print("header fetch for", len(unique), flush=True)
    ids = sorted(unique)
    exifs = headers_for([unique[i] for i in ids])
    for row_id, exif in zip(ids, exifs):
        unique[row_id]["exif"] = exif
    candidates, reasons = {}, Counter()
    for rubric_class, rs in nominated.items():
        kept = []
        for row in rs:
            exif = row["exif"]
            if exif.get("error"):
                reasons["no-header"] += 1
                continue
            if EDIT_SOFTWARE.search(exif.get("software", "")):
                reasons["edited"] += 1
                continue
            brand = phone_brand(exif.get("make", ""), exif.get("model", ""))
            if brand is None and not (rubric_class in CAMERA_FALLBACK and exif.get("make")):
                reasons["not-phone"] += 1
                continue
            kept.append((brand is None, row["id"]))
        kept.sort()
        for is_camera, row_id in kept[:DOWNLOAD_CAP[rubric_class]]:
            entry = candidates.setdefault(row_id, {**unique[row_id], "is_phone": not is_camera, "nominated_classes": []})
            entry["nominated_classes"].append(rubric_class)
    print("reasons", dict(reasons), flush=True)
    print("to download", len(candidates), Counter(c for e in candidates.values() for c in e["nominated_classes"]), flush=True)
    session = _session()
    os.makedirs(THUMB_DIR, exist_ok=True)

    def fetch(entry):
        path = os.path.join(PD12M_DIR, "eval_originals", entry["id"] + ".jpg")
        try:
            entry["sha1"] = download_verified(entry, path, session)
            thumb = os.path.join(THUMB_DIR, entry["id"] + ".jpg")
            if not os.path.exists(thumb):
                image = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
                image.thumbnail((330, 330))
                image.save(thumb, quality=85)
        except Exception as error:  # noqa: BLE001 - a failed file just drops out of review
            entry["error"] = repr(error)[:200]
        return entry

    with ThreadPoolExecutor(max_workers=S3_WORKERS) as pool:
        done = list(pool.map(fetch, candidates.values()))
    good = previous + [e for e in done if "sha1" in e]
    json.dump(good, open(out_path, "w"), indent=1)
    print("downloaded", len(good), "failed", len(done) - len(good))


if __name__ == "__main__":
    main()
