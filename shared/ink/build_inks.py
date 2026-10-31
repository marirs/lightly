#!/usr/bin/env python3
"""Build the ink pack both apps bundle (Effects › Ink, owner-approved 2026-10-31: docs/ui/proposals/ink-2026-10-31).

    python shared/ink/build_inks.py [--review .preset-review/ink] [--out shared/ink/out]

Input: the ink review (.preset-review/ink, not committed): scans/<name>.jpg, the photographed ink scans; SOURCES.tsv
(name, image URL, Unsplash page, photographer); picks.json, the scans the owner kept. Output (`out/`, git-ignored like
the leak pack):
- inks.json   format "lightly-ink-pack" 1: per ink its id, display name, kind, image and thumbnail files, SHA-256 and credit;
- img/<id>.png  a stroke ink's mask: 8-bit grey, 255 where the photo shows through, cropped to the stroke, turned so it is
                landscape (width ≥ height), 1600 px on the long edge;
- img/<id>.jpg  an overlay ink (Splatter, Speckle): the scan's grey, multiplied over the frame, 1600 px on the long edge;
- thumb/<id>.*  the same at 240 px, for the panel's tiles.

Ids are "ink-" + the first 12 hex digits of the source scan's SHA-256, so they never move when the set changes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
LONG_EDGE, THUMB_EDGE = 1600, 240
# The approved proposal's names, in its gallery order. Overlay inks are printed over the whole photo.
NAMES = {"01-dry-sweep": "Dry Sweep", "02-dry-vertical": "Dry Vertical", "03-bold-strokes": "Bold Strokes",
         "04-stacked-dry": "Stacked", "05-double-stroke": "Double Stroke", "06-torn-dry": "Torn Stroke",
         "07-dry-block": "Dry Block", "08-three-arcs": "Three Arcs", "09-grey-wash": "Grey Wash", "10-thin-arc": "Thin Arc",
         "11-ink-edge": "Ink Edge", "12-ink-bloom-1": "Bloom", "13-ink-bloom-2": "Soft Bloom", "14-ink-bloom-3": "Deep Bloom",
         "15-ink-bloom-4": "Cloud Bloom", "16-ink-wash": "Ink Wash", "17-splatter": "Splatter", "18-speckle": "Speckle"}
OVERLAY = {"17-splatter", "18-speckle"}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def luminance(image: Image.Image) -> np.ndarray:
    return (np.asarray(image.convert("RGB"), dtype=np.float64) / 255.0) @ np.array([0.2126, 0.7152, 0.0722])


def stroke_mask(scan: Image.Image) -> Image.Image:
    """Where the ink is, 0…255. Polarity from the scan's border (white strokes on black, or black ink on white); the
    paper level maps to 0 and the densest 0.5 % of ink to 255; then a light blur, the crop to the stroke, and a curve
    that drops paper-grain speckle but keeps the soft ink edges (the approved review's look)."""
    lum = luminance(scan)
    border = np.concatenate([lum[:8].ravel(), lum[-8:].ravel(), lum[:, :8].ravel(), lum[:, -8:].ravel()])
    dark_paper = np.median(border) < 0.5
    ink = lum if dark_paper else 1.0 - lum
    low = np.median(border if dark_paper else 1.0 - border)
    high = max(np.percentile(ink, 99.5), low + 0.05)
    mask = Image.fromarray((np.clip((ink - low) / (high - low), 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2))
    mask = mask.crop(mask.point(lambda v: 255 if v > 24 else 0).getbbox() or (0, 0, mask.width, mask.height))
    a = np.clip((np.asarray(mask, dtype=np.float64) / 255 - 0.04) / 0.9, 0, 1) ** 0.85
    mask = Image.fromarray((a * 255).round().astype(np.uint8))
    return mask if mask.width >= mask.height else mask.rotate(90, expand=True)


def overlay_grey(scan: Image.Image) -> Image.Image:
    return Image.fromarray((np.clip(luminance(scan) * 1.08, 0, 1) * 255).round().astype(np.uint8))


def resized(image: Image.Image, edge: int) -> Image.Image:
    copy = image.copy(); copy.thumbnail((edge, edge), Image.LANCZOS)
    return copy


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--review", type=Path, default=REPO / ".preset-review/ink")
    parser.add_argument("--out", type=Path, default=HERE / "out")
    args = parser.parse_args()
    kept = json.loads((args.review / "picks.json").read_text())["keep"]
    credits = {row[0]: row for row in (line.split("\t") for line in (args.review / "SOURCES.tsv").read_text().splitlines() if line)}
    staging = args.out.with_name(args.out.name + ".partial")
    shutil.rmtree(staging, ignore_errors=True)
    (staging / "img").mkdir(parents=True)
    (staging / "thumb").mkdir()
    inks = []
    for name in NAMES:
        if name not in kept:
            continue
        source = args.review / "scans" / f"{name}.jpg"
        ink_id = "ink-" + sha256(source)[:12]
        scan = Image.open(source).convert("RGB")
        kind = "overlay" if name in OVERLAY else "stroke"
        art, ext = (overlay_grey(scan), "jpg") if kind == "overlay" else (stroke_mask(scan), "png")
        full, thumb = resized(art, LONG_EDGE), resized(art, THUMB_EDGE)
        image_path, thumb_path = f"img/{ink_id}.{ext}", f"thumb/{ink_id}.{ext}"
        save = (lambda im, p: im.save(p, quality=88)) if ext == "jpg" else (lambda im, p: im.save(p, optimize=True))
        save(full, staging / image_path); save(thumb, staging / thumb_path)
        _, _, page, by = credits[name]
        inks.append({"id": ink_id, "name": NAMES[name], "kind": kind, "image": image_path, "thumbnail": thumb_path,
                     "imageSha256": sha256(staging / image_path), "width": full.width, "height": full.height,
                     "credit": {"by": by, "page": page}})
    manifest = {"format": "lightly-ink-pack", "formatVersion": 1, "inks": inks}
    (staging / "inks.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n")
    shutil.rmtree(args.out, ignore_errors=True)
    staging.rename(args.out)
    size = sum(p.stat().st_size for p in args.out.rglob("*") if p.is_file())
    print(f"{len(inks)} inks, {size / 1e6:.1f} MB: " + ", ".join(i["name"] for i in inks))


if __name__ == "__main__":
    main()
