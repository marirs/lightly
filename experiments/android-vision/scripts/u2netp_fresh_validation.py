"""A5 validation (2026-10-06): the frozen rule "confident area >= 2 % and depth step >= 0.1" (u2netp_depth_step.py;
threshold read off the earlier sets) scored on the fresh labelled set (work/u2netp-fresh; labels committed before this
ran). Nothing is changed here."""
import os, json, numpy as np, importlib.util
from PIL import Image, ImageOps
HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, '..', 'work'); REPO = os.path.join(HERE, '..', '..', '..')
spec = importlib.util.spec_from_file_location('ds', os.path.join(HERE, 'u2netp_depth_step.py'))
src = open(os.path.join(HERE, 'u2netp_depth_step.py')).read().split('rows = []')[0]
ns = {'__file__': os.path.join(HERE, 'u2netp_depth_step.py')}; exec(src, ns); step = ns['step']
F = os.path.join(W, 'u2netp-fresh')
sets = [(json.load(open(os.path.join(F, 'selection.json'))), json.load(open(os.path.join(F, 'labels-batch1.json'))), ''),
        (json.load(open(os.path.join(F, 'selection-batch2.json'))), json.load(open(os.path.join(F, 'labels-batch2.json'))), 'B')]
rows = []
for sel, labels, prefix in sets:
    for k, x in enumerate(sel):
        im = np.asarray(ImageOps.exif_transpose(Image.open(os.path.join(REPO, 'experiments/auto/data/pd12m/eval_originals', x['id'] + '.jpg'))).convert('RGB'))
        area, d = step(im)
        rows.append({'name': prefix + str(k), 'label': labels[prefix + str(k)], 'area': round(area, 4), 'step': None if d is None else round(d, 3),
                     'area_rule': area >= 0.02, 'rule': area >= 0.02 and d is not None and d >= 0.1})
json.dump(rows, open(os.path.join(F, 'results.json'), 'w'), indent=1)
for lab in ('subject', 'none', 'ambiguous'):
    g = [r for r in rows if r['label'] == lab]
    print(f"{lab:9} n={len(g):3}  area rule says subject: {sum(r['area_rule'] for r in g):3}  area+step rule says subject: {sum(r['rule'] for r in g):3}")
    for r in g:
        if lab == 'subject' or r['area_rule']: print(f"   {r['name']:5} area {r['area']*100:5.1f}%  step {r['step']}  -> {'subject' if r['rule'] else 'none'}")
