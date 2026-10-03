"""Fetch the evaluation review pool as ORIGINAL files (one request per image), and render local review
thumbnails from them.

Why originals and not Commons thumbnails: upload.wikimedia.org admits roughly 7-8 requests/minute from an
unauthenticated client (measured: every second request at a 4 s pace drew HTTP 429). Fetching the original
once serves both the contact-sheet review and, for selected images, the PH-1 proxy, so nothing is requested
twice.

  python -m data_tools.fetch_review_pool
"""
from __future__ import annotations

import json
import os

from PIL import Image, ImageOps

from data_tools.commons import download

AUTO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ORIGINALS_DIR = os.path.join(AUTO_ROOT, "data", "commons", "originals")
THUMB_DIR = os.path.join(AUTO_ROOT, "data", "commons", "thumbs")
# Review pool per nominated class: phones first, then camera fallbacks (backlit, portrait only), sha1 order.
POOL = {"backlit": (193, False), "portrait": (160, False), "night": (127, True), "sunset": (100, True),
        "landscape": (80, True), "indoor_mixed": (100, True)}


def original_path(record: dict) -> str:
    return os.path.join(ORIGINALS_DIR, record["sha1"] + os.path.splitext(record["url"])[1].lower())


def pool_records(candidates: list[dict]) -> list[dict]:
    chosen, seen = [], set()
    for nominated, (size, phones_only) in POOL.items():
        records = [r for r in candidates if nominated in r["nominated_classes"] and (r["is_phone"] or not phones_only)]
        records.sort(key=lambda r: (not r["is_phone"], r["sha1"]))
        for record in records[:size]:
            if record["sha1"] not in seen:
                seen.add(record["sha1"])
                chosen.append(record)
    return chosen


def main():
    candidates = json.load(open(os.path.join(AUTO_ROOT, "data", "commons", "candidates.json")))
    pool = pool_records(candidates)
    print("pool", len(pool), flush=True)
    os.makedirs(THUMB_DIR, exist_ok=True)
    for index, record in enumerate(pool):
        thumb = os.path.join(THUMB_DIR, record["sha1"] + ".jpg")
        if os.path.exists(thumb):
            continue
        try:
            download(record["url"], original_path(record), record["sha1"])
            image = ImageOps.exif_transpose(Image.open(original_path(record))).convert("RGB")
            image.thumbnail((330, 330))
            image.save(thumb, quality=85)
        except Exception as error:  # noqa: BLE001 - a failed file drops out of review only
            print("failed", record["title"], repr(error)[:200], flush=True)
        if (index + 1) % 25 == 0:
            print(f"[{index + 1}/{len(pool)}]", flush=True)


if __name__ == "__main__":
    main()
