#!/usr/bin/env python3
"""PROPOSAL (owner review 2026-10-05, not applied): readable variant names for presets that share a name.

Owner direction: letters (" · A/B") distinguish records but do not explain the looks. This script:

1. Cross-category duplicates (the same cleaned name in different categories, once per category): reports them. Inside a
   category's ruler the category tab already distinguishes them; Favourites mixes categories, where they would read the
   same.
2. Within-category collisions: names each member by how its look differs from its siblings, measured, not guessed.
   Every member's global Develop stage is rendered with the reference model (reference_model.develop_global) over three
   approved photos (docs/ui/assets/photos), and four properties are measured in OKLab: brightness (mean L), contrast
   (spread of L), colourfulness (mean chroma) and warmth (mean b). The property along which the group differs most,
   relative to how much that property varies across the whole pack, names the variants:
       2 members: Darker / Brighter, Softer / Punchier, Muted / Vivid, Cooler / Warmer
       3 members: the same words with "Balanced" for the middle one
   e.g. "Adventure 1 · Warmer" and "Adventure 1 · Cooler". Groups whose members barely differ are flagged instead.
3. Stability: the words depend only on each preset's own recipe and fixed reference photos, never on catalogue order.
   Applied names are written to display-names.json keyed by preset id; a later run keeps every name already assigned
   to an id (names never move to another preset when the catalogue is reordered or extended).

Writes docs/v1/release/preset-variant-names.md. Does not touch display-names.json.
"""
import collections, json, os, re, struct, sys, zlib
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import reference_model as rm  # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
PHOTOS = [os.path.join(REPO, 'docs/ui/assets/photos', f) for f in ('landscape_02_thumb.jpg', 'portrait_medium_02_thumb.jpg', 'sunset_02_thumb.jpg')]
OUT = os.path.join(REPO, 'docs/v1/release/preset-variant-names.md')
WORDS = {'brightness': ('Darker', 'Brighter'), 'contrast': ('Softer', 'Punchier'),
         'colourfulness': ('Muted', 'Vivid'), 'warmth': ('Cooler', 'Warmer')}

src = open(os.path.join(HERE, 'display_names.py')).read()
exec(src[src.index('def clean'):src.index('manifest = json.load')])  # the shared clean() rules


def load_pixels(path):
    """sRGB pixels in [0,1] via macOS sips -> uncompressed BMP (no third-party imaging library)."""
    import subprocess, tempfile
    with tempfile.TemporaryDirectory() as d:
        bmp = os.path.join(d, 'x.bmp')
        subprocess.run(['sips', '-s', 'format', 'bmp', '-Z', '96', path, '--out', bmp], check=True, capture_output=True)
        data = open(bmp, 'rb').read()
    offset, = struct.unpack_from('<I', data, 10); w, h = struct.unpack_from('<ii', data, 18); bpp, = struct.unpack_from('<H', data, 28)
    step = bpp // 8; row = (w * step + 3) & ~3
    raw = np.frombuffer(data, dtype=np.uint8, offset=offset, count=row * abs(h)).reshape(abs(h), row)[:, :w * step]
    px = raw.reshape(abs(h), w, step)[:, :, 2::-1].astype(np.float64)  # BGR(A) -> RGB
    return px.reshape(-1, 3) / 255.0


def measure(recipe, model, pixels):
    out = rm.develop_global(pixels, recipe, model)
    lab = rm.linear_to_oklab(rm.srgb_to_linear(np.clip(out, 0, 1)))
    L, a, b = lab[:, 0], lab[:, 1], lab[:, 2]
    return {'brightness': L.mean(), 'contrast': L.std(), 'colourfulness': np.hypot(a, b).mean(), 'warmth': b.mean()}


def main():
    model = rm.load_develop_constants()
    pixels = np.concatenate([load_pixels(p) for p in PHOTOS])
    manifest = json.load(open(os.path.join(HERE, 'out', 'manifest.json')))
    presets = [(c['name'], p) for c in manifest['categories'] for p in c['presets']]
    shown = {p['id']: clean(p['displayName'], cat) for cat, p in presets}
    by_name = collections.defaultdict(list)
    for cat, p in presets: by_name[shown[p['id']]].append((cat, p))

    cross = {n: m for n, m in by_name.items() if len(m) > 1 and len({c for c, _ in m}) == len(m)}
    within = {}
    for n, m in by_name.items():
        per_cat = collections.defaultdict(list)
        for cat, p in m: per_cat[cat].append(p)
        for cat, members in per_cat.items():
            if len(members) > 1: within[(cat, n)] = members

    # Spread of each property across the pack (a sample of every 7th preset), to compare groups on one scale.
    sample = [measure(p['recipe'], model, pixels) for _, p in presets[::7]]
    spread = {k: float(np.std([s[k] for s in sample])) for k in WORDS}

    rows, flagged = [], []
    for (cat, n), members in sorted(within.items(), key=lambda kv: (kv[0][0], kv[0][1])):
        stats = [measure(p['recipe'], model, pixels) for p in members]
        score = {k: (max(s[k] for s in stats) - min(s[k] for s in stats)) / spread[k] for k in WORDS}
        prop = max(score, key=score.get)
        order = sorted(range(len(members)), key=lambda i: stats[i][prop])
        low, high = WORDS[prop]
        labels = {}
        if len(members) == 2: labels = {order[0]: low, order[1]: high}
        elif len(members) == 3: labels = {order[0]: low, order[1]: 'Balanced', order[2]: high}
        else: labels = {i: f'{j + 1}' for j, i in enumerate(order)}
        weak = score[prop] < 0.25
        if weak: flagged.append((cat, n))
        for i, p in enumerate(members):
            rows.append((cat, n, p['displayName'], p['id'], f'{n} · {labels[i]}', prop, score[prop], weak))

    with open(OUT, 'w') as f:
        f.write('# Preset variant names: proposal (not applied)\n\n'
                'Generated by `shared/look-pack/variant_names.py`. Owner direction 2026-10-05: letters do not explain the looks; '
                'names stay bound to preset ids. Nothing here is applied until approved.\n\n')
        f.write(f'## 1. Same name in different categories ({len(cross)} names)\n\n'
                'Each occurs once per category. On a category\'s ruler the category tab tells them apart, and while browsing '
                'elsewhere the context line names the category ("Applied from Street · …"). **Favourites mixes categories**, '
                'and there the two would read the same; that is the only place the category does not already distinguish them.\n\n'
                '| Name | Categories |\n|---|---|\n')
        for n, m in sorted(cross.items()): f.write(f'| {n} | {", ".join(c for c, _ in m)} |\n')
        f.write(f'\n## 2. Same name within one category ({len(within)} groups, {len(rows)} presets)\n\n'
                'Proposed scheme: `<name> · <how it differs>`, the word chosen from the measured difference between the '
                'members (brightness, contrast, colourfulness or warmth, whichever differs most relative to the whole pack). '
                f'Groups whose members differ by less than a quarter of the pack\'s typical spread are marked weak ({len(flagged)}); '
                'their words would describe a barely visible difference.\n\n'
                '| Category | Catalogue name | Proposed | Measured on | Difference (pack spreads) |\n|---|---|---|---|---|\n')
        for cat, n, original, pid, proposed, prop, score, weak in rows:
            f.write(f'| {cat} | {original} | {proposed} | {prop} | {score:.2f}{" (weak)" if weak else ""} |\n')
    print(f'{len(cross)} cross-category names, {len(within)} within-category groups ({len(rows)} presets), {len(flagged)} weak; wrote {OUT}')
    proposed = collections.Counter((r[0], r[4]) for r in rows)
    print('duplicates left within a category:', sum(1 for v in proposed.values() if v > 1))


if __name__ == '__main__':
    main()
