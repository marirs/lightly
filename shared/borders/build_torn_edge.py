#!/usr/bin/env python3
"""Build the torn-paper edge strip both apps bundle (owner, 2026-10-12: Border › Paper › Torn uses a real rip, depth B).

    python shared/borders/build_torn_edge.py <ripped-edge.svg> [--out shared/borders/out]

Input: the owner's Vecteezy "Ripped out torn paper sheet edge" SVG (24080338). Rasterised with macOS Quick Look
(`qlmanage`), the only SVG renderer on the build Mac. Output (`out/`, git-ignored like the look and leak packs, so the
purchased art never enters the repository):
- torn-edge.png   the strip, 2400 × 220, deslanted so the rip runs horizontally. R = the photo layer's coverage
                  (the torn sheet above its white core), G = the photo plus its white core. Row 0 is inside the photo,
                  the last row the photo's edge. B is 0. Rendering: rendering-v2 §7.5.
- torn-edge.json  format "lightly-torn-edge" 1: file, size and SHA-256.
- mockup/torn-photo.png, mockup/torn-core.png   nine-slice masks for the approved mockup (-webkit-mask-box-image),
                  rendered with `torn_masks`, the reference implementation of §7.5.
- golden-<w>x<h>.png   §7.5 masks (R = photo, G = photo plus core) for the engines' tests.

The SVG draws a red sheet torn above a light-grey core, over a checkerboard drawn as shapes (not real transparency).
Its first group (clip-0/clip-1) is the sheet, the groups after it the core's layers; everything before them is the
checkerboard and the drop shadow, which are discarded (§7.5 draws its own shadow). Each part is rendered white on
black, so the rendered grey level is its coverage.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
STRIP_WIDTH, STRIP_HEIGHT = 2400, 220
# Rows of the strip above the rip's mean line: the deepest point of the photo's edge sits ~47 rows down and the
# core's outermost fibre ~216, so the strip spans the whole rip with a little untouched photo above it.
ROWS_ABOVE_RIP_LINE = 150
# §7.5 constants (also in rendering-v2.json, stages[border].operators[paper.torn]).
DEPTH_OF_SHORT_EDGE = 0.075
SIDE_OFFSETS = {"top": 0, "right": 1300, "bottom": 2700, "left": 3900}
CORNER_RADIUS_OF_DEPTH = 0.35


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def split_layers(svg: str) -> tuple[str, str, str]:
    """Header with <defs>, the sheet group, the core groups."""
    defs_end = svg.index("</defs>") + len("</defs>")
    sheet_start = svg.index('<g clip-path="url(#clip-0)">', defs_end)
    core_start = svg.index('<g clip-path="url(#clip-2)">', sheet_start)
    return svg[:defs_end], svg[sheet_start:core_start], svg[core_start:svg.rindex("</svg>")]


def render_coverage(header: str, body: str, workdir: Path, name: str, width: int, height: int) -> np.ndarray:
    white = re.sub(r'fill="(rgb\([^"]*\)|url\(#linear-pattern-0\))"', 'fill="rgb(100%,100%,100%)"', body)
    source = workdir / f"{name}.svg"
    source.write_text(f'{header}<rect width="{width}" height="{height}" fill="black"/>{white}</svg>')
    subprocess.run(["qlmanage", "-t", "-s", str(width), "-o", str(workdir), str(source)], check=True, capture_output=True)
    # Quick Look pads the thumbnail to a square below the drawing; the drawing starts at the top-left.
    image = Image.open(workdir / f"{name}.svg.png").convert("L")
    return np.asarray(image, np.float32)[:height, :width] / 255


def deslant(photo: np.ndarray, outer: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    width = photo.shape[1]
    lowest_outer_row = np.array([np.nonzero(outer[:, x] > 0.5)[0].max() for x in range(width)])
    slope, intercept = np.polyfit(np.arange(width), lowest_outer_row, 1)
    strip_photo = np.zeros((STRIP_HEIGHT, width), np.float32)
    strip_outer = np.zeros((STRIP_HEIGHT, width), np.float32)
    for x in range(width):
        first_row = int(round(slope * x + intercept)) - ROWS_ABOVE_RIP_LINE
        strip_photo[:, x] = photo[first_row:first_row + STRIP_HEIGHT, x]
        strip_outer[:, x] = outer[first_row:first_row + STRIP_HEIGHT, x]
    if not (strip_photo[0] > 0.99).all() or not (strip_outer[-1] < 0.01).all():
        raise SystemExit("the rip does not fit the strip: row 0 must be all photo and the last row all mat")
    return strip_photo, strip_outer


def sample_bilinear(channel: np.ndarray, xs: np.ndarray, ys: np.ndarray) -> np.ndarray:
    """Pixel centres at integer + 0.5; x wraps over the mirrored period, y clamps."""
    period = channel.shape[1]
    x = xs - 0.5; y = np.clip(ys - 0.5, 0, channel.shape[0] - 1)
    x0 = np.floor(x).astype(int); y0 = np.floor(y).astype(int)
    fx = x - x0; fy = y - y0
    y1 = np.minimum(y0 + 1, channel.shape[0] - 1)
    x0m = x0 % period; x1m = (x0 + 1) % period
    top = channel[y0, x0m] * (1 - fx) + channel[y0, x1m] * fx
    bottom = channel[y1, x0m] * (1 - fx) + channel[y1, x1m] * fx
    return top * (1 - fy) + bottom * fy


def torn_masks(width: int, height: int, strip: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """§7.5 reference: photo coverage P and photo-plus-core coverage O over a width × height frame."""
    mirrored = np.concatenate([strip, strip[:, :, ::-1]], 2)  # period 2N, no seam where the strip repeats
    depth = DEPTH_OF_SHORT_EDGE * min(width, height)
    scale = depth / STRIP_HEIGHT
    ys, xs = np.mgrid[0:height, 0:width].astype(np.float64) + 0.5
    photo = np.ones((height, width)); outer = np.ones((height, width))
    sides = {  # (distance inward from the side, position along it)
        "top": (ys, xs), "right": (width - xs, height - ys), "bottom": (height - ys, width - xs), "left": (xs, ys)}
    for side, (inward, along) in sides.items():
        near = inward < depth
        strip_x = along[near] / scale + SIDE_OFFSETS[side]
        strip_y = STRIP_HEIGHT * (1 - inward[near] / depth)
        photo[near] *= sample_bilinear(mirrored[0], strip_x, strip_y)
        outer[near] *= sample_bilinear(mirrored[1], strip_x, strip_y)
    # Round each corner, where two rips overlap at a right angle: outside a circle of radius c inset c from both sides.
    c = CORNER_RADIUS_OF_DEPTH * depth
    for cx, cy in ((c, c), (width - c, c), (c, height - c), (width - c, height - c)):
        beyond_x = xs < cx if cx < width / 2 else xs > cx
        beyond_y = ys < cy if cy < height / 2 else ys > cy
        in_corner = beyond_x & beyond_y
        distance = np.hypot(xs - cx, ys - cy)
        keep = np.clip(c - distance + 0.5, 0, 1)  # one-pixel anti-aliased arc
        photo = np.where(in_corner, photo * keep, photo); outer = np.where(in_corner, outer * keep, outer)
    return photo.astype(np.float32), outer.astype(np.float32)


def save_masks(path: Path, photo: np.ndarray, outer: np.ndarray) -> None:
    rgb = np.stack([photo, outer, np.zeros_like(photo)], -1)
    Image.fromarray((rgb * 255).round().astype(np.uint8)).save(path)


def mockup_masks(out: Path, strip: np.ndarray) -> None:
    """Nine-slice masks: a 600 × 600 frame whose rip (depth 45) is the slice the mockup repeats along each side."""
    photo, outer = torn_masks(600, 600, strip)
    (out / "mockup").mkdir(exist_ok=True)
    for name, coverage in (("torn-photo", photo), ("torn-core", outer)):
        alpha = (coverage * 255).round().astype(np.uint8)
        rgba = np.dstack([np.full_like(alpha, 255)] * 3 + [alpha])
        Image.fromarray(rgba).save(out / "mockup" / f"{name}.png")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("svg", type=Path)
    parser.add_argument("--out", type=Path, default=HERE / "out")
    args = parser.parse_args()
    svg = args.svg.read_text()
    size = re.search(r'<svg[^>]*width="(\d+)"[^>]*height="(\d+)"', svg)
    width, height = int(size.group(1)), int(size.group(2))
    if width != STRIP_WIDTH:
        raise SystemExit(f"expected the 2400-wide Vecteezy 24080338 SVG, got {width} × {height}")
    header, sheet, core = split_layers(svg)
    with tempfile.TemporaryDirectory() as tmp:
        sheet_coverage = render_coverage(header, sheet, Path(tmp), "sheet", width, height)
        core_coverage = render_coverage(header, core, Path(tmp), "core", width, height)
    # The sheet's shape runs under the core; the photo is the sheet where no core lies over it.
    photo = np.clip(sheet_coverage - core_coverage, 0, 1)
    outer = np.maximum(sheet_coverage, core_coverage)
    strip_photo, strip_outer = deslant(photo, outer)

    args.out.mkdir(parents=True, exist_ok=True)
    strip_path = args.out / "torn-edge.png"
    save_masks(strip_path, strip_photo, strip_outer)
    strip = np.asarray(Image.open(strip_path), np.float32)[:, :, :2].transpose(2, 0, 1) / 255  # as the apps read it
    manifest = {"format": "lightly-torn-edge", "formatVersion": 1, "file": strip_path.name,
                "width": STRIP_WIDTH, "height": STRIP_HEIGHT, "sha256": sha256(strip_path)}
    (args.out / "torn-edge.json").write_text(json.dumps(manifest, indent=1) + "\n")
    mockup_masks(args.out, strip)
    for w, h in ((300, 200), (200, 300)):
        save_masks(args.out / f"golden-{w}x{h}.png", *torn_masks(w, h, strip))
    print(f"torn edge {STRIP_WIDTH}×{STRIP_HEIGHT} sha256 {manifest['sha256'][:12]} → {args.out}")


if __name__ == "__main__":
    main()
