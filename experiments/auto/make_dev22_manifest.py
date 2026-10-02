"""Build eval/dev22_manifest.csv: the 22 M1 Unsplash photos as the DEV / regression set.

DEV-22 is NOT the frozen evaluation set the plan requires (that must be T1 phone captures), and it is never
used for training: Unsplash Terms section 8 prohibits ML training use (licensing.md). Sources are the golden
source.png files (EXIF-oriented, converted to 8-bit sRGB by lut3d/reference/make_golden.py).
"""
import csv
import os

from lightly_auto.manifest import file_sha256, manifest_hash, write_manifest
from lightly_auto.paths import AUTO_ROOT, LUT3D_ROOT, REPO_ROOT

M1_CATEGORY_TO_RUBRIC_CLASS = {
    "portrait_light": "portrait", "portrait_medium": "portrait", "portrait_deep": "portrait",
    "night": "night", "backlit": "backlit", "sunset": "sunset", "landscape": "landscape",
    "wellexposed": "already_good",
}

rows = []
with open(os.path.join(LUT3D_ROOT, "photos", "MANIFEST.csv"), newline="") as handle:
    for photo in csv.DictReader(handle):
        stem = os.path.splitext(photo["filename"])[0]
        source = os.path.join(LUT3D_ROOT, "golden", stem, "source.png")
        rows.append({
            "image_id": stem,
            "source_path": os.path.relpath(source, REPO_ROOT),
            "sha256": file_sha256(source),
            "rubric_class": M1_CATEGORY_TO_RUBRIC_CLASS[photo["category"]],
            # No Monk Skin Tone annotation exists for these photos; the M1 descriptor is kept in notes only.
            "skin_bucket": "",
            "labels": "",
            "split": "dev",
            "source_tier": "unsplash_dev",
            "contributor_id": photo["photographer"],
            "session_id": "",
            "device_brand": "",
            "device_model": "",
            "rights_doc_id": "Unsplash License (no ML training: Terms s.8)",
            "permitted_uses": "eval_dev_only",
            "notes": f"M1 category {photo['category']}; jpg sha256 {photo['sha256'][:16]}; {photo['notes']}",
        })
out = os.path.join(AUTO_ROOT, "eval", "dev22_manifest.csv")
write_manifest(out, rows)
print(f"{len(rows)} rows -> {out}\nmanifest hash {manifest_hash(rows)}")
