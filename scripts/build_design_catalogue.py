"""Build the explicit, reviewable Develop catalogue for the design milestone.

Assignments below are editorial decisions, not inferred by Claude or by the app.
Unknown material remains inventoried; it is never silently assigned a fallback.
"""
import csv
import hashlib
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'experiments/presets'))
from lrsettings import parse_bytes

CATEGORIES = ['Portrait', 'Landscape', 'Film', 'Cinematic', 'Street', 'Travel', 'Wedding', 'Golden Hour', 'Black & White']
# Exact collection families, inspected in the source inventory.
FAMILIES = {
    'Portrait': ['Portrait', 'WithLuke Bonus Portrait Collection', 'Fitness Collection', 'Nude Tones Collection', 'Light _ Airy Collection Desktop_Mobile Presets'],
    'Landscape': ['Classic', 'Aerial', 'Cine Landscapes', 'Cinematic Drone', 'Cinematic Green', 'Dark Cinema Drone', 'Dark City Drone', 'Deep Blue', 'Drone Forest', 'Drone Green', 'Drone Island', 'Garden', 'Landscapes Drone', 'Moody Forest', 'Rustic Fall', 'Underwater', 'Winter Drone', 'Autumn Collection', 'Drone Collection', 'Earth Tones', 'Forest', 'Hiking Collection', 'Woodlands Collection', 'Rustic Collection'],
    'Film': ['35MM Film', 'Analog Film V2', 'Analog Flim', 'Classic Flim', 'Kodak Flim', 'Nostalgia', 'Polaroid', 'Portra 400', 'Street Flim', 'Vintage Flim', 'Film Collection Lightroom Desktop _ Mobile Presets', 'Vintage Collection Lightroom Desktop _ Mobile Presets', 'Faded Black Collection'],
    'Cinematic': ['Cinematic', 'Cinematic Light', 'Dark Cinema', 'Dystopia', 'Movie', 'Movie Style', 'Dark Moody', 'Moody Blue', 'Moody Earthy', 'WithLuke - Cinematic Collection', 'WithLuke Cinematic Collection', 'Cinematic Collection Desktop Mobile Lightroom Presets', 'Moody', 'Carbon Collection Lightroom Desktop _ Mobile Presets', 'Blvck Lightroom Desktop Mobile Preset Collection', 'Rich Black', 'Black'],
    'Street': ['Black Car', 'Black Paris', 'Cinematic City', 'City Drone', 'Dark Academia', 'Dark Winter', 'Flash', 'London Style', 'New York', 'Night Street', 'Rainy', 'Urban', 'Urban Light', 'Urban Night', 'Automotive Collection', 'Cinematic Street', 'City Lights Collection', 'Grey Tones Collection', 'Metro Collection', 'Neon Lights Collection', 'Urban Collection'],
    'Travel': ['Adventure', 'Aesthetic', 'Clean & White', 'Interior', 'Nordic', 'Organic', 'Travel', 'Adventure Collection', 'California Collection', 'Color Pop Collection', 'Espresso', 'Festive Collection', 'Home Collection', 'Minimal Blogger Collection', 'Minimal Brown Collection', 'Nordic Collection', 'Tasty Collection'],
    'Wedding': ['Autumn Wedding', 'Boho Wedding', 'Bronze Wedding', 'Classy Wedding', 'Earthy Wedding', 'Golden Wedding', 'Retro Wedding', 'Vintage Wedding'],
    'Golden Hour': ['Golden Hour', 'Sunset Drone', 'Golden Hour Collection'],
    'Black & White': ['Black and White'],
}
FAMILY_MAP = {name: category for category, names in FAMILIES.items() for name in names}
# Exact named families in the otherwise unstructured source archives.
NAME_FAMILIES = {
    'Portrait': ['Portrait', 'Selfie', 'Fitness', 'Nude', 'Cream', 'Creamy', 'Soft Light', 'Rose Petal'],
    'Landscape': ['Aerial', 'Dark Green', 'Nature Vibes', 'New Nature', 'Jungle', 'Iceland Blue', 'Crystal Blue', 'Calm Sea', 'Sky Light', 'Rose Desert', 'Wild', 'Wld', 'Cold'],
    'Film': ['Film', 'Popped Film', 'Rose Film', 'Rose Flm', 'Rose FIlm', 'Retrô', 'Vintage', 'Matte Style'],
    'Cinematic': ['Cinematic', 'CINEMATIC', 'New Cinema', 'Modern Movie', 'Matrix Look', 'Orange and Blue', 'Teals', 'Drama', 'Poison', 'SkyFall', 'Dark Moody', 'Moody', 'Black Moody', 'Dark Aesthetic', 'Dark Orange', 'Dark Red', 'Dark Yellow', 'Dark Purple', 'Dark Blue', 'Dark Light', 'Dreamy', 'Black', 'Super Black', 'Pure Black', 'Luxury Black', 'Gold Black', 'New Orange', 'Gray', 'Gray Moody'],
    'Street': ['Night City', 'Old Street', 'Urban', 'Blue Light', 'Car Horizon', 'Car and Nature'],
    'Travel': ['Adventure', 'Aesthetic', 'Clean Aesthetic', 'Bright', 'Beach Style', 'Beach Tones', 'Blogger', 'Comida', 'Food', 'Influencer', 'Insta Look', 'Insta Feed', 'Lifestyle', 'Natural', 'NO FILTER', 'Clean', 'Basic V', 'Summer', 'Summer Paradise', 'Verão', 'Travel', 'White', 'Vibes', 'Vibrant', 'Ocean Blue', 'Ocea Blue', 'Radiant'],
    'Golden Hour': ['Golden Tones', 'Rose Gold', 'Fire'],
    'Black & White': ['Preto e Branco'],
}
NAME_MAP = {n.casefold(): c for c, names in NAME_FAMILIES.items() for n in names}
NAME_MAP.update({'white car':'Street','bali':'Travel','cloudy':'Landscape','influencer v':'Travel','rustic':'Film','wedding':'Wedding','wedding v':'Wedding','white v':'Travel','beauty':'Portrait','black gold':'Cinematic','cyberpunk':'Cinematic','dramatic':'Cinematic','film portrait':'Portrait','landscape':'Landscape','neon lights':'Street','purple horizon':'Landscape'})
YEAR_NAMES = {
    'Portrait': [5, 8, 15, 16, 19, 25], 'Landscape': [1, 2, 3, 4, 11, 20, 22, 23, 26],
    'Cinematic': [6, 7, 9, 17, 18, 29], 'Street': [10], 'Travel': [12, 13, 14, 21, 27, 30],
    'Wedding': [24], 'Golden Hour': [28],
}
DISPLAY_METADATA = {'Name', 'ShortName', 'SortName', 'Group', 'UUID', 'Copyright', 'ContactInfo', 'Description'}


def clean_name(raw):
    raw = raw.split('!')[-1]
    raw = re.sub(r'\.(xmp|dng|lrtemplate|cube)$', '', raw, flags=re.I)
    raw = re.sub(r'https?://\S+|www\.\S+', '', raw, flags=re.I)
    raw = re.sub(r'WithLuke|SolutionPresets|Huliluts|#WL', '', raw, flags=re.I)
    raw = re.sub(r'\bFlim\b', 'Film', raw, flags=re.I)
    raw = raw.replace('Cassic', 'Classic').replace('Nighmood', 'Night Mood')
    return re.sub(r'\s+', ' ', raw).strip(' -_')


def natural_key(text):
    return [int(t) if t.isdigit() else t.casefold() for t in re.split(r'(\d+)', text)]


def assign(record, settings, name):
    family = record['sources'][0]['category']
    if family in ['Film Grain', 'Tone Curves', 'Split Toning']:
        return None, 'Standalone adjustment/reset family; outside Develop looks'
    if re.search(r'\bclear all\b|\breset\b|no filter', name, re.I):
        return None, 'Reset/identity command; represented by the base stop'
    if str(settings.get('ConvertToGrayscale', '')).lower() == 'true' or str(settings.get('Treatment', '')).lower() == 'black & white' or str(settings.get('Saturation', '')).strip() == '-100':
        return 'Black & White', 'Source enables monochrome treatment or full desaturation (toning may remain)'
    if family in FAMILY_MAP:
        category = FAMILY_MAP[family]
        if category == 'Black & White':
            return None, 'Named monochrome family without verified monochrome setting'
        return category, 'Explicit reviewed source-family assignment: ' + family
    if family == '2025 Collection':
        n = int(re.match(r'\d+', name)[0])
        return next(c for c, nums in YEAR_NAMES.items() if n in nums), 'Explicit individual assignment in 2025 collection'
    if family in ['Timeless Collection', 'WithLuke - Timeless Collection']:
        for prefix, category in [('Portrait', 'Portrait'), ('Urban', 'Street'), ('Blue', 'Landscape'), ('Desert', 'Landscape'), ('Green', 'Landscape'), ('Nature', 'Landscape'), ('zAstro', 'Landscape')]:
            if name.startswith(prefix):
                return category, 'Explicit Timeless subgroup assignment: ' + prefix
    if family == 'WithLuke Africa Collection':
        return ('Film' if name.startswith('A14 ') else 'Landscape'), 'Explicit Africa series assignment'
    if family == 'Commercial':
        return ('Street' if name.startswith('C6 ') else 'Cinematic'), 'Explicit Commercial series assignment'
    if family == 'Cinematic Presets - Android':
        return 'Cinematic', 'Explicit cinematic series assignment'
    stem = re.sub(r'[\s_-]*\d+.*$', '', name).strip().casefold()
    if stem in NAME_MAP:
        if NAME_MAP[stem] == 'Black & White':
            return None, 'Named monochrome family without verified monochrome setting'
        return NAME_MAP[stem], 'Explicit reviewed named-family assignment: ' + stem
    return None, 'Not selected: no explicit reviewed assignment'


def main():
    dest = ROOT / 'presets'
    assets = json.loads((dest / 'manifest.json').read_text())['assets']
    included, excluded, seen = [], [], {}
    for r in assets:
        if r['format'] != 'xmp':
            excluded.append({'assetId': r['id'], 'reason': 'Alternate source format preserved outside this XMP-based design selection; equivalence not assumed'})
            continue
        parsed = parse_bytes((dest / r['file']).read_bytes(), r['file'], '.xmp')
        name = clean_name(r['name'])
        if re.fullmatch(r'[\d\s]+', name):
            name = clean_name(Path(r['sources'][0]['source'].split('!')[-1]).stem)
        if parsed.error:
            excluded.append({'assetId': r['id'], 'reason': parsed.error})
            continue
        category, reason = assign(r, parsed.settings, name)
        if not category:
            excluded.append({'assetId': r['id'], 'name': name, 'reason': reason})
            continue
        # Only label/author fields are removed. All parsed processing/restriction fields remain.
        settings = {k: v for k, v in parsed.settings.items() if k not in DISPLAY_METADATA}
        signature = hashlib.sha256(json.dumps(settings, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        if signature in seen:
            seen[signature]['equivalentAssetIds'].append(r['id'])
            excluded.append({'assetId': r['id'], 'reason': 'Identical complete parsed processing settings', 'sameAs': seen[signature]['id']})
            continue
        entry = {'id': 'look-' + r['id'][:20], 'displayName': name, 'category': category,
                 'sourceAssetId': r['id'], 'sourceFile': r['file'], 'settingsSha256': signature,
                 'assignmentReason': reason, 'equivalentAssetIds': [], 'renderValidation': 'not-validated'}
        included.append(entry)
        seen[signature] = entry
    # Same name can refer to different settings. Keep both with an explicit, stable distinction.
    collisions = defaultdict(list)
    for e in included:
        collisions[(e['category'], e['displayName'].casefold())].append(e)
    for es in collisions.values():
        if len(es) > 1:
            for i, e in enumerate(sorted(es, key=lambda e: e['id']), 1):
                e['displayName'] += f' — Variation {i}'
    catalogue = []
    for category in CATEGORIES:
        entries = sorted([e for e in included if e['category'] == category], key=lambda e: natural_key(e['displayName']))
        for i, e in enumerate(entries, 1):
            e['stop'] = i
        catalogue.append({'id': category.lower().replace(' & ', '-').replace(' ', '-'), 'name': category, 'presets': entries})
    contract = {'schemaVersion': 1, 'purpose': 'Approved-category design input; editorial membership proposed by Codex, rendering unvalidated',
                'baseStop': {'stop': 0, 'labelRule': 'Auto only when correction applied; otherwise Original'},
                'orderRule': 'Frozen natural display-name order; no claim of perceptual progression', 'categories': catalogue}
    (dest / 'develop-design-catalogue.json').write_text(json.dumps(contract, ensure_ascii=False, indent=2))
    (dest / 'develop-design-exclusions.json').write_text(json.dumps(excluded, ensure_ascii=False, indent=2))
    public = {**contract, 'categories': [{**c, 'presets': [{k:e[k] for k in ['id','displayName','stop']} for e in c['presets']]} for c in catalogue]}
    (dest / 'develop-design-ui.json').write_text(json.dumps(public, ensure_ascii=False, indent=2))
    lines = ['# Exact Develop slider catalogue', '', 'Every numbered line is one fixed slider stop. Stop 0 is Auto or Original, according to whether correction is applied.', '', 'This is the design catalogue, not a claim of rendering fidelity. Order is natural name order, not increasing strength. Source files remain intact.', '']
    for c in catalogue:
        lines += [f"## {c['name']} — {len(c['presets'])} presets", '']
        lines += [f"{e['stop']}. {e['displayName']} (`{e['id']}`)" for e in c['presets']]
        lines += ['']
    (dest / 'DEVELOP-PRESET-LIST.md').write_text('\n'.join(lines))
    with (dest / 'develop-design-catalogue.csv').open('w') as f:
        w = csv.writer(f); w.writerow(['category','stop','displayName','id','sourceAssetId'])
        for c in catalogue:
            for e in c['presets']:w.writerow([c['name'],e['stop'],e['displayName'],e['id'],e['sourceAssetId']])
    print(json.dumps({'included': len(included), 'categories': {c['name']:len(c['presets']) for c in catalogue}, 'excluded': dict(Counter(e['reason'] for e in excluded))}, indent=2))


if __name__ == '__main__':
    main()
