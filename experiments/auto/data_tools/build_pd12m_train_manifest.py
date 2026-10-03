"""Training / validation / held-out-synthetic manifests for the PD12M CC0 reference photos (CC0REF).

  python -m data_tools.build_pd12m_train_manifest --exclude manifests/ph1_manifest.csv --exclude-provenance manifests/ph1_provenance.csv

Separation (plan section 3.4), all enforced here and recorded:
  * shards: references come from PD12M shards 012-024, PH-1 from 000-011;
  * capture session: split groups are camera model + capture date (data_tools.pd12m.session_key); every
    session that also appears in PH-1 (device model + date from its provenance) is dropped;
  * near duplicates: 64-bit DCT pHash Hamming <= 6 against every PH-1 proxy and every DEV-22 photo drops
    the reference.
PD12M rows carry no photographer field, so photographer-disjointness between CC0REF splits cannot be proven;
session grouping is the available proxy (stated in the manifest notes and in docs/m3/auto-progress.md).
Split rule: sha256(session key) mod 100 -> [0, 80) train, [80, 90) validation, [90, 100) public_holdout_syn
(capped at --holdout-cap images; the held-out set is frozen before any photo training run).
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os

import numpy as np
from PIL import Image

from lightly_auto.manifest import dct_phash, file_sha256, hamming_distance, load_manifest, manifest_hash, write_manifest

AUTO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(os.path.dirname(AUTO_ROOT))
SOURCE_TIER = "T2_public_cc0_pd"
PROVENANCE_COLUMNS = ["image_id", "split", "pd12m_id", "pd12m_url", "source", "licence", "original_md5", "file_sha256",
                      "camera_make", "camera_model", "session_key", "phash", "caption"]


def split_for(session: str) -> str:
    bucket = int(hashlib.sha256(session.encode()).hexdigest(), 16) % 100
    return "train" if bucket < 80 else ("validation" if bucket < 90 else "public_holdout_syn")


def phash_of(path: str) -> int:
    return dct_phash(np.asarray(Image.open(path).convert("RGB")))


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--refs", default="data/pd12m/train_refs.json")
    parser.add_argument("--exclude", action="append", default=[], help="evaluation manifests (pHash exclusion)")
    parser.add_argument("--exclude-provenance", action="append", default=[], help="eval provenance (session exclusion)")
    parser.add_argument("--dev-manifest", default="eval/dev22_manifest.csv")
    parser.add_argument("--holdout-cap", type=int, default=300)
    parser.add_argument("--set-id", default="cc0ref")
    args = parser.parse_args(argv)
    refs = sorted((r for r in json.load(open(os.path.join(AUTO_ROOT, args.refs))) if r.get("kept")), key=lambda r: r["id"])

    eval_phashes = {}
    for manifest_path in args.exclude + [args.dev_manifest]:
        for row in load_manifest(os.path.join(AUTO_ROOT, manifest_path)):
            path = os.path.join(REPO_ROOT, row["source_path"])
            if os.path.exists(path):
                eval_phashes[row["image_id"]] = phash_of(path)
    eval_sessions = set()
    for provenance_path in args.exclude_provenance:
        for row in csv.DictReader(open(os.path.join(AUTO_ROOT, provenance_path))):
            if row["device_model"] and row["capture_datetime"]:
                eval_sessions.add((row["device_model"].lower(), row["capture_datetime"][:10]))

    rows, provenance = [], []
    dropped = {"eval_session": 0, "near_duplicate": 0}
    holdout = 0
    for ref in refs:
        session = ref.get("session") or ("id:" + ref["id"])
        exif = ref.get("exif") or {}
        if exif.get("model") and (exif["model"].lower(), (exif.get("datetime_original") or "")[:10]) in eval_sessions:
            dropped["eval_session"] += 1
            continue
        path = os.path.join(AUTO_ROOT, "data", "pd12m", "train_refs", ref["id"] + ".jpg")
        phash = phash_of(path)
        if any(hamming_distance(phash, other) <= 6 for other in eval_phashes.values()):
            dropped["near_duplicate"] += 1
            continue
        split = split_for(session)
        if split == "public_holdout_syn":
            if holdout >= args.holdout_cap:
                continue  # its session stays out of train/validation either way
            holdout += 1
        image_id = f"{args.set_id}_{ref['id'][:16]}"
        digest = file_sha256(path)
        rows.append({
            "image_id": image_id, "source_path": os.path.relpath(path, REPO_ROOT), "sha256": digest, "rubric_class": "",
            "skin_bucket": "", "labels": "", "split": split, "source_tier": SOURCE_TIER,
            "contributor_id": "pd12m-session:" + hashlib.sha256(session.encode()).hexdigest()[:16],
            "session_id": session if not session.startswith("id:") else "", "device_brand": exif.get("make", ""),
            "device_model": exif.get("model", ""), "rights_doc_id": ref["url"] + " (PD12M row licence CC0 1.0)",
            "permitted_uses": "eval" if split == "public_holdout_syn" else "train;eval",
            "notes": f"PD12M {ref['source']}; derived 640px q95 from md5 {ref['hash']}"})
        provenance.append({
            "image_id": image_id, "split": split, "pd12m_id": ref["id"], "pd12m_url": ref["url"], "source": ref["source"],
            "licence": ref["license"], "original_md5": ref["hash"], "file_sha256": digest, "camera_make": exif.get("make", ""),
            "camera_model": exif.get("model", ""), "session_key": session, "phash": f"{phash:016x}",
            "caption": (ref.get("caption") or "")[:160]})
    manifests_dir = os.path.join(AUTO_ROOT, "manifests")
    write_manifest(os.path.join(manifests_dir, f"{args.set_id}_manifest.csv"), rows)
    with open(os.path.join(manifests_dir, f"{args.set_id}_provenance.csv"), "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=PROVENANCE_COLUMNS)
        writer.writeheader()
        writer.writerows(provenance)
    counts = {s: sum(1 for r in rows if r["split"] == s) for s in ("train", "validation", "public_holdout_syn")}
    print("counts", counts, "dropped", dropped, "rows hash", manifest_hash(rows))


if __name__ == "__main__":
    main()
