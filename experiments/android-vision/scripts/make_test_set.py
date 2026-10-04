#!/usr/bin/env python3
"""Build the evaluation photo set into work/photos/ (git-ignored).

Real photos: the 22 Unsplash-licensed originals listed in experiments/lut3d/photos/MANIFEST.csv
(docs/ui/assets/photos holds downscaled copies of the same Unsplash images, so the originals are
used). Every photo is re-encoded with its long edge at 2048 px, the resolution the harness feeds
to every candidate.

Real multi-person photo: experiments/test-photos/group_three_01.jpg (three faces, light / medium /
deep skin; Unsplash License; source in experiments/test-photos/SOURCES.csv), copied unchanged.

Synthetic composites (made only from the same licensed photos) cover cases the real set lacks:
  synthetic_group4      four portraits (light / medium / deep / very deep skin) side by side,
                        faces ~250 px: "choose among several faces".
  synthetic_small_faces five portraits pasted small into a no-person landscape, faces ~45-70 px:
                        group-at-distance / small-face recall, plus person masks for small people.
"""
import csv
import pathlib
import sys

from PIL import Image, ImageOps

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
LUT_PHOTOS = REPO / "experiments/lut3d/photos"
TEST_PHOTOS = REPO / "experiments/test-photos"
EXTRA_REAL_PHOTOS = ["group_three_01.jpg"]
OUT = ROOT / "work/photos"
MAX_EDGE = 2048


def load(name: str) -> Image.Image:
    return ImageOps.exif_transpose(Image.open(LUT_PHOTOS / name)).convert("RGB")


def fit(image: Image.Image, max_edge: int = MAX_EDGE) -> Image.Image:
    scale = max_edge / max(image.size)
    if scale >= 1:
        return image
    return image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)


def portrait_tile(name: str, width: int, height: int) -> Image.Image:
    """Centre-crop to the tile aspect, biased upwards where portrait faces sit."""
    image = load(name)
    target_aspect = width / height
    if image.width / image.height > target_aspect:
        crop_width = round(image.height * target_aspect)
        left = (image.width - crop_width) // 2
        box = (left, 0, left + crop_width, image.height)
    else:
        crop_height = round(image.width / target_aspect)
        top = max(0, round((image.height - crop_height) * 0.25))
        box = (0, top, image.width, top + crop_height)
    return image.crop(box).resize((width, height), Image.LANCZOS)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    rows = list(csv.DictReader(open(LUT_PHOTOS / "MANIFEST.csv")))
    missing = [r["filename"] for r in rows if not (LUT_PHOTOS / r["filename"]).exists()]
    if missing:
        print("missing originals (download per MANIFEST.csv download_url):", missing, file=sys.stderr)
        return 1
    for row in rows:
        fit(load(row["filename"])).save(OUT / row["filename"], quality=92)

    for name in EXTRA_REAL_PHOTOS:
        fit(ImageOps.exif_transpose(Image.open(TEST_PHOTOS / name)).convert("RGB")).save(OUT / name, quality=95)

    group_names = ["portrait_light_01.jpg", "portrait_medium_01.jpg", "portrait_deep_01.jpg", "portrait_deep_03.jpg"]
    group = Image.new("RGB", (2048, 768), (128, 128, 128))
    for index, name in enumerate(group_names):
        group.paste(portrait_tile(name, 512, 768), (index * 512, 0))
    group.save(OUT / "synthetic_group4.jpg", quality=92)

    small_names = ["portrait_light_02.jpg", "portrait_medium_02.jpg", "portrait_deep_02.jpg",
                   "portrait_deep_01.jpg", "portrait_light_01.jpg"]
    scene = fit(load("landscape_03.jpg"))
    tile_heights = [300, 260, 220, 190, 160]
    x = 120
    for name, tile_height in zip(small_names, tile_heights):
        tile = portrait_tile(name, round(tile_height * 2 / 3), tile_height)
        scene.paste(tile, (x, scene.height - tile_height - 140))
        x += tile.width + 160
    scene.save(OUT / "synthetic_small_faces.jpg", quality=92)

    print(f"{len(rows) + len(EXTRA_REAL_PHOTOS) + 2} photos -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
