"""Enhance step 1f: training images for the photo-or-art classifier (owner approved, 2026-11-13).

Same source and rules as fetch_art_test_set.py (The Met Open Access, public domain only), saved to art-train/, never
any object in the test set (art-test/SOURCES.csv), so the test numbers stay honest. Images are git-ignored.
Run: .venv/bin/python -I fetch_art_train_set.py
"""
import csv
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # run with -I (downloads are untrusted), which drops the script's folder from the path
import fetch_art_test_set as met  # noqa: E402
# (class, department, query, how many). Departments: 1 American Wing, 6 Asian Art, 9 Drawings and Prints,
# 11 European Paintings, 19 Photographs.
SETS = [
    ("painting", 11, "portrait", 120), ("painting", 11, "woman", 60), ("painting", 11, "man", 60),
    ("painting", 11, "child", 30), ("painting", 1, "portrait", 60), ("painting", 1, "miniature", 30),
    ("painting", 6, "portrait", 20),
    ("drawing", 9, "portrait", 90), ("drawing", 9, "head", 50), ("drawing", 9, "engraving portrait", 40),
    ("photo", 19, "portrait", 120), ("photo", 19, "woman", 80), ("photo", 19, "man", 80), ("photo", 19, "child", 50),
    ("photo", 19, "ambrotype", 40), ("photo", 19, "daguerreotype", 40), ("photo", 19, "tintype", 40),
    ("photo", 19, "carte de visite", 40), ("photo", 19, "cabinet card", 40), ("photo", 19, "group", 40),
]

if __name__ == "__main__":
    test_ids = frozenset(int(row[1]) for row in csv.reader((HERE / "art-test" / "SOURCES.csv").open()) if row)
    met.main(out=HERE / "art-train", sets=SETS, exclude=test_ids, offsets=(0, 200, 400))
