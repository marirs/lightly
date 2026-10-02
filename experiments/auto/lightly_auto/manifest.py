"""Evaluation/training manifests: integrity hashes, near-duplicate detection, and the G0 frozen-set checks.

Manifest CSV columns (one row per image):
  image_id, source_path (relative to the repo root), sha256, rubric_class, skin_bucket (MST 1-3 | MST 4-7 |
  MST 8-10 | empty), labels (';'-separated flags, e.g. face_underexposed), split (frozen_eval | validation |
  train | dev), source_tier (T1..T4 | unsplash_dev), contributor_id, session_id, device_brand, device_model,
  rights_doc_id, permitted_uses (';'-separated: train, eval, marketing), notes
"""
from __future__ import annotations

import csv
import hashlib
import os
from dataclasses import dataclass

import numpy as np
from PIL import Image
from scipy.fft import dctn

from .paths import REPO_ROOT

MANIFEST_COLUMNS = ["image_id", "source_path", "sha256", "rubric_class", "skin_bucket", "labels", "split",
                    "source_tier", "contributor_id", "session_id", "device_brand", "device_model",
                    "rights_doc_id", "permitted_uses", "notes"]
PHASH_NEAR_DUPLICATE_MAX_HAMMING = 6


def file_sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(path: str) -> list[dict]:
    with open(path, newline="") as handle:
        rows = list(csv.DictReader(handle))
    for row in rows:
        missing = [c for c in MANIFEST_COLUMNS if c not in row]
        if missing:
            raise ValueError(f"{path}: row {row.get('image_id')} lacks columns {missing}")
        row["labels_dict"] = {flag: True for flag in row["labels"].split(";") if flag}
        row["permitted_uses_set"] = {use for use in row["permitted_uses"].split(";") if use}
    return rows


def write_manifest(path: str, rows: list[dict]) -> None:
    with open(path, "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=MANIFEST_COLUMNS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def manifest_hash(rows: list[dict]) -> str:
    """Order-independent hash of identity-relevant fields. Labels and class are included because changing
    them changes what the protocol scores."""
    lines = sorted(f"{r['image_id']}|{r['sha256']}|{r['rubric_class']}|{r['skin_bucket']}|{r['labels']}|{r['split']}"
                   for r in rows)
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()


def resolve_source(row: dict) -> str:
    return os.path.join(REPO_ROOT, row["source_path"])


def verify_integrity(rows: list[dict]) -> list[str]:
    problems = []
    for row in rows:
        path = resolve_source(row)
        if not os.path.exists(path):
            problems.append(f"{row['image_id']}: missing file {row['source_path']}")
        elif file_sha256(path) != row["sha256"]:
            problems.append(f"{row['image_id']}: sha256 mismatch")
    return problems


def dct_phash(rgb8: np.ndarray) -> int:
    """64-bit perceptual hash: 32x32 grey, 2-D DCT, top-left 8x8 (minus DC) against its median."""
    grey = Image.fromarray(rgb8).convert("L").resize((32, 32), Image.LANCZOS)
    coefficients = dctn(np.asarray(grey, dtype=np.float64), norm="ortho")[:8, :8].flatten()
    ac = coefficients[1:]
    bits = np.concatenate([[False], ac > np.median(ac)])
    return int("".join("1" if b else "0" for b in bits), 2)


def hamming_distance(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


class TrainingRightsError(RuntimeError):
    pass


# Tiers that may never train, whatever a row's permitted_uses says. unsplash_dev: Unsplash Terms s.8.
NEVER_TRAIN_TIERS = {"unsplash_dev", "fivek_research"}


def assert_training_rights(rows: list[dict]) -> None:
    """Plan section 3.3: a training run fails if any input lacks a documented 'train' permission, or comes
    from the frozen eval split (leakage), or from a tier that can never train."""
    problems = []
    for row in rows:
        if row["source_tier"] in NEVER_TRAIN_TIERS:
            problems.append(f"{row['image_id']}: tier {row['source_tier']} may never be used for training")
        elif "train" not in row["permitted_uses_set"] or not row["rights_doc_id"]:
            problems.append(f"{row['image_id']}: no documented train permission")
        if row["split"] == "frozen_eval":
            problems.append(f"{row['image_id']}: belongs to the frozen eval set")
    if problems:
        raise TrainingRightsError("training refused:\n" + "\n".join(problems))


@dataclass
class FrozenSetReport:
    passes_g0: bool
    problems: list
    counts_per_class: dict
    bucket_shares: dict


def check_frozen_eval_set(protocol: dict, eval_rows: list[dict], other_rows: list[dict],
                          phashes: dict | None = None) -> FrozenSetReport:
    """G0 data checks from PROTOCOL.json frozen_eval_set_requirements_G0. phashes: image_id -> int, for the
    near-duplicate check (computed by the caller so tests can inject them)."""
    requirements = protocol["frozen_eval_set_requirements_G0"]
    problems: list[str] = []
    gated_classes = [name for name, entry in protocol["criteria"].items()
                     if name != "skin" and (entry.get("gated") or entry.get("requires_skin"))]
    counts = {c: sum(1 for r in eval_rows if r["rubric_class"] == c) for c in gated_classes}
    for rubric_class, count in counts.items():
        if count < requirements["min_images_per_gated_class"]:
            problems.append(f"class {rubric_class}: {count} images < {requirements['min_images_per_gated_class']}")
    skin_rows = [r for r in eval_rows if r["rubric_class"] in ("portrait", "backlit")]
    bucket_shares = {}
    for bucket in requirements["skin_tone_buckets"]:
        share = (sum(1 for r in skin_rows if r["skin_bucket"] == bucket) / len(skin_rows)) if skin_rows else 0.0
        bucket_shares[bucket] = share
        if share < requirements["min_bucket_share_of_portrait_plus_backlit"]:
            problems.append(f"skin bucket {bucket}: share {share:.2f} < {requirements['min_bucket_share_of_portrait_plus_backlit']}")
    for row in eval_rows:
        if row["split"] != "frozen_eval":
            problems.append(f"{row['image_id']}: split {row['split']!r} is not frozen_eval")
        if row["source_tier"] != "T1":
            problems.append(f"{row['image_id']}: source tier {row['source_tier']!r} is not T1")
        if "eval" not in row["permitted_uses_set"] or not row["rights_doc_id"]:
            problems.append(f"{row['image_id']}: no documented eval permission")
    other_hashes = {r["sha256"]: r["image_id"] for r in other_rows}
    for row in eval_rows:
        if row["sha256"] in other_hashes:
            problems.append(f"{row['image_id']}: exact duplicate of {other_hashes[row['sha256']]} in another split")
    if phashes:
        other_ids = [r["image_id"] for r in other_rows if r["image_id"] in phashes]
        for row in eval_rows:
            if row["image_id"] not in phashes:
                continue
            for other_id in other_ids:
                if hamming_distance(phashes[row["image_id"]], phashes[other_id]) <= PHASH_NEAR_DUPLICATE_MAX_HAMMING:
                    problems.append(f"{row['image_id']}: near duplicate of {other_id} (pHash)")
    return FrozenSetReport(not problems, problems, counts, bucket_shares)
