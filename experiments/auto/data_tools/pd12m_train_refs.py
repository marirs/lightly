"""Download CC0 reference photos for self-supervised training from PD12M (training shards 012-024 only;
PH-1 evaluation candidates come from shards 000-011).

  python -m data_tools.pd12m_train_refs --count 4000

Sources: Wikimedia Commons and iNaturalist rows with a CC0 licence (PDM rows skipped). Commons rows must
carry camera EXIF (Make), which excludes scans, artwork reproductions and historical prints; iNaturalist
observations are photographs by construction, so EXIF is recorded when present but not required.
Each file is md5-verified against PD12M, downscaled to 640 px long edge (training runs at 320 px) and saved as
JPEG q95; the derived file's sha256 is what the training manifest pins. Simple quality screens drop
near-monochrome frames and frames with more than 10% clipped pixels: these are clean TARGETS, so obviously
broken photos would teach the wrong thing.
Output: data/pd12m/train_refs/<id>.jpg and data/pd12m/train_refs.json (row, EXIF, session key, stats).
"""
from __future__ import annotations

import argparse
import io
import json
import os
import random
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from PIL import Image, ImageOps
from skimage import color

from data_tools.pd12m import NOT_A_PHOTO, PD12M_DIR, S3_WORKERS, _session, header_exif, load_rows, session_key

TRAIN_SHARDS = list(range(12, 25))
REFERENCE_LONG_EDGE = 640


def screen(rgb8: np.ndarray) -> tuple[bool, dict]:
    small = np.asarray(Image.fromarray(rgb8).resize((128, 128)))
    lab = color.rgb2lab(small)
    chroma = float(np.hypot(lab[..., 1], lab[..., 2]).mean())
    clipped = float(((small.max(-1) >= 254) | (small.max(-1) <= 1)).mean())
    stats = {"mean_L": round(float(lab[..., 0].mean()), 2), "mean_chroma": round(chroma, 2), "clipped_share": round(clipped, 4)}
    return chroma >= 4.0 and clipped <= 0.10, stats


def fetch_reference(row: dict, session) -> dict:
    out_path = os.path.join(PD12M_DIR, "train_refs", row["id"] + ".jpg")
    if os.path.exists(out_path):
        return {**row, "path": out_path, "kept": True}
    exif = header_exif(row, session)
    if row["source"] == "Wikimedia Commons" and not exif.get("make"):
        return {**row, "kept": False, "why": "no camera EXIF"}
    import hashlib
    try:
        response = session.get(row["url"], timeout=120)
        response.raise_for_status()
    except Exception as error:  # noqa: BLE001
        return {**row, "kept": False, "why": f"download {error!r}"[:120]}
    if hashlib.md5(response.content).hexdigest() != row["hash"]:
        return {**row, "kept": False, "why": "md5 mismatch"}
    try:
        image = ImageOps.exif_transpose(Image.open(io.BytesIO(response.content))).convert("RGB")
    except Exception:  # noqa: BLE001
        return {**row, "kept": False, "why": "decode"}
    image.thumbnail((REFERENCE_LONG_EDGE, REFERENCE_LONG_EDGE), Image.LANCZOS)
    rgb8 = np.asarray(image)
    ok, stats = screen(rgb8)
    if not ok:
        return {**row, "kept": False, "why": "screen", "stats": stats}
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    image.save(out_path, quality=95)
    return {**row, "path": out_path, "kept": True, "exif": exif, "session": session_key(row, exif), "stats": stats}


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=4000, help="rows to try (kept count is lower after screens)")
    parser.add_argument("--inat-share", type=float, default=0.3)
    args = parser.parse_args(argv)
    rows = [r for r in load_rows(TRAIN_SHARDS, ("Wikimedia Commons", "iNaturalist"))
            if not NOT_A_PHOTO.search(r["caption"] or "") and min(r["width"], r["height"]) >= 800]
    rng = random.Random(20261003)
    commons = sorted((r for r in rows if r["source"] == "Wikimedia Commons"), key=lambda r: r["id"])
    inat = sorted((r for r in rows if r["source"] == "iNaturalist"), key=lambda r: r["id"])
    rng.shuffle(commons)
    rng.shuffle(inat)
    n_inat = int(args.count * args.inat_share)
    chosen = commons[:args.count - n_inat] + inat[:n_inat]
    print("rows available", len(commons), "commons", len(inat), "inat; trying", len(chosen), flush=True)
    session = _session()
    results = []
    with ThreadPoolExecutor(max_workers=S3_WORKERS) as pool:
        for index, result in enumerate(pool.map(lambda r: fetch_reference(r, session), chosen)):
            results.append(result)
            if (index + 1) % 250 == 0:
                print(f"[{index + 1}/{len(chosen)}] kept {sum(r['kept'] for r in results)}", flush=True)
    json.dump(results, open(os.path.join(PD12M_DIR, "train_refs.json"), "w"), indent=1)
    print("kept", sum(r["kept"] for r in results), "of", len(results))


if __name__ == "__main__":
    main()
