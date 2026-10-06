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

--variants (proposal 2026-10-05, applied only after the owner approves the preview): instead of keeping catalogue
names, every member of a collision group (and of a name the catalogue itself repeats) gets the shared cleaned name plus a variant letter, " · A", " · B", ...,
in catalogue order (category order, then stop), e.g. "01 Adventure 01" -> "Adventure 1 · A", "Adventure 1" ->
"Adventure 1 · B". The sources carry no readable variant information (only bundle file names such as "Presets for
Android.zip" and pack codes such as "C4"), so letters are used. Ids are unchanged; order is fixed by the catalogue,
so the letters are stable. `--preview FILE` writes the full mapping of collision groups as Markdown without
touching display-names.json.
"""
import json, os, re, sys, collections, string
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
variants = '--variants' in sys.argv
order = {pid: i for i, (_, pid, _) in enumerate(presets)}
category = {pid: cat for cat, pid, _ in presets}
# Every shared label gets letters: the merges above, and names the catalogue itself repeats ("Winter 1" twice).
groups = collections.defaultdict(list)
for pid, n in proposed.items(): groups[n].append(pid)
groups = {n: members for n, members in groups.items() if len(members) > 1}
lettered = {}
for n, members in groups.items():
    for letter, pid in zip(string.ascii_uppercase, sorted(members, key=order.get)):
        lettered[pid] = f'{n} · {letter}'
# Final proposal (2026-10-06, awaiting the owner's choice): same name within one category -> stable variant numbers.
# The member whose catalogue name has no numbering or code prefix of its own ("Nordic 01", not "01 Nordic 01" or
# "P13 - ...") keeps the plain name; the others get " · Variant 2", " · Variant 3" (preset-id order breaks ties). The
# name's own number is kept and never doubled. Names differing only by category stay plain (the UI shows the category
# where they could be confused). --numbered-preview FILE writes the table; --apply-numbered writes display-names.json,
# keeping every name an id already has there, so reordering or extending the catalogue never renames a preset.
def numbered_names():
    by_cat_name = collections.defaultdict(list)
    for cat, pid, _ in presets: by_cat_name[(cat, proposed[pid])].append(pid)
    out = {}
    for (cat, n), members in by_cat_name.items():
        if len(members) < 2: continue
        prefixed = lambda pid: bool(re.match(r'^\s*(?:\d+\s|[A-Z]{0,4}\d+\s+-\s)', original[pid]))
        ordered = sorted(members, key=lambda pid: (prefixed(pid), pid))
        out[ordered[0]] = n
        for k, pid in enumerate(ordered[1:], start=2): out[pid] = f'{n} · Variant {k}'
    return out
if '--numbered-preview' in sys.argv:
    path = sys.argv[sys.argv.index('--numbered-preview') + 1]
    numbered = numbered_names()
    category_of = {pid: cat for cat, pid, _ in presets}
    with open(path, 'w') as f:
        for pid in sorted(numbered, key=lambda p: (category_of[p], numbered[p])):
            f.write(f'| {category_of[pid]} | {original[pid]} | {numbered[pid]} | `{pid}` |\n')
    print(len(numbered), 'presets in', len({(category_of[p], proposed[p]) for p in numbered}), 'groups')
    sys.exit(0)
if '--apply-numbered' in sys.argv:
    existing = json.load(open(OUT)).get('names', {}) if os.path.exists(OUT) else {}
    final.update(numbered_names())
    final.update({pid: n for pid, n in existing.items() if pid in final and n != proposed.get(pid)})  # ids keep assigned names
if '--preview' in sys.argv:
    path = sys.argv[sys.argv.index('--preview') + 1]
    with open(path, 'w') as f:
        f.write(f'# Preset name collisions: proposed variant letters ({len(groups)} groups, {len(lettered)} presets)\n\n')
        f.write('Generated by `shared/look-pack/display_names.py --preview`. Not applied until approved.\n\n')
        f.write('| Catalogue name | Category | Proposed |\n|---|---|---|\n')
        for n in sorted(groups):
            for pid in sorted(groups[n], key=order.get): f.write(f'| {original[pid]} | {category[pid]} | {lettered[pid]} |\n')
    print('preview written to', path)
    sys.exit(0)
if variants: final.update(lettered)
changed = {pid: n for pid, n in final.items() if n != original[pid]}
json.dump({'formatVersion': 1, 'names': dict(sorted(changed.items()))}, open(OUT, 'w'), ensure_ascii=False, indent=1)
print(f'{len(presets)} presets, {len(changed)} renamed, {len(collisions)} cleaned names would have merged different presets' + (' (lettered variants)' if variants else ' (those keep their catalogue names)'))
for n in collisions[:20]: print('  collision:', n, [original[p] for p in proposed if proposed[p] == n][:4])
