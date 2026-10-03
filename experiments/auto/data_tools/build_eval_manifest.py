"""Build the public held-out evaluation set PH-1 from reviewed Commons selections.

  python -m data_tools.build_eval_manifest --selection manifests/ph1_selection.json --set-id ph1

For every selected file:
  1. download the ORIGINAL upload once, verify Commons' sha1, record its sha256;
  2. derive the analysis proxy exactly once: EXIF orientation applied, embedded ICC profile converted to sRGB
     (phone JPEGs are often Display P3), LANCZOS to 2048 px long edge (protocol analysis_resolution), saved
     as lossless PNG. The runner then reads the proxy (already at 2048, so it is not resized again);
  3. write manifest rows (lightly_auto.manifest schema) pointing at the proxy and a provenance CSV with the
     source URL, licence, author and both hashes.

Labels: rubric_class is the reviewer's class (checked by eye on contact sheets, not the search query).
skin_bucket is left EMPTY: the protocol requires two human annotators plus self-identification where
offered. A provisional, automatic ITA-based bucket is written to the provenance CSV only, for coverage
planning; it is never used for gating.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os

import numpy as np
from PIL import Image, ImageCms, ImageOps

from data_tools.commons import download
from data_tools.fetch_review_pool import original_path as review_original_path
from lightly_auto.manifest import file_sha256, manifest_hash, write_manifest

AUTO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(os.path.dirname(AUTO_ROOT))
LONG_EDGE = 2048
SOURCE_TIER = "T2_public_cc0_pd"  # third-party CC0 / public domain; NOT T1, so never a G0 frozen set
PROVENANCE_COLUMNS = ["image_id", "rubric_class", "commons_page", "original_url", "licence", "licence_url", "author",
                      "original_sha1", "original_sha256", "original_bytes", "proxy_sha256", "device_brand", "device_model",
                      "capture_datetime", "personality_rights_flag", "faces_detected", "provisional_ita_deg",
                      "provisional_ita_bucket"]


def to_srgb_upright(path: str) -> Image.Image:
    image = Image.open(path)
    image = ImageOps.exif_transpose(image)
    icc = image.info.get("icc_profile")
    image = image.convert("RGB")
    if icc:
        try:
            source_profile = ImageCms.ImageCmsProfile(io.BytesIO(icc))
            image = ImageCms.profileToProfile(image, source_profile, ImageCms.createProfile("sRGB"),
                                              renderingIntent=ImageCms.Intent.PERCEPTUAL, outputMode="RGB")
        except Exception:  # noqa: BLE001 - a broken profile falls back to treating pixels as sRGB, noted by caller
            pass
    return image


def make_proxy(original_path: str, proxy_path: str) -> None:
    image = to_srgb_upright(original_path)
    scale = LONG_EDGE / max(image.size)
    if scale < 1.0:
        image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    os.makedirs(os.path.dirname(proxy_path), exist_ok=True)
    image.save(proxy_path, optimize=False, compress_level=6)


def provisional_ita(proxy_rgb8: np.ndarray, face_boxes: list) -> float | None:
    """Individual Typology Angle of the central 40% of the largest face box. ITA mixes skin tone with scene
    lighting, so this is a coverage-planning proxy only, never an MST label."""
    if not face_boxes:
        return None
    from skimage import color
    height, width = proxy_rgb8.shape[:2]
    x, y, w, h = max(face_boxes, key=lambda b: b[2] * b[3])
    x0, x1 = int((x + 0.3 * w) * width), int((x + 0.7 * w) * width)
    y0, y1 = int((y + 0.3 * h) * height), int((y + 0.7 * h) * height)
    patch = proxy_rgb8[max(y0, 0):max(y1, 1), max(x0, 0):max(x1, 1)]
    if patch.size < 30:
        return None
    lab = color.rgb2lab(patch).reshape(-1, 3)
    lightness, b_star = np.median(lab[:, 0]), np.median(lab[:, 2])
    return float(np.degrees(np.arctan2(lightness - 50.0, b_star)))


def ita_bucket(ita: float | None) -> str:
    # Chardon ITA categories collapsed onto the protocol's three MST groups (approximate correspondence):
    # very light/light (> 41) ~ MST 1-3, intermediate/tan (10..41) ~ MST 4-7, brown/dark (< 10) ~ MST 8-10.
    if ita is None:
        return ""
    return "MST 1-3 (prov.)" if ita > 41 else ("MST 4-7 (prov.)" if ita >= 10 else "MST 8-10 (prov.)")


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--selection", required=True)
    parser.add_argument("--candidates", default="data/commons/candidates.json")
    parser.add_argument("--set-id", default="ph1")
    parser.add_argument("--faces", default=None, help="faces.json for the proxies (second pass, after detection)")
    args = parser.parse_args(argv)
    candidates = {r["sha1"]: r for r in json.load(open(os.path.join(AUTO_ROOT, args.candidates)))}
    selection = json.load(open(os.path.join(AUTO_ROOT, args.selection)))
    faces = json.load(open(os.path.join(AUTO_ROOT, args.faces))) if args.faces else {}
    data_dir = os.path.join(AUTO_ROOT, "data", args.set_id)
    rows, provenance = [], []
    for index, item in enumerate(sorted(selection, key=lambda s: (s["rubric_class"], s["sha1"]))):
        record = candidates[item["sha1"]]
        original_path = review_original_path(record)  # shared with the review pool, fetched once
        original_sha256 = download(record["url"], original_path, record["sha1"])
        image_id = f"{args.set_id}_{item['rubric_class']}_{record['sha1'][:10]}"
        proxy_path = os.path.join(data_dir, "proxy", image_id + ".png")
        if not os.path.exists(proxy_path):
            make_proxy(original_path, proxy_path)
        proxy_sha256 = file_sha256(proxy_path)
        from data_tools.commons import phone_brand
        brand = phone_brand(record["make"], record["model"]) or record["make"]
        boxes = faces.get(image_id, [])
        ita = provisional_ita(np.asarray(Image.open(proxy_path).convert("RGB")), boxes) if boxes else None
        rows.append({
            "image_id": image_id, "source_path": os.path.relpath(proxy_path, REPO_ROOT), "sha256": proxy_sha256,
            "rubric_class": item["rubric_class"], "skin_bucket": "", "labels": ";".join(item.get("labels", [])),
            "split": "public_holdout", "source_tier": SOURCE_TIER, "contributor_id": "commons:" + record["artist"][:80],
            "session_id": (record["datetime_original"] or "")[:10], "device_brand": brand, "device_model": record["model"],
            "rights_doc_id": record["descriptionurl"], "permitted_uses": "eval",
            "notes": f"{record['licence_short']}; original sha256 {original_sha256}"})
        provenance.append({
            "image_id": image_id, "rubric_class": item["rubric_class"], "commons_page": record["descriptionurl"],
            "original_url": record["url"], "licence": record["licence_short"], "licence_url": record["licence_url"],
            "author": record["artist"][:120], "original_sha1": record["sha1"], "original_sha256": original_sha256,
            "original_bytes": record["bytes"], "proxy_sha256": proxy_sha256, "device_brand": brand,
            "device_model": record["model"], "capture_datetime": record["datetime_original"],
            "personality_rights_flag": "yes" if "ersonality" in (record.get("restrictions") or "") else "",
            "faces_detected": len(boxes) if args.faces else "", "provisional_ita_deg": "" if ita is None else round(ita, 1),
            "provisional_ita_bucket": ita_bucket(ita)})
        print(f"[{index + 1}/{len(selection)}] {image_id}", flush=True)
    manifests_dir = os.path.join(AUTO_ROOT, "manifests")
    os.makedirs(manifests_dir, exist_ok=True)
    write_manifest(os.path.join(manifests_dir, f"{args.set_id}_manifest.csv"), rows)
    with open(os.path.join(manifests_dir, f"{args.set_id}_provenance.csv"), "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=PROVENANCE_COLUMNS)
        writer.writeheader()
        writer.writerows(provenance)
    with open(os.path.join(data_dir, "face_list.tsv"), "w") as handle:
        for row in rows:
            handle.write(f"{row['image_id']}\t{os.path.join(REPO_ROOT, row['source_path'])}\n")
    print("manifest hash", manifest_hash(rows), "rows", len(rows))


if __name__ == "__main__":
    main()
