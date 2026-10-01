"""Inventory every develop parameter in the source preset collection.

Usage: python inventory.py "<preset root>"  -> inventory.json + printed summary
Counts per key: present, non-default (value differs from Lightroom's neutral default), parse errors.
"""
import collections, json, sys
from pathlib import Path
import lrsettings

# Values that mean "no adjustment" in Lightroom. Missing key == default.
NEUTRAL = {"0", "+0", "0.0", "+0.00", "0.00", "-0", "", "False", "None"}
NEUTRAL_CURVES = {("0, 0", "255, 255")}
METADATA_KEYS = {"Name", "Group", "UUID", "SupportsAmount", "SupportsAmount2", "SupportsColor", "SupportsMonochrome",
                 "SupportsHighDynamicRange", "SupportsNormalDynamicRange", "SupportsSceneReferred", "SupportsOutputReferred",
                 "CameraModelRestriction", "Copyright", "ContactInfo", "Version", "PresetType", "Cluster", "Description",
                 "HasSettings", "AlreadyApplied", "RawFileName", "ShortName", "SortName", "Amount"}

def non_default(k, v):
    if isinstance(v, list):
        return len(v) > 0 and not (all(isinstance(x, str) for x in v) and tuple(v) in NEUTRAL_CURVES)
    if isinstance(v, dict):
        return bool(v)
    return str(v).strip() not in NEUTRAL

root = Path(sys.argv[1])
present, nondef, kinds, errors, packs = collections.Counter(), collections.Counter(), collections.Counter(), [], collections.Counter()
example = {}
n = 0
for p in lrsettings.walk(root):
    n += 1; kinds[p.kind] += 1; packs[p.source.split("/")[0]] += 1
    if p.error:
        errors.append({"source": p.source, "error": p.error}); continue
    for k, v in p.settings.items():
        if k in METADATA_KEYS: continue
        present[k] += 1
        if non_default(k, v):
            nondef[k] += 1
            example.setdefault(k, v if not isinstance(v, (list, dict)) else str(v)[:120])
out = {"files": n, "kinds": kinds, "packs": packs, "errors": errors,
       "keys": {k: {"present": present[k], "non_default": nondef[k], "example": example.get(k)} for k in sorted(present, key=lambda k: -nondef[k])}}
json.dump(out, open("inventory.json", "w"), indent=1, default=str)
print(n, "files", dict(kinds), "errors", len(errors))
for e in errors[:8]: print("  ERR", e)
for k in sorted(present, key=lambda k: -nondef[k])[:140]:
    print(f"{nondef[k]:6d} {present[k]:6d}  {k}")
