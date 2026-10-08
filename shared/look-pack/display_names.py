#!/usr/bin/env python3
"""Validate the frozen Lightly naming catalogue shared by iOS and Android.

Names are assigned to stable preset IDs, never rebuilt from source-pack names or
catalogue order. The owner approved the naming direction on 2026-10-08.
Editing this catalogue changes display labels only, not recipes or saved edits.
Run this check after intentional catalogue edits; it never overwrites names.
"""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent

def validate(manifest, catalogue):
    expected = {p["id"] for c in manifest["categories"] for p in c["presets"]}
    names = catalogue["names"]
    assert catalogue["formatVersion"] == 1
    assert set(names) == expected, "Missing or unexpected preset IDs"
    assert len({n.casefold() for n in names.values()}) == len(names), "Duplicate names"
    assert all(n == n.strip() and 0 < len(n) <= 30 for n in names.values()), "Invalid label"
    assert all(not any(c.isdigit() for c in n) for n in names.values()), "Numbered label"
    return len(names)

if __name__ == "__main__":
    manifest = json.loads((HERE / "out/manifest.json").read_text())
    catalogue = json.loads((HERE / "names/display-names.json").read_text())
    count = validate(manifest, catalogue)
    print(f"{count} stable Lightly names; complete coverage; no duplicates; no numbered labels")
