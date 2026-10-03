"""Contact sheets for reviewing candidates by eye (class assignment is a human/reviewer decision, never the
search query). Thumbnails come from Commons' own 330 px renders and are cached under data/commons/thumbs/.

  python -m data_tools.contact_sheet --candidates data/commons/candidates.json --nominated night --out data/commons/sheets/night
"""
from __future__ import annotations

import argparse
import io
import json
import os

from PIL import Image, ImageDraw

from data_tools.commons import _session, polite_get

AUTO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
THUMB_DIR = os.path.join(AUTO_ROOT, "data", "commons", "thumbs")


def thumb_url(original_url: str, width: int = 330) -> str:
    # https://upload.wikimedia.org/wikipedia/commons/a/ab/Name.jpg -> .../commons/thumb/a/ab/Name.jpg/330px-Name.jpg
    prefix, rest = original_url.split("/wikipedia/commons/", 1)
    name = rest.rsplit("/", 1)[1]
    return f"{prefix}/wikipedia/commons/thumb/{rest}/{width}px-{name}"


def record_key(record: dict) -> str:
    """PD12M candidates are keyed by PD12M id, Commons-API candidates by sha1."""
    return record.get("id") or record["sha1"]


def fetch_thumb(record: dict, session, cached_only: bool = False) -> Image.Image | None:
    path = os.path.join(THUMB_DIR, record_key(record) + ".jpg")
    if not os.path.exists(path) and cached_only:
        return None
    if not os.path.exists(path):
        os.makedirs(THUMB_DIR, exist_ok=True)
        try:
            response = polite_get(session, thumb_url(record["url"]), "media")
        except Exception:  # noqa: BLE001 - a missing thumbnail drops the candidate from the sheet only
            return None
        if response.status_code != 200:
            return None
        open(path, "wb").write(response.content)
    try:
        return Image.open(path).convert("RGB")
    except Exception:  # noqa: BLE001 - a broken thumbnail just drops the candidate from the sheet
        return None


def make_sheets(records: list[dict], out_prefix: str, per_sheet: int = 48, columns: int = 8, cell: int = 220,
                cached_only: bool = False) -> list[str]:
    session = _session()
    paths = []
    for sheet_index in range(0, len(records), per_sheet):
        chunk = records[sheet_index:sheet_index + per_sheet]
        rows = (len(chunk) + columns - 1) // columns
        sheet = Image.new("RGB", (columns * cell, rows * (cell + 18)), "white")
        draw = ImageDraw.Draw(sheet)
        for offset, record in enumerate(chunk):
            thumb = fetch_thumb(record, session, cached_only)
            x, y = (offset % columns) * cell, (offset // columns) * (cell + 18)
            if thumb is not None:
                thumb.thumbnail((cell - 4, cell - 4))
                sheet.paste(thumb, (x + 2, y + 2))
            draw.text((x + 4, y + cell), f"{sheet_index + offset}", fill="black")
        path = f"{out_prefix}_{sheet_index // per_sheet:02d}.jpg"
        os.makedirs(os.path.dirname(path), exist_ok=True)
        sheet.save(path, quality=85)
        paths.append(path)
    return paths


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidates", required=True)
    parser.add_argument("--nominated", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--phones-only", action="store_true")
    parser.add_argument("--max", type=int, default=0, help="review at most N candidates (deterministic order)")
    parser.add_argument("--cached-only", action="store_true", help="use review thumbnails already on disk; no requests")
    args = parser.parse_args(argv)
    records = [r for r in json.load(open(os.path.join(AUTO_ROOT, args.candidates)))
               if args.nominated in r["nominated_classes"] and (r["is_phone"] or not args.phones_only)]
    # Phones first, then camera fallbacks; stable order so sheet indices are reproducible.
    records.sort(key=lambda r: (not r["is_phone"], record_key(r)))
    if args.max:
        records = records[:args.max]
    index_path = os.path.join(AUTO_ROOT, args.out + "_index.json")
    os.makedirs(os.path.dirname(index_path), exist_ok=True)
    json.dump([record_key(r) for r in records], open(index_path, "w"))
    if args.cached_only:
        records = [r for r in records if os.path.exists(os.path.join(THUMB_DIR, record_key(r) + ".jpg"))]
    json.dump([record_key(r) for r in records], open(index_path, "w"))
    for path in make_sheets(records, os.path.join(AUTO_ROOT, args.out), cached_only=args.cached_only):
        print(path)


if __name__ == "__main__":
    main()
