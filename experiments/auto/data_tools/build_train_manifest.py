"""Build the CC0/PD reference-photo manifests for self-supervised training (stage (a) on real photos).

  python -m data_tools.build_train_manifest --exclude-provenance manifests/ph1_provenance.csv

Splits are by PHOTOGRAPHER (Commons Artist field), so no photographer straddles splits (plan section 3.4):
  sha256(artist) mod 100 in [0, 80)  -> train          (permitted_uses train;eval)
                          [80, 90)  -> validation     (tuning and checkpoint selection only)
                          [90, 100) -> public_holdout_syn  (frozen synthetic-degradation held-out set,
                                                            capped at --holdout-cap images; never tunes)
Every photographer who appears in an evaluation provenance file (PH-1) is dropped entirely, and every kept
file is pHash-checked against PH-1 and DEV-22 (Hamming <= 6 is a near duplicate and is dropped).

The files used are Commons' 960 px upright thumbnails; their own sha256 is recorded next to the original
upload's sha1, so the manifest pins the exact bytes trained on.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os

import numpy as np
from PIL import Image

from data_tools.commons import download
from lightly_auto.manifest import dct_phash, hamming_distance, load_manifest, manifest_hash, write_manifest

AUTO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(os.path.dirname(AUTO_ROOT))
SOURCE_TIER = "T2_public_cc0_pd"
PROVENANCE_COLUMNS = ["image_id", "split", "commons_page", "thumb_url", "original_url", "licence", "licence_url", "author",
                      "original_sha1", "file_sha256", "camera_make", "camera_model", "personality_rights_flag", "phash"]


def split_for(artist: str) -> str:
    bucket = int(hashlib.sha256(artist.strip().lower().encode()).hexdigest(), 16) % 100
    return "train" if bucket < 80 else ("validation" if bucket < 90 else "public_holdout_syn")


def phash_file(path: str) -> int:
    return dct_phash(np.asarray(Image.open(path).convert("RGB")))


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidates", default="data/commons/train_candidates.json")
    parser.add_argument("--exclude-provenance", action="append", default=[])
    parser.add_argument("--dev-manifest", default="eval/dev22_manifest.csv")
    parser.add_argument("--holdout-cap", type=int, default=240)
    parser.add_argument("--set-id", default="cc0ref")
    args = parser.parse_args(argv)
    records = json.load(open(os.path.join(AUTO_ROOT, args.candidates)))
    records.sort(key=lambda r: r["sha1"])

    excluded_artists, excluded_sha1, eval_phashes = set(), set(), {}
    for provenance_path in args.exclude_provenance:
        for row in csv.DictReader(open(os.path.join(AUTO_ROOT, provenance_path))):
            excluded_artists.add(row["author"].strip().lower())
            excluded_sha1.add(row["original_sha1"])
    for provenance_path in args.exclude_provenance:
        manifest_path = provenance_path.replace("_provenance.csv", "_manifest.csv")
        for row in load_manifest(os.path.join(AUTO_ROOT, manifest_path)):
            eval_phashes[row["image_id"]] = phash_file(os.path.join(REPO_ROOT, row["source_path"]))
    for row in load_manifest(os.path.join(AUTO_ROOT, args.dev_manifest)):
        path = os.path.join(REPO_ROOT, row["source_path"])
        if os.path.exists(path):
            eval_phashes[row["image_id"]] = phash_file(path)

    data_dir = os.path.join(AUTO_ROOT, "data", args.set_id)
    rows, provenance, dropped = [], [], {"eval_photographer": 0, "eval_file": 0, "near_duplicate": 0, "download": 0}
    holdout_count = 0
    for index, record in enumerate(records):
        artist = (record.get("artist") or "unknown").strip()
        if artist.lower() in excluded_artists:
            dropped["eval_photographer"] += 1
            continue
        if record["sha1"] in excluded_sha1:
            dropped["eval_file"] += 1
            continue
        split = split_for(artist)
        if split == "public_holdout_syn":
            if holdout_count >= args.holdout_cap:
                continue  # photographer stays out of train/validation either way
            holdout_count += 1
        path = os.path.join(data_dir, "thumbs960", record["sha1"] + ".jpg")
        try:
            file_sha256 = download(record["thumburl"], path, None)
        except Exception as error:  # noqa: BLE001 - one failed thumbnail must not stop the build
            dropped["download"] += 1
            print("download failed", record["title"], error)
            continue
        phash = phash_file(path)
        duplicate_of = next((k for k, v in eval_phashes.items() if hamming_distance(v, phash) <= 6), None)
        if duplicate_of:
            dropped["near_duplicate"] += 1
            print("near duplicate of", duplicate_of, record["title"])
            continue
        image_id = f"{args.set_id}_{record['sha1'][:12]}"
        rows.append({
            "image_id": image_id, "source_path": os.path.relpath(path, REPO_ROOT), "sha256": file_sha256,
            "rubric_class": "", "skin_bucket": "", "labels": "", "split": split, "source_tier": SOURCE_TIER,
            "contributor_id": "commons:" + artist[:80], "session_id": "", "device_brand": record.get("make", ""),
            "device_model": record.get("model", ""), "rights_doc_id": record["descriptionurl"],
            "permitted_uses": "eval" if split == "public_holdout_syn" else "train;eval",
            "notes": record["licence_short"]})
        provenance.append({
            "image_id": image_id, "split": split, "commons_page": record["descriptionurl"], "thumb_url": record["thumburl"],
            "original_url": record["url"], "licence": record["licence_short"], "licence_url": record["licence_url"],
            "author": artist[:120], "original_sha1": record["sha1"], "file_sha256": file_sha256,
            "camera_make": record.get("make", ""), "camera_model": record.get("model", ""),
            "personality_rights_flag": "yes" if "ersonality" in (record.get("restrictions") or "") else "",
            "phash": f"{phash:016x}"})
        if (index + 1) % 100 == 0:
            print(f"[{index + 1}/{len(records)}] kept {len(rows)}", flush=True)
    manifests_dir = os.path.join(AUTO_ROOT, "manifests")
    os.makedirs(manifests_dir, exist_ok=True)
    write_manifest(os.path.join(manifests_dir, f"{args.set_id}_manifest.csv"), rows)
    with open(os.path.join(manifests_dir, f"{args.set_id}_provenance.csv"), "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=PROVENANCE_COLUMNS)
        writer.writeheader()
        writer.writerows(provenance)
    counts = {s: sum(1 for r in rows if r["split"] == s) for s in ("train", "validation", "public_holdout_syn")}
    print("counts", counts, "dropped", dropped, "manifest hash", manifest_hash(rows))


if __name__ == "__main__":
    main()
