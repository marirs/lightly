"""Representative before/after sheets for Auto experiment 1 (for the archive; NOT committed).

  python make_before_after.py --out runs/before_after_sheets [--gate gating/gate_v1.json]

PH-1 sheets: for each class, images picked deterministically from the committed per-image results
(results/heldout_v1/ph1_photo_a_001/per_image.csv), never by eye: the class's worst images on its failing
criterion, the image with the median dE00, and the best passing one. Columns: Original | photo_a_001
[| photo_a_001 + gate]. HO-SYN sheet: clean reference | synthetically degraded input | model output
[| gated], for degraded and identity samples picked by the same kind of rule.

The PH-1 sheets were produced only AFTER the gate was pre-registered (gating/PREREGISTRATION_gate_v1.json),
so no gate parameter was chosen by looking at frozen-set images.

They show identifiable people from public CC0 photos (whose likeness rights CC0 does not clear), so they are
written under the git-ignored runs/ tree and copied only into the private archive.
"""
from __future__ import annotations

import argparse
import csv
import os

import numpy as np
from PIL import Image, ImageDraw

from eval_synthetic import frozen_degradation, load_clean
from lightly_auto import synthetic
from lightly_auto.arms import GatedLutArm, trained_run_arm
from lightly_auto.gating import GateConfig
from lightly_auto.manifest import load_manifest, resolve_source
from lightly_auto.paths import AUTO_ROOT
from run_eval import load_proxy

RUN = "runs/photo_a_001"
PH1_RESULTS = "results/heldout_v1/ph1_photo_a_001/per_image.csv"
HOSYN_RESULTS = "results/heldout_v1/hosyn_photo_a_001/per_image.csv"
CELL = 360
# The criterion each class failed most on, and whether a larger value is worse.
CLASS_FAILURE_KEY = {"night": ("night_p50_dL", True), "sunset": ("warm_chroma_ratio", False),
                     "already_good": ("dE00_mean", True), "backlit": ("subject_dL", False),
                     "portrait": ("skin_abs_dh_deg", True), "landscape": ("dE00_mean", True),
                     "indoor_mixed": ("dE00_mean", True)}


def thumbnail(rgb8: np.ndarray) -> Image.Image:
    image = Image.fromarray(rgb8)
    image.thumbnail((CELL, CELL), Image.LANCZOS)
    canvas = Image.new("RGB", (CELL, CELL), (24, 24, 24))
    canvas.paste(image, ((CELL - image.width) // 2, (CELL - image.height) // 2))
    return canvas


def sheet(rows: list[tuple[str, list[np.ndarray]]], headers: list[str], path: str) -> None:
    columns = len(headers)
    out = Image.new("RGB", (columns * CELL, 22 + len(rows) * (CELL + 34)), "white")
    draw = ImageDraw.Draw(out)
    for column, header in enumerate(headers):
        draw.text((column * CELL + 6, 4), header, fill="black")
    for index, (caption, images) in enumerate(rows):
        top = 22 + index * (CELL + 34)
        for column, image in enumerate(images):
            out.paste(thumbnail(image), (column * CELL, top))
        draw.text((6, top + CELL + 4), caption[:150], fill="black")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    out.save(path, quality=90)


def pick_ph1(rows: list[dict], rubric_class: str) -> list[dict]:
    key, larger_is_worse = CLASS_FAILURE_KEY[rubric_class]
    candidates = [r for r in rows if r["rubric_class"] == rubric_class and r.get(key) not in ("", None)]
    ordered = sorted(candidates, key=lambda r: float(r[key]), reverse=larger_is_worse)
    by_dE = sorted(candidates, key=lambda r: float(r["dE00_mean"]))
    passing = [r for r in by_dE if r["passed"] == "True"]
    picks = ordered[:2] + [by_dE[len(by_dE) // 2]] + passing[:1]
    unique, seen = [], set()
    for row in picks:
        if row["image_id"] not in seen:
            unique.append(row)
            seen.add(row["image_id"])
    return unique


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="runs/before_after_sheets")
    parser.add_argument("--gate", default="")
    args = parser.parse_args(argv)
    out_dir = os.path.join(AUTO_ROOT, args.out)
    model = trained_run_arm(os.path.join(AUTO_ROOT, RUN))
    arms = [model]
    headers_extra = ["photo_a_001 (ungated)"]
    if args.gate:
        arms.append(GatedLutArm(model, GateConfig.load(os.path.join(AUTO_ROOT, args.gate))))
        headers_extra.append("photo_a_001 + pre-registered gate")

    manifest = {r["image_id"]: r for r in load_manifest(os.path.join(AUTO_ROOT, "manifests/ph1_manifest.csv"))}
    results = [r for r in csv.DictReader(open(os.path.join(AUTO_ROOT, PH1_RESULTS))) if r["arm"].startswith("candidate")]
    for rubric_class in CLASS_FAILURE_KEY:
        rows = []
        for picked in pick_ph1(results, rubric_class):
            proxy = load_proxy(resolve_source(manifest[picked["image_id"]]), 2048)
            outputs = [arm.render(proxy) for arm in arms]
            strength = outputs[-1].info.get("gate_strength") if args.gate else None
            caption = (f"{picked['image_id']}  dE00 {float(picked['dE00_mean']):.2f}  "
                       f"{'PASS' if picked['passed'] == 'True' else 'FAIL ' + picked['failed_criteria']}"
                       + (f"  gate s={strength:.2f}" if strength is not None else ""))
            rows.append((caption, [proxy] + [o.image for o in outputs]))
        sheet(rows, ["PH-1 original"] + headers_extra, os.path.join(out_dir, f"ph1_{rubric_class}.jpg"))

    hosyn_manifest = {r["image_id"]: r for r in load_manifest(os.path.join(AUTO_ROOT, "manifests/cc0ref_manifest.csv"))}
    hosyn = list(csv.DictReader(open(os.path.join(AUTO_ROOT, HOSYN_RESULTS))))
    key = [k for k in hosyn[0] if k.startswith("candidate") and k.endswith("dE00_vs_clean")][0]
    degraded = sorted((r for r in hosyn if r["identity"] == "False"), key=lambda r: float(r["input_dE00_vs_clean"]) - float(r[key]))
    identity = sorted((r for r in hosyn if r["identity"] == "True"), key=lambda r: float(r[key]))
    picks = degraded[:2] + degraded[len(degraded) // 2:len(degraded) // 2 + 2] + degraded[-2:] + identity[-2:] + identity[:1]
    rows = []
    for picked in picks:
        row = hosyn_manifest[picked["image_id"]]
        clean = load_clean(resolve_source(row))
        degraded_input = synthetic.apply_degradation(clean, frozen_degradation(row["sha256"]))
        outputs = [arm.render(degraded_input) for arm in arms]
        caption = (f"{picked['image_id']} {'IDENTITY' if picked['identity'] == 'True' else 'degraded'}  input dE00 "
                   f"{float(picked['input_dE00_vs_clean']):.2f} -> model {float(picked[key]):.2f}")
        rows.append((caption, [clean, degraded_input] + [o.image for o in outputs]))
    sheet(rows, ["HO-SYN clean reference", "degraded input"] + headers_extra, os.path.join(out_dir, "hosyn.jpg"))
    print(f"sheets in {out_dir}")


if __name__ == "__main__":
    main()
