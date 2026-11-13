"""Enhance step 1f: phone classifier scores against PyTorch (export_art_classifier.py reference.csv).
Run: .venv/bin/python -I compare_art_phones.py"""
import csv
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ART = HERE / "outputs" / "art"
THRESHOLD = 0.8

reference = {row["name"]: row for row in csv.DictReader((ART / "phone-views" / "reference.csv").open())}
runs = {"A069 (TFLite, CPU fp32)": (ART / "android-results.csv", "score", "ms")}
for phone, label in (("se3", "iPhone SE 3"), ("11pm", "iPhone 11 Pro Max")):
    runs[f"{label} (Core ML, CPU only)"] = (ART / f"ios-{phone}-results.csv", "cpu_only", None)
    runs[f"{label} (Core ML, all units)"] = (ART / f"ios-{phone}-results.csv", "all_units", "ms")
for title, (path, column, time_column) in runs.items():
    rows = list(csv.DictReader(path.open()))
    differences = [abs(float(row[column]) - float(reference[row["name"]]["pytorch"])) for row in rows]
    flips = [row["name"] for row in rows
             if (float(row[column]) >= THRESHOLD) != (float(reference[row["name"]]["pytorch"]) >= THRESHOLD)]
    art = [row for row in rows if reference[row["name"]]["art"] == "1"]
    photo = [row for row in rows if reference[row["name"]]["art"] == "0"]
    timing = f", median {np.median([float(row[time_column]) for row in rows]):.0f} ms" if time_column else ""
    print(f"{title}: {len(rows)} images, max |score - PyTorch| {max(differences):.2e}, decisions changed {len(flips)} "
          f"{flips}; art caught {sum(float(r[column]) >= THRESHOLD for r in art)}/{len(art)}, photos skipped "
          f"{sum(float(r[column]) >= THRESHOLD for r in photo)}/{len(photo)}{timing}")
