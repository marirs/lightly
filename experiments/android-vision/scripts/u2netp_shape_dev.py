"""A5 new signal, development (2026-10-07): the shape of U2-Netp's confident region instead of its area or a depth step.
Features of the mask s >= 0.9 (320 x 320): border = share of the 4-px frame band covered by the mask; components = number
of connected components holding >= 0.2 % of the frame; largest = share of the mask in its largest component. Computed on
the spent sets only (independent, held-out, edges, fresh); the rule chosen here is validated on a new labelled set."""
import os, json, sys, numpy as np, cv2
from PIL import Image, ImageOps
HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, '..', 'work'); REPO = os.path.join(HERE, '..', '..', '..')
src = open(os.path.join(HERE, 'u2netp_depth_step.py')).read().split('rows = []')[0].replace("da = Interpreter(", "da = None and Interpreter(").replace("; da.allocate_tensors()", "")
ns = {'__file__': os.path.join(HERE, 'u2netp_depth_step.py')}; exec(src, ns); saliency = ns['saliency']
def features(im):
    s = saliency(im); mask = (s >= 0.9).astype(np.uint8); area = float(mask.mean())
    band = np.zeros_like(mask, bool); band[:4] = band[-4:] = True; band[:, :4] = band[:, -4:] = True
    border = float(mask[band].mean())
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    sizes = sorted([stats[i, cv2.CC_STAT_AREA] for i in range(1, n)], reverse=True)
    big = [x for x in sizes if x >= 0.002 * mask.size]
    largest = sizes[0] / max(1, mask.sum()) if sizes else 0.0
    return dict(area=round(area, 4), border=round(border, 4), components=len(big), largest=round(float(largest), 3))
def load(p): return np.asarray(ImageOps.exif_transpose(Image.open(p)).convert('RGB'))
if __name__ == '__main__':
    rows = []
    PD = os.path.join(REPO, 'experiments/auto/data/pd12m/eval_originals')
    sel = json.load(open(os.path.join(W, 'u2netp-independent.json'))); lab = json.load(open(os.path.join(W, 'u2netp-independent-labels.json')))
    for k, x in enumerate(sel): rows.append(dict(name='indep%02d' % k, label=lab[str(k)], **features(load(os.path.join(PD, x['id'] + '.jpg')))))
    for n in ('landscape_01', 'night_01', 'night_02', 'sunset_01', 'sunset_03', 'wellexposed_01', 'wellexposed_02', 'wellexposed_03'):
        rows.append(dict(name=n, label='none', **features(load(os.path.join(W, 'u2netp-heldout', 'photos', n + '.jpg')))))
    for n in ('subject_boat', 'subject_swan'):
        rows.append(dict(name=n, label='subject', **features(load(os.path.join(W, 'u2netp-edges', 'photos', n + '.jpg')))))
    F = os.path.join(W, 'u2netp-fresh')
    for self, labf, pre in (('selection.json', 'labels-batch1.json', ''), ('selection-batch2.json', 'labels-batch2.json', 'B')):
        s2 = json.load(open(os.path.join(F, self))); l2 = json.load(open(os.path.join(F, labf)))
        for k, x in enumerate(s2): rows.append(dict(name='fresh-' + pre + str(k), label=l2[pre + str(k)], **features(load(os.path.join(PD, x['id'] + '.jpg')))))
    json.dump(rows, open(os.path.join(W, 'u2netp-shape-dev.json'), 'w'), indent=1)
