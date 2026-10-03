"""Build before / mask / after contact sheets from out/<candidate>/<case>.png.

Sheets go to ~/.codex/artifacts/lightly/v1/remove/ (outside the repo):
  sheet_<candidate>.jpg   one row per case: before | brush | after   (zoomed to the edit region)
  compare_<case>.jpg      one case, every candidate side by side, plus a full-frame strip
  compare_all.jpg         every case x every candidate (overview)
  detail_<case>.jpg       1:1 pixels (no resampling) around the largest stroke, every candidate

Zoom region = the stroke's bounding box grown 60% per side (min 360 px), so the fill is visible;
the full-frame result is unchanged outside the brush (checked in run_eval.py).
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

import inpaint_lib as lib

SHEETS_DIR = Path.home() / ".codex" / "artifacts" / "lightly" / "v1" / "remove"
TILE = 420
LABEL_H = 34
CANDIDATE_LABELS = {
    "lama": "LaMa big-lama @512 (Apache-2.0)",
    "lama_flex1024": "LaMa big-lama @<=1024",
    "migan": "MI-GAN 512 Places2 (MIT)",
    "telea": "OpenCV Telea (classical)",
    "shiftmap": "OpenCV ShiftMap (exemplar)",
}


def font(size: int):
    for candidate in ("/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            continue
    return ImageFont.load_default()


def zoom_box(mask: np.ndarray) -> tuple[int, int, int, int]:
    height, width = mask.shape
    x0, y0, x1, y1 = lib.mask_bbox(mask)
    side = max(x1 - x0, y1 - y0)
    side = max(int(side * 2.2), 360)
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    side = min(side, width, height)
    left = min(max(cx - side // 2, 0), width - side)
    top = min(max(cy - side // 2, 0), height - side)
    return left, top, left + side, top + side


def detail_box(mask: np.ndarray, side: int = 360) -> tuple[int, int, int, int]:
    """Native-resolution window centred on the largest stroke's centroid."""
    jobs = sorted(lib.plan_stroke_jobs(mask), key=lambda job: int((job.mask > 0).sum()), reverse=True)
    ys, xs = np.nonzero(jobs[0].mask)
    height, width = mask.shape
    left = int(min(max(xs.mean() - side / 2, 0), width - side))
    top = int(min(max(ys.mean() - side / 2, 0), height - side))
    return left, top, left + side, top + side


def labelled(tile: Image.Image, text: str) -> Image.Image:
    canvas = Image.new("RGB", (TILE, TILE + LABEL_H), (24, 24, 24))
    canvas.paste(tile.resize((TILE, TILE), Image.LANCZOS), (0, LABEL_H))
    ImageDraw.Draw(canvas).text((8, 7), text, fill=(235, 235, 235), font=font(17))
    return canvas


def brush_overlay(image: np.ndarray, mask: np.ndarray) -> np.ndarray:
    overlay = image.astype(np.float32).copy()
    selected = mask > 0
    overlay[selected] = overlay[selected] * 0.45 + np.array([255, 0, 200]) * 0.55
    return overlay.astype(np.uint8)


def grid(rows: list[list[Image.Image]]) -> Image.Image:
    cell_w, cell_h = rows[0][0].size
    sheet = Image.new("RGB", (cell_w * max(len(r) for r in rows), cell_h * len(rows)), (24, 24, 24))
    for row_index, row in enumerate(rows):
        for column_index, cell in enumerate(row):
            sheet.paste(cell, (column_index * cell_w, row_index * cell_h))
    return sheet


def main() -> None:
    candidates = [c for c in (sys.argv[1:] or CANDIDATE_LABELS) if (lib.EXPERIMENT_ROOT / "out" / c).exists()]
    SHEETS_DIR.mkdir(parents=True, exist_ok=True)
    cases = lib.load_cases()
    per_candidate_rows = {candidate: [] for candidate in candidates}
    overview_rows = []
    for case in cases:
        image = lib.load_rgb(case.photo_path)
        mask = lib.rasterise_mask(case, image.shape[1], image.shape[0])
        box = zoom_box(mask)
        crop = lambda array: Image.fromarray(array[box[1]:box[3], box[0]:box[2]])
        before = labelled(crop(image), f"{case.case_id}: before")
        brush = labelled(crop(brush_overlay(image, mask)), "brush mask")
        outputs = {}
        for candidate in candidates:
            result_path = lib.EXPERIMENT_ROOT / "out" / candidate / f"{case.case_id}.png"
            if result_path.exists():
                outputs[candidate] = lib.load_rgb(result_path)
        for candidate, result in outputs.items():
            per_candidate_rows[candidate].append([before, brush, labelled(crop(result), CANDIDATE_LABELS[candidate])])
        compare_row = [before, brush] + [labelled(crop(result), CANDIDATE_LABELS[c]) for c, result in outputs.items()]
        overview_rows.append(compare_row)
        grid([compare_row]).save(SHEETS_DIR / f"compare_{case.case_id}.jpg", quality=90)

        dbox = detail_box(mask)
        detail_crop = lambda array: Image.fromarray(array[dbox[1]:dbox[3], dbox[0]:dbox[2]])
        detail_row = [labelled(detail_crop(image), f"{case.case_id}: before (1:1)"),
                      labelled(detail_crop(brush_overlay(image, mask)), "brush mask (1:1)")]
        detail_row += [labelled(detail_crop(result), CANDIDATE_LABELS[c]) for c, result in outputs.items()]
        grid([detail_row]).save(SHEETS_DIR / f"detail_{case.case_id}.jpg", quality=92)

        # Full-frame strip: proves the paste-back leaves the rest of the photo untouched.
        thumb_side = 640
        full_tiles = []
        for title, array in [("before", image)] + [(CANDIDATE_LABELS[c], r) for c, r in outputs.items()]:
            thumb = Image.fromarray(array)
            thumb.thumbnail((thumb_side, thumb_side))
            canvas = Image.new("RGB", (thumb_side, thumb_side + LABEL_H), (24, 24, 24))
            canvas.paste(thumb, ((thumb_side - thumb.width) // 2, LABEL_H))
            ImageDraw.Draw(canvas).text((8, 7), title, fill=(235, 235, 235), font=font(17))
            full_tiles.append(canvas)
        grid([full_tiles]).save(SHEETS_DIR / f"fullframe_{case.case_id}.jpg", quality=85)

    for candidate, rows in per_candidate_rows.items():
        if rows:
            grid(rows).save(SHEETS_DIR / f"sheet_{candidate}.jpg", quality=90)
    overview = grid(overview_rows)
    overview.thumbnail((3200, 3200))
    overview.save(SHEETS_DIR / "compare_all.jpg", quality=88)
    print("sheets written to", SHEETS_DIR)


if __name__ == "__main__":
    main()
