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


def fetch_thumb(record: dict, session) -> Image.Image | None:
    path = os.path.join(THUMB_DIR, record["sha1"] + ".jpg")
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


def make_sheets(records: list[dict], out_prefix: str, per_sheet: int = 48, columns: int = 8, cell: int = 220) -> list[str]:
    session = _session()
    paths = []
    for sheet_index in range(0, len(records), per_sheet):
        chunk = records[sheet_index:sheet_index + per_sheet]
        rows = (len(chunk) + columns - 1) // columns
        sheet = Image.new("RGB", (columns * cell, rows * (cell + 18)), "white")
        draw = ImageDraw.Draw(sheet)
        for offset, record in enumerate(chunk):
            thumb = fetch_thumb(record, session)
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
    args = parser.parse_args(argv)
    records = [r for r in json.load(open(os.path.join(AUTO_ROOT, args.candidates))) if args.nominated in r["nominated_classes"]]
    records.sort(key=lambda r: r["sha1"])
    for path in make_sheets(records, os.path.join(AUTO_ROOT, args.out)):
        print(path)


if __name__ == "__main__":
    main()
