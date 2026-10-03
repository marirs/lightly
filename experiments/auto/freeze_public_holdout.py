"""Freeze a public held-out set: record its manifest hash, composition and the G0 frozen-set check result.

  python freeze_public_holdout.py manifests/ph1_manifest.csv manifests/ph1_provenance.csv manifests/ph1_FROZEN.json

Run once, BEFORE any training run that could be scored on the set. The record is committed; later scoring
runs compare the manifest hash against it (run_eval.py records the hash in every summary). The G0 check is
expected to FAIL (tier is not T1, skin buckets are unlabelled): the record says so explicitly, so PH-1 can
never be mistaken for the G0 frozen set.
"""
from __future__ import annotations

import csv
import json
import sys
import time
from collections import Counter

from lightly_auto.manifest import check_frozen_eval_set, file_sha256, load_manifest, manifest_hash
from lightly_auto.protocol import current_fingerprint, load_protocol


def problem_kind(problem: str) -> str:
    for marker, kind in (("is not frozen_eval", "split is public_holdout, not frozen_eval"),
                         ("is not T1", "source tier is not T1"), ("eval permission", "no eval permission"),
                         ("skin bucket", "skin-tone bucket share below 30% (buckets unlabelled)"),
                         ("images <", "class below 40 images"), ("duplicate", "duplicate")):
        if marker in problem:
            return kind
    return "other"


def main(manifest_path: str, provenance_path: str, out_path: str) -> None:
    rows = load_manifest(manifest_path)
    provenance = list(csv.DictReader(open(provenance_path)))
    report = check_frozen_eval_set(load_protocol(), rows, other_rows=[])
    record = {
        "set_id": "PH-1",
        "frozen_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "manifest": manifest_path, "manifest_rows_hash": manifest_hash(rows), "manifest_file_sha256": file_sha256(manifest_path),
        "provenance_file_sha256": file_sha256(provenance_path),
        "protocol": current_fingerprint(),
        "n_images": len(rows),
        "per_class": dict(Counter(r["rubric_class"] for r in rows)),
        "per_class_phone": dict(Counter(p["rubric_class"] for p in provenance if p["is_phone"] == "True")),
        "device_brands": dict(Counter(r["device_brand"] for r in rows).most_common()),
        "provisional_ita_buckets_portrait": dict(Counter(p["provisional_ita_bucket"] or "no face" for p in provenance
                                                         if p["rubric_class"] == "portrait")),
        "rules": ["frozen before any photo training run; never used for tuning, thresholds or checkpoint selection",
                  "retired and rebuilt if it is ever used for a decision",
                  "not the G0 frozen set: source tier is third-party CC0/PD, not T1; skin buckets unlabelled"],
        "g0_frozen_set_check": {"passes": report.passes_g0, "problem_summary": dict(Counter(problem_kind(p) for p in report.problems)),
                                "first_problems": report.problems[:8], "bucket_shares": report.bucket_shares},
    }
    json.dump(record, open(out_path, "w"), indent=2)
    print(json.dumps({k: record[k] for k in ("manifest_rows_hash", "n_images", "per_class", "per_class_phone")}, indent=1))
    print("G0 check passes:", report.passes_g0, "problems:", len(report.problems))


if __name__ == "__main__":
    main(*sys.argv[1:4])
