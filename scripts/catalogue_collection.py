"""Preserve original preset bytes; deduplicate only SHA-256-identical files.

Usage: python3 scripts/catalogue_collection.py SOURCE_ROOT
Archives are read without extracting their paths. Existing outputs are verified.
"""
import hashlib
import json
import re
import sys
import zipfile
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'experiments/presets'))
from lrsettings import parse_bytes

EXTS = {'.xmp', '.lrtemplate', '.dng', '.cube'}


def category(path):
    parts = path.replace('!', '/').split('/')
    for part in reversed(parts[:-1]):
        if part.lower().endswith('.zip'):
            return re.sub(r'\(\d+\)$', '', Path(part).stem).strip()
        clean = re.sub(r'^#?WL\s*-\s*(?:\d+\s*-\s*)?', '', part, flags=re.I)
        clean = re.sub(r'\s*\(Added.*?\)', '', clean, flags=re.I)
        clean = re.sub(r'\s*(?:Lightroom Desktop Mobile Presets|Video Luts|Luts Video| - DESKTOP Presets \(XMP\)| - MOBILE Presets.*|\(XMP\))\s*$', '', clean, flags=re.I).strip()
        if re.match(r'^#?(?:DNG|LRT|XMP) Files', clean, re.I):
            continue
        if not clean or re.fullmatch(r'[\d\s#-]*(?:desktop|mobile|xmp|dng|lrtemplate|presets|files|video luts|luts video|luts|desktop presets|mobile presets|xmp files.*|for lightroom.*|part\s*\d+|1 desktop|2 mobile)(?:\s*\(.*\))?', clean, re.I):
            continue
        return clean
    return 'Unsorted collection'


def main(source):
    source = Path(source).resolve()
    dest = ROOT / 'presets'
    dest.mkdir(exist_ok=True)
    (dest / '.gitignore').write_text('library/\nmanifest.json\ncatalog.json\nsummary.json\nbrowse-catalog.json\ndevelop-design-*.json\ndevelop-design-*.csv\nDEVELOP-PRESET-LIST.md\n\n!develop-design-ui.json\n!DEVELOP-PRESET-LIST.md\n')
    records = {}
    occurrences = 0

    def add(data, origin, ext):
        nonlocal occurrences
        occurrences += 1
        digest = hashlib.sha256(data).hexdigest()
        alias = {'source': origin, 'vendor': origin.split('/')[0], 'category': category(origin)}
        if digest in records:
            records[digest]['sources'].append(alias)
            return
        filename = re.sub(r'[^\w .()#-]', '_', Path(origin).name)
        rel = Path('library') / digest[:2] / digest / filename
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                raise ValueError(f'Existing asset was changed: {target}')
        else:
            target.write_bytes(data)
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise ValueError(f'Copy verification failed: {target}')
        parsed = parse_bytes(data, origin, ext) if ext != '.cube' else None
        records[digest] = {'id': digest, 'file': str(rel), 'bytes': len(data), 'format': ext[1:],
            'name': (parsed.name if parsed and parsed.name else Path(filename).stem),
            'parseError': parsed.error if parsed else None, 'sources': [alias]}

    files = sorted(source.rglob('*'))
    for p in files:
        if not p.is_file() or p.name.startswith('._') or '__MACOSX' in p.parts:
            continue
        ext = p.suffix.lower()
        if ext in EXTS:
            add(p.read_bytes(), p.relative_to(source).as_posix(), ext)
        elif ext == '.zip':
            with zipfile.ZipFile(p) as z:
                for name in sorted(z.namelist()):
                    ext = Path(name).suffix.lower()
                    if ext in EXTS and '__MACOSX' not in name and not Path(name).name.startswith('._'):
                        add(z.read(name), p.relative_to(source).as_posix() + '!' + name, ext)
    groups = {}
    for r in records.values():
        # Keep format variants and differently encoded files: similar is not identical.
        s = r['sources'][0]
        key = (s['vendor'], s['category'], 'LUT' if r['format'] == 'cube' else 'Photo')
        g = groups.setdefault(key, {'vendor': key[0], 'name': key[1], 'kind': key[2], 'presets': []})
        g['presets'].append({'id': r['id'], 'name': r['name'], 'format': r['format'], 'parseError': r['parseError']})
    catalogue = sorted(groups.values(), key=lambda g: (g['kind'], g['vendor'], g['name']))
    for g in catalogue:
        g['presets'].sort(key=lambda r: r['name'].casefold())
    summary = {'sourceOccurrences': occurrences, 'retainedFiles': len(records),
        'exactDuplicatesRemoved': occurrences - len(records), 'categories': len(catalogue),
        'formats': dict(Counter(r['format'] for r in records.values())),
        'parseErrors': sum(bool(r['parseError']) for r in records.values()),
        'bytesCopied': sum(r['bytes'] for r in records.values()),
        'dedupRule': 'Exact SHA-256 content only. Different encodings and format variants retained. No visual similarity deduplication.'}
    for filename, obj in [('manifest.json', {'summary': summary, 'assets': list(records.values())}), ('catalog.json', catalogue), ('summary.json', summary)]:
        (dest / filename).write_text(json.dumps(obj, ensure_ascii=False, indent=2))
    browse = {}
    for family in ['Wedding', 'Drone', 'Trending']:
        items = [r for r in records.values() if r['format'] != 'cube' and any('/' + family + '/' in a['source'] for a in r['sources'])]
        browse[family + ' · Huliluts'] = ['Original'] + [r['name'] + ' [' + r['format'].upper() + ']' for r in sorted(items, key=lambda r: r['name'].casefold())]
    for g in catalogue:
        if g['kind'] == 'Photo':
            browse[g['name'] + ' · ' + g['vendor'].replace('The Ultimate Preset Bundle - ', '')] = ['Original'] + [r['name'] + ' [' + r['format'].upper() + ']' for r in g['presets']]
    (dest / 'browse-catalog.json').write_text(json.dumps(browse, ensure_ascii=False, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main(sys.argv[1])
