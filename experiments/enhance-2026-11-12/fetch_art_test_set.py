"""Enhance step 1f: test images for "leave paintings alone" (owner approved the download, 2026-11-13).

Public-domain (CC0) objects from The Met's Open Access API: portrait paintings and miniatures, drawings and prints
(the classes Enhance should skip), and old portrait photographs (the class it should enhance). Saves the web-large image
to art-test/<class>/<object id>.jpg and every source to art-test/SOURCES.csv. Images are git-ignored.
Run: .venv/bin/python -I fetch_art_test_set.py
"""
import csv
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "art-test"
API = "https://collectionapi.metmuseum.org/public/collection"
# (class, department id, query, how many)
SETS = [("painting", 11, "portrait", 45), ("painting", 1, "portrait painting", 15), ("painting", 1, "miniature portrait", 10),
        ("drawing", 9, "portrait", 20), ("photo", 19, "portrait", 45), ("photo", 19, "daguerreotype", 12),
        ("photo", 19, "tintype", 10), ("photo", 19, "carte de visite", 10), ("photo", 19, "albumen print portrait", 10),
        ("photo", 19, "cabinet card", 8)]


def get_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)


def main(out: Path = OUT, sets=SETS, exclude: frozenset = frozenset(), offsets=(0,)) -> None:
    """exclude: object ids never to fetch (the training set excludes every test image)."""
    sources = out / "SOURCES.csv"
    out.mkdir(exist_ok=True)
    recorded = set()
    if sources.exists():
        recorded = {(row[0], row[1]) for row in csv.reader(sources.open()) if row}
    with sources.open("a", newline="") as handle:
        writer = csv.writer(handle)  # one row per image as it is saved, so an interrupted run keeps its sources
        for label, department, query, wanted in sets:
            folder = out / label
            folder.mkdir(parents=True, exist_ok=True)
            ids = []
            for offset in offsets:
                ids += get_json(f"{API}/v1.1/search?q={urllib.parse.quote(query)}&hasImages=true"
                                f"&departmentId={department}&limit=200&offset={offset}").get("objectIDs") or []
            ids = [object_id for object_id in ids if object_id not in exclude]
            have = 0
            for object_id in ids:
                if have >= wanted:
                    break
                target = folder / f"{object_id}.jpg"
                if target.exists() and (label, str(object_id)) in recorded:
                    have += 1
                    continue
                try:
                    record = get_json(f"{API}/v1/objects/{object_id}")
                    image_url = record.get("primaryImageSmall") or ""
                    if not record.get("isPublicDomain") or not image_url.startswith("https://images.metmuseum.org/"):
                        continue
                    if not target.exists():
                        # Some Met file names contain spaces: encode the path, keep the scheme and host.
                        with urllib.request.urlopen(urllib.parse.quote(image_url, safe=":/"), timeout=60) as response:
                            target.write_bytes(response.read())
                except (urllib.error.URLError, OSError, ValueError) as error:  # refused (403/404), timeout or bad URL:
                    print("skipped", object_id, getattr(error, "code", error), flush=True)  # skip, no retry loop
                    time.sleep(1.0)
                    continue
                writer.writerow([label, object_id, record.get("title", ""), record.get("objectDate", ""),
                                 record.get("classification", ""), record.get("department", ""), image_url,
                                 record.get("objectURL", "")])
                handle.flush()
                recorded.add((label, str(object_id)))
                have += 1
                time.sleep(0.25)
            print(label, department, query, "have", have, flush=True)


if __name__ == "__main__":
    main()
