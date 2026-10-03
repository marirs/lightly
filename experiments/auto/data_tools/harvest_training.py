"""Harvest well-exposed CC0 / public-domain reference photos for self-supervised training (plan stage (a), T3
built on a CC0 source).

  python -m data_tools.harvest_training

Source: Wikimedia Commons "Quality images" (community-reviewed for exposure, colour and sharpness), CC0 or
public domain, any camera, excluding stock-site imports and post-processed files we can detect. These are the
"clean" targets; the degradation sampler makes the inputs. Post-processed files are allowed here (a finished
photo is a fine target), unlike evaluation inputs, which must be unedited captures. Thumbnails (960 px wide, upright, as Commons
renders them) are enough: training runs at <= 512 px.

Separation from evaluation (plan section 3.4): every photographer (Artist field) who appears in an
evaluation manifest is excluded here, and every kept file is checked against the evaluation pHashes later
by data_tools/build_train_manifest.py.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
from collections import Counter

from data_tools.commons import CC0_OR_PD_QUERY, eligible, search

AUTO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRAIN_QUERIES = ["incategory:Quality_images", "incategory:Featured_pictures_on_Wikimedia_Commons",
                 "incategory:Valued_images_by_subject"]


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--per-query", type=int, default=2500)
    parser.add_argument("--out", default="data/commons/train_candidates.json")
    args = parser.parse_args(argv)
    cache = os.path.join(AUTO_ROOT, "data", "commons", "search_cache")
    kept, rejections = {}, Counter()
    for term in TRAIN_QUERIES:
        for query in (f"{CC0_OR_PD_QUERY} filetype:bitmap {term}",):
            for record in search(query, args.per_query, cache, thumb_width=960):
                ok, why = eligible(record, require_phone=False, allow_edited=True)
                if not ok:
                    rejections[why.split(" ")[0]] += 1
                    continue
                if not record.get("make"):
                    # No camera EXIF: likely a scan, an artwork reproduction or a historical print, which are
                    # poor colour references for phone photos.
                    rejections["no-camera-exif"] += 1
                    continue
                if not record.get("thumburl"):
                    rejections["no-thumb"] += 1
                    continue
                kept.setdefault(record["sha1"], {**record, "query": query})
            print(query, "kept so far", len(kept), flush=True)
    out = os.path.join(AUTO_ROOT, args.out)
    json.dump(list(kept.values()), open(out, "w"), indent=1)
    print("kept", len(kept), "rejections", dict(rejections))


if __name__ == "__main__":
    main()
