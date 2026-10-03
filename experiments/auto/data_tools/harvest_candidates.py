"""Harvest candidate phone photos per rubric class from Wikimedia Commons (CC0 / public domain).

  python -m data_tools.harvest_candidates --out data/commons/candidates.json

Search terms only nominate candidates. Every image that enters an evaluation manifest is then checked by eye
on contact sheets (data_tools/contact_sheet.py) and its class assigned by the reviewer, never by the query.
"""
from __future__ import annotations

import argparse
import json
import os
from collections import Counter

from data_tools.commons import CC0_OR_PD_QUERY, eligible, phone_brand, search

AUTO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CLASS_QUERIES = {
    "portrait": ["portrait", "selfie", "woman smiling", "man portrait", "people portrait face", "girl portrait",
                 "boy portrait", "portrait Nigeria", "portrait Ghana", "portrait Kenya", "portrait Uganda",
                 "portrait India", "portrait Bangladesh", "portrait Indonesia", "portrait Philippines", "portrait Brazil",
                 "portrait Ethiopia", "portrait Cameroon", "Wikimedian portrait", "headshot"],
    "backlit": ["backlit", "backlight", "against the light", "contre-jour", "silhouette", "person backlit",
                "window light person", "sun behind"],
    "night": ["night", "at night", "night street", "night city", "night lights", "by night", "nightscape", "evening lights"],
    "sunset": ["sunset", "sunrise", "golden hour", "sunset beach", "sunset sky", "dusk"],
    "landscape": ["landscape", "mountain view", "valley", "lake view", "countryside", "panorama view", "hills"],
    "indoor_mixed": ["interior", "restaurant interior", "kitchen", "living room", "museum interior", "church interior",
                     "office interior", "cafe interior", "shop interior"],
    "already_good": ["incategory:Quality_images", "incategory:Valued_images_by_subject"],
}


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="data/commons/candidates.json")
    parser.add_argument("--per-query", type=int, default=150)
    args = parser.parse_args(argv)
    cache = os.path.join(AUTO_ROOT, "data", "commons", "search_cache")
    candidates, rejections = {}, Counter()
    jobs = [(nominated_class, f"{CC0_OR_PD_QUERY} filetype:bitmap {term}")
            for nominated_class, queries in CLASS_QUERIES.items() for term in queries]
    for nominated_class, query in jobs:  # serial: commons.polite_get enforces the rate limit
        records = search(query, args.per_query, cache)
        for record in records:
            # Phones are preferred (protocol), but CC0 phone portraits are scarce on Commons, so unedited
            # camera JPEGs are kept as a labelled fallback (is_phone False) and reported separately.
            ok, why = eligible(record, require_phone=False)
            if not ok:
                rejections[why.split(" ")[0]] += 1
                continue
            is_phone = phone_brand(record.get("make", ""), record.get("model", "")) is not None
            if not is_phone and not record.get("make"):
                rejections["no-EXIF-camera"] += 1  # no camera EXIF: cannot show it is an unedited capture
                continue
            entry = candidates.setdefault(record["sha1"], {**record, "is_phone": is_phone, "nominated_classes": [], "queries": []})
            if nominated_class not in entry["nominated_classes"]:
                entry["nominated_classes"].append(nominated_class)
            entry["queries"].append(query)
        print(query, "candidates so far", len(candidates), flush=True)
    out = os.path.join(AUTO_ROOT, args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump(list(candidates.values()), open(out, "w"), indent=1)
    by_class = Counter(c for r in candidates.values() for c in r["nominated_classes"])
    by_class_phone = Counter(c for r in candidates.values() if r["is_phone"] for c in r["nominated_classes"])
    print("by nominated class (all cameras)", dict(by_class))
    print("by nominated class (phones)", dict(by_class_phone))
    print("rejections", dict(rejections))


if __name__ == "__main__":
    main()
