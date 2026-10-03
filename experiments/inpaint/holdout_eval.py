"""Objective quality proxy: hide REAL background behind synthetic brush strokes and score the fill.

Object removal has no ground truth, so this hold-out test masks regions of the 22 licensed photos
(no object there), runs the same app-shaped pipeline, and compares the fill with the hidden
original pixels. Three stroke shapes mirror the three processing routes:
  spot   : 48 px dab                         -> "native" route (blemish-sized)
  stroke : ~700 px long, 28 px wide polyline -> "tiled-native" route (wire-like)
  blob   : ~360 px free-form lasso           -> "downscaled" route (object-sized)

Metrics on a crop around each mask (1.5x bbox): PSNR over the masked pixels only, and LPIPS
(AlexNet, Zhang et al. 2018) on the crop. Lower LPIPS = perceptually closer. Absolute values are
not comparable to papers (different masks/data); only the ranking between candidates matters.

    OMP_NUM_THREADS=4 <venv>/bin/python holdout_eval.py lama migan telea
    OMP_NUM_THREADS=4 <contrib-venv>/bin/python holdout_eval.py shiftmap --score-later
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

import inpaint_lib as lib
import run_eval

PHOTO_DIR = lib.REPO_ROOT / "experiments" / "lut3d" / "photos"
HOLDOUT_DIR = lib.EXPERIMENT_ROOT / "out" / "holdout"
SHAPES = ("spot", "stroke", "blob")


def synthetic_mask(shape_name: str, width: int, height: int, rng: np.random.Generator) -> np.ndarray:
    mask = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(mask)
    margin = 420
    cx = rng.uniform(margin, width - margin)
    cy = rng.uniform(margin, height - margin)
    if shape_name == "spot":
        draw.ellipse([cx - 24, cy - 24, cx + 24, cy + 24], fill=255)
    elif shape_name == "stroke":
        angle = rng.uniform(-math.pi / 5, math.pi / 5)
        points = []
        for step in np.linspace(-1, 1, 6):
            wobble = rng.uniform(-25, 25)
            points.append((cx + step * 350 * math.cos(angle) - wobble * math.sin(angle),
                           cy + step * 350 * math.sin(angle) + wobble * math.cos(angle)))
        draw.line(points, fill=255, width=28, joint="curve")
    elif shape_name == "blob":
        vertices = []
        for index in range(14):
            theta = 2 * math.pi * index / 14
            radius = rng.uniform(110, 180)
            vertices.append((cx + radius * math.cos(theta), cy + radius * math.sin(theta) * 1.2))
        draw.polygon(vertices, fill=255)
    return np.array(mask)


def holdout_items():
    rng = np.random.default_rng(20261003)
    for photo_path in sorted(PHOTO_DIR.glob("*.jpg")):
        with Image.open(photo_path) as image:
            width, height = image.size
        for shape_name in SHAPES:
            yield photo_path, shape_name, synthetic_mask(shape_name, width, height, rng)


def score(original: np.ndarray, result: np.ndarray, mask: np.ndarray, lpips_model) -> dict:
    import torch

    x0, y0, x1, y1 = lib.mask_bbox(mask)
    pad_x, pad_y = (x1 - x0) // 4 + 16, (y1 - y0) // 4 + 16
    x0, y0 = max(0, x0 - pad_x), max(0, y0 - pad_y)
    x1, y1 = min(mask.shape[1], x1 + pad_x), min(mask.shape[0], y1 + pad_y)
    selected = mask[y0:y1, x0:x1] > 0
    reference = original[y0:y1, x0:x1].astype(np.float64) / 255
    candidate = result[y0:y1, x0:x1].astype(np.float64) / 255
    mse = float(np.mean((reference[selected] - candidate[selected]) ** 2))
    to_tensor = lambda array: torch.from_numpy(array).permute(2, 0, 1)[None].float() * 2 - 1
    with torch.no_grad():
        perceptual = float(lpips_model(to_tensor(reference), to_tensor(candidate)))
    return {"psnr_masked_db": round(10 * math.log10(1 / max(mse, 1e-10)), 2), "lpips_crop": round(perceptual, 4)}


def main() -> None:
    arguments = [a for a in sys.argv[1:] if not a.startswith("--")]
    score_later = "--score-later" in sys.argv
    lpips_model = None
    if not score_later:
        import lpips

        lpips_model = lpips.LPIPS(net="alex", verbose=False)
    results_path = lib.EXPERIMENT_ROOT / "results" / "holdout.json"
    all_results = json.loads(results_path.read_text()) if results_path.exists() else {}
    for candidate_name in arguments:
        inpainter = run_eval.build_candidate(candidate_name)
        rows = []
        for photo_path, shape_name, mask in holdout_items():
            original = lib.load_rgb(photo_path)
            result, _ = lib.remove_strokes(inpainter, original, mask)
            out_path = HOLDOUT_DIR / candidate_name / f"{photo_path.stem}_{shape_name}.png"
            out_path.parent.mkdir(parents=True, exist_ok=True)
            x0, y0, x1, y1 = lib.mask_bbox(mask)
            # Store only the edited neighbourhood so --score-later can run in another venv.
            np.savez_compressed(out_path.with_suffix(".npz"), box=np.array([x0, y0, x1, y1]),
                                result=result[max(0, y0 - 400):y1 + 400, max(0, x0 - 400):x1 + 400])
            row = {"photo": photo_path.stem, "shape": shape_name}
            if lpips_model is not None:
                row |= score(original, result, mask, lpips_model)
            rows.append(row)
            print(candidate_name, row, flush=True)
        all_results[candidate_name] = rows
        results_path.write_text(json.dumps(all_results, indent=2) + "\n")


def score_saved(candidate_name: str) -> None:
    """Score results saved by a --score-later run (used for ShiftMap from the contrib venv)."""
    import lpips

    lpips_model = lpips.LPIPS(net="alex", verbose=False)
    results_path = lib.EXPERIMENT_ROOT / "results" / "holdout.json"
    all_results = json.loads(results_path.read_text()) if results_path.exists() else {}
    rows = []
    for photo_path, shape_name, mask in holdout_items():
        original = lib.load_rgb(photo_path)
        saved = np.load(HOLDOUT_DIR / candidate_name / f"{photo_path.stem}_{shape_name}.npz")
        x0, y0, x1, y1 = saved["box"]
        result = original.copy()
        top, left = max(0, y0 - 400), max(0, x0 - 400)
        patch = saved["result"]
        result[top:top + patch.shape[0], left:left + patch.shape[1]] = patch
        rows.append({"photo": photo_path.stem, "shape": shape_name} | score(original, result, mask, lpips_model))
    all_results[candidate_name] = rows
    results_path.write_text(json.dumps(all_results, indent=2) + "\n")


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--score-saved":
        score_saved(sys.argv[2])
    else:
        main()
