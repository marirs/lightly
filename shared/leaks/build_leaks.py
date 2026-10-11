#!/usr/bin/env python3
"""Build the light-leak pack both apps bundle (owner, 2026-10-11: real light leaks from the owner's film-burn clips).

    python shared/leaks/build_leaks.py [--review .leak-review] [--out shared/leaks/out]

Input: the leak review (.leak-review/candidates.json and frames/, not committed), the stills the owner approved,
extracted from the purchased clips. Output (`out/`, git-ignored like the look pack, so the purchase never enters the
repository):
- leaks.json   format "lightly-leak-pack" 1: per leak its id, display name, image and thumbnail files and their SHA-256;
- img/<id>.jpg   the leak at 1600 px on the long edge (sRGB, JPEG q90), the overlay the renderer screens over the frame;
- thumb/<id>.jpg 240 px, for the panel's tiles.

Ids are "leak-" + the first 12 hex digits of the source still's SHA-256, so they never move when the set changes.
Names follow the preset names' style (no digits): the leak's dominant colour and its shape, unique.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
LONG_EDGE, THUMB_EDGE = 1600, 240
COLOUR_WORDS = [  # hue (degrees, HSV) → words
    (0, 18, ["Ember", "Crimson", "Scarlet"]), (18, 40, ["Amber", "Copper", "Tangerine"]),
    (40, 62, ["Gold", "Honey", "Saffron"]), (62, 160, ["Lime", "Moss", "Citrine"]),
    (160, 250, ["Azure", "Cobalt", "Teal"]), (250, 320, ["Violet", "Plum", "Orchid"]), (320, 361, ["Rose", "Coral", "Ruby"])]
SHAPE_WORDS = {"edge": ["Edge", "Fringe", "Border"], "flare": ["Flare", "Glow", "Bloom"],
               "streak": ["Streak", "Sweep", "Beam"], "wash": ["Wash", "Haze", "Veil"]}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def describe(image: Image.Image) -> tuple[float, str]:
    """Dominant hue of the bright part, and a shape word from where the light sits."""
    small = np.asarray(image.convert("RGB").resize((96, 54)), dtype=float) / 255
    luma = small.mean(2)
    bright = luma > max(0.25, np.percentile(luma, 75))
    hsv = np.asarray(Image.fromarray((small * 255).astype(np.uint8)).convert("HSV"), dtype=float)
    hues = hsv[..., 0][bright] / 255 * 360
    hue = float(np.degrees(np.arctan2(np.sin(np.radians(hues)).mean(), np.cos(np.radians(hues)).mean())) % 360) if hues.size else 30.0
    ys, xs = np.nonzero(bright)
    coverage = bright.mean()
    near_edge = xs.size and (min(xs.min(), 95 - xs.max()) == 0 or min(ys.min(), 53 - ys.max()) == 0)
    aspect = (np.ptp(xs) + 1) / (np.ptp(ys) + 1) if xs.size else 1
    shape = "wash" if coverage > 0.45 else "streak" if (aspect > 2.6 or aspect < 0.38) else "edge" if near_edge else "flare"
    return hue, shape


def name_for(leak_id: str, hue: float, shape: str, taken: set[str]) -> str:
    colours = next(words for low, high, words in COLOUR_WORDS if low <= hue < high)
    seed = int(leak_id[5:13], 16)
    for k in range(len(colours) * 3):
        candidate = f"{colours[(seed + k) % len(colours)]} {SHAPE_WORDS[shape][(seed // 3 + k // len(colours)) % 3]}"
        if candidate not in taken:
            return candidate
    for first in [w for _, _, ws in COLOUR_WORDS for w in ws]:
        for second in [w for ws in SHAPE_WORDS.values() for w in ws]:
            if f"{first} {second}" not in taken:
                return f"{first} {second}"
    raise SystemExit("no free leak name")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--review", type=Path, default=REPO / ".leak-review")
    parser.add_argument("--out", type=Path, default=HERE / "out")
    args = parser.parse_args()
    candidates = json.loads((args.review / "candidates.json").read_text())
    staging = args.out.with_name(args.out.name + ".partial")
    shutil.rmtree(staging, ignore_errors=True)
    (staging / "img").mkdir(parents=True)
    (staging / "thumb").mkdir()
    leaks, taken = [], set()
    for candidate in candidates:
        source = args.review / "frames" / candidate["f"]
        leak_id = "leak-" + sha256(source)[:12]
        image = Image.open(source).convert("RGB")
        hue, shape = describe(image)
        name = name_for(leak_id, hue, shape, taken)
        taken.add(name)
        full = image.copy(); full.thumbnail((LONG_EDGE, LONG_EDGE), Image.LANCZOS)
        thumb = image.copy(); thumb.thumbnail((THUMB_EDGE, THUMB_EDGE), Image.LANCZOS)
        full.save(staging / "img" / f"{leak_id}.jpg", quality=90)
        thumb.save(staging / "thumb" / f"{leak_id}.jpg", quality=85)
        leaks.append({"id": leak_id, "name": name, "image": f"img/{leak_id}.jpg", "thumbnail": f"thumb/{leak_id}.jpg",
                      "imageSha256": sha256(staging / "img" / f"{leak_id}.jpg"), "width": full.width, "height": full.height})
    manifest = {"format": "lightly-leak-pack", "formatVersion": 1, "leaks": leaks}
    (staging / "leaks.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n")
    shutil.rmtree(args.out, ignore_errors=True)
    staging.rename(args.out)
    size = sum(p.stat().st_size for p in args.out.rglob("*") if p.is_file())
    print(f"{len(leaks)} leaks, {size / 1e6:.1f} MB: " + ", ".join(l["name"] for l in leaks[:12]) + " …")


if __name__ == "__main__":
    main()
