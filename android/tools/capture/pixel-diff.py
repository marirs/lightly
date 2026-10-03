#!/usr/bin/env python3
"""Pixel-by-pixel comparison of two capture folders (same file names), for validating the capture runner.

Usage: pixel-diff.py <folder A> <folder B> [--masks <dir>] [--json <out.json>]

For every PNG present in both folders: identical, or the number of differing pixels, the largest
channel difference and the bounding box of the differences (pixels and as a fraction of the height,
to locate status bar / photo / panel). With --masks, a JPEG per differing pair shows B with the
differing pixels in magenta (generated on demand; the PNGs remain the evidence).
Needs numpy and Pillow (experiments/android-vision/.venv has both).
"""
import json
import os
import sys

import numpy as np
from PIL import Image


def load(path):
    return np.asarray(Image.open(path).convert("RGBA"), dtype=np.int16)


def compare(a_path, b_path):
    a, b = load(a_path), load(b_path)
    if a.shape != b.shape:
        return {"status": "size", "a": list(a.shape), "b": list(b.shape)}
    delta = np.abs(a - b).max(axis=2)
    differing = delta > 0
    count = int(differing.sum())
    if count == 0:
        return {"status": "identical"}
    ys, xs = np.nonzero(differing)
    h = a.shape[0]
    return {
        "status": "differs",
        "pixels": count,
        "fraction": round(count / differing.size, 6),
        "max_delta": int(delta.max()),
        "bbox": [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())],
        "bbox_y_fraction": [round(ys.min() / h, 3), round(ys.max() / h, 3)],
    }, differing, b


def main():
    args = sys.argv[1:]
    masks = json_out = None
    if "--masks" in args:
        i = args.index("--masks"); masks = args[i + 1]; del args[i:i + 2]
    if "--json" in args:
        i = args.index("--json"); json_out = args[i + 1]; del args[i:i + 2]
    left, right = args
    names = sorted(n for n in os.listdir(left) if n.endswith(".png") and os.path.exists(os.path.join(right, n)))
    report = {}
    for name in names:
        result = compare(os.path.join(left, name), os.path.join(right, name))
        if isinstance(result, tuple):
            summary, differing, b = result
            if masks:
                os.makedirs(masks, exist_ok=True)
                shown = b[..., :3].astype(np.uint8).copy()
                shown[differing] = (255, 0, 255)
                Image.fromarray(shown).save(os.path.join(masks, name[:-4] + ".jpg"), quality=80)
        else:
            summary = result
        report[name] = summary
        print(name, json.dumps(summary))
    only = sorted(set(n for n in os.listdir(left) if n.endswith(".png")) ^ set(n for n in os.listdir(right) if n.endswith(".png")))
    for name in only:
        print(name, '{"status": "missing in one folder"}')
    if json_out:
        json.dump(report, open(json_out, "w"), indent=2)
    identical = sum(1 for r in report.values() if r["status"] == "identical")
    print(f"{identical}/{len(report)} identical")


if __name__ == "__main__":
    main()
