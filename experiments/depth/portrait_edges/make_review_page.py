"""A4 blind visual review page (2026-10-07): one local page for the owner, built from the fresh-set composites of the
shipped pipeline and candidate 2 (out/hair-projection/chroma), in the left/right order of the sealed key
(out/a4-blind-key/key.json, never copied into the page). Output: out/a4-review/index.html with full-resolution images.

This review is a separate visual assessment. It does not replace or rescore the candidate's failed experiment
(results/hair-fresh/README.md), and a tie between two defective outputs is not release acceptance.
Edge crops: the two 512 px windows (at full resolution) where the A and B images differ most, so the reviewer starts at
the hair edges; every image also opens at full size with synchronised zoom and scroll."""
import json, os, shutil, html
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'out', 'hair-projection', 'chroma')
KEY = os.path.join(HERE, '..', 'out', 'a4-blind-key', 'key.json')
OUT = os.path.join(HERE, '..', 'out', 'a4-review')
WIN = 512


def edge_windows(a, b, count=2):
    """Top-left corners of the `count` non-overlapping WIN x WIN windows with the largest mean |A - B|."""
    d = np.abs(np.asarray(a, np.int16) - np.asarray(b, np.int16)).sum(-1).astype(np.float64)
    step = WIN // 2
    h, w = d.shape
    scores = []
    for y in range(0, max(1, h - WIN + 1), step):
        for x in range(0, max(1, w - WIN + 1), step):
            scores.append((d[y:y + WIN, x:x + WIN].mean(), x, y))
    scores.sort(reverse=True)
    chosen = []
    for _, x, y in scores:
        if all(abs(x - cx) >= WIN or abs(y - cy) >= WIN for cx, cy in chosen):
            chosen.append((x, y))
        if len(chosen) == count:
            break
    return chosen


def main():
    key = json.load(open(KEY))
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(os.path.join(OUT, 'img'))
    pairs = []
    for pair, entry in sorted(key.items()):
        shipped = os.path.join(SRC, f"{entry['case']}-shipped.jpg")
        candidate = os.path.join(SRC, f"{entry['case']}-projected.jpg")
        a_src, b_src = (candidate, shipped) if entry['candidate'] == 'A' else (shipped, candidate)
        shutil.copy(a_src, os.path.join(OUT, 'img', f'{pair}-A.jpg'))
        shutil.copy(b_src, os.path.join(OUT, 'img', f'{pair}-B.jpg'))
        a, b = Image.open(a_src).convert('RGB'), Image.open(b_src).convert('RGB')
        crops = []
        for k, (x, y) in enumerate(edge_windows(a, b)):
            for side, im in (('A', a), ('B', b)):
                im.crop((x, y, x + WIN, y + WIN)).save(os.path.join(OUT, 'img', f'{pair}-{side}-crop{k}.png'))
            crops.append(k)
        pairs.append(dict(id=pair, width=a.width, height=a.height, crops=crops))
    page = open(os.path.join(HERE, 'review_page_template.html')).read()
    open(os.path.join(OUT, 'index.html'), 'w').write(page.replace('/*PAIRS*/[]', json.dumps(pairs)))
    print(os.path.join(OUT, 'index.html'), len(pairs))


if __name__ == '__main__':
    main()
