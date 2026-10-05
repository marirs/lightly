#!/usr/bin/env python3
"""Readable preset display names for both apps (owner feedback 2026-10-05: "05 Nude Tones 05" is not a finished label).

Reads the pack manifest (shared/look-pack/out/manifest.json) and writes shared/look-pack/names/display-names.json:
{"formatVersion": 1, "names": {"<preset id>": "<display name>"}}. Only names that change are listed; ids, versions,
recipes, favourites and saved edits are untouched (both apps apply the mapping when they load the pack).

Rules, in order, applied to the catalogue's name:
  1. "NN Words NN" with the same number twice  -> "Words N"         ("05 Nude Tones 05" -> "Nude Tones 5")
  2. a code prefix "N - ", "P2 - ", "CC20 - "   -> dropped          ("6 - Commercial Vibe" -> "Commercial Vibe")
  3. "(Portrait)" style tags naming the category -> dropped
  4. " | " between words                          -> " · "
  5. "Word-NN"                                     -> "Word NN"
  6. leading zeros of standalone numbers           -> dropped         ("Portrait 08" -> "Portrait 8"; "400" kept)
If two presets would share a name, both keep their catalogue name (no invented names). Prints the collisions.
"""
import json, os, re, sys, collections
HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, 'out', 'manifest.json')
OUT = os.path.join(HERE, 'names', 'display-names.json')

def clean(name: str, category: str) -> str:
    n = name.strip()
    m = re.fullmatch(r'0*(\d+)\s+(.+?)\s+0*(\d+)', n)
    if m and m.group(1) == m.group(3): n = f'{m.group(2)} {m.group(3)}'
    n = re.sub(r'^(?:[A-Z]{0,3}\d+)\s+-\s+', '', n)
    n = re.sub(r'\(\s*' + re.escape(category) + r'\s*\)\s*', '', n, flags=re.I)
    n = re.sub(r'\s+\|\s+', ' · ', n)
    n = re.sub(r'(?<=[A-Za-z])-(\d+)\b', r' \1', n)
    n = re.sub(r'\b0+(\d)', r'\1', n)
    return re.sub(r'\s{2,}', ' ', n).strip()

manifest = json.load(open(MANIFEST))
presets = [(c['name'], p['id'], p['displayName']) for c in manifest['categories'] for p in c['presets']]
proposed = {pid: clean(name, cat) for cat, pid, name in presets}
original = {pid: name for _, pid, name in presets}
# No new collisions: presets may share a cleaned name only if they already shared their catalogue name (the
# catalogue has some duplicates of its own). Members of a group that would merge different names keep their
# catalogue names; repeat until stable.
final = dict(proposed)
collisions = set()
while True:
    groups = collections.defaultdict(list)
    for pid, n in final.items(): groups[n].append(pid)
    bad = [n for n, members in groups.items() if len({original[m] for m in members}) > 1]
    if not bad: break
    for n in bad:
        collisions.add(n)
        for m in groups[n]: final[m] = original[m]
collisions = sorted(collisions)
changed = {pid: n for pid, n in final.items() if n != original[pid]}
json.dump({'formatVersion': 1, 'names': dict(sorted(changed.items()))}, open(OUT, 'w'), ensure_ascii=False, indent=1)
print(f'{len(presets)} presets, {len(changed)} renamed, {len(collisions)} cleaned names would have merged different presets (those keep their catalogue names)')
for n in collisions[:20]: print('  collision:', n, [original[p] for p in proposed if proposed[p] == n][:4])
