"""A5 new signal, development (2026-10-08): how confident U2-Netp's saliency map is, instead of the area, shape or a
depth step of its confident region. Per photo (320 x 320 map s): area (s >= 0.9), mean s inside s >= 0.5, share of the
frame in the uncertain range 0.1 < s < 0.9, uncertain share relative to the s >= 0.5 region, mean binary entropy, the
peak (99th percentile) and the contrast mean(s | s >= 0.5) - mean(s | s < 0.5). Computed on the spent development sets
only (independent, held-out, edges, fresh); a rule chosen here is validated on work/a5-validation (labels committed in
e407ea2 before any model run)."""
import os, json, numpy as np
HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, '..', 'work')
ns = {'__file__': os.path.join(HERE, 'u2netp_shape_dev.py')}
exec(open(os.path.join(HERE, 'u2netp_shape_dev.py')).read().split("if __name__")[0], ns)
saliency, load = ns['saliency'], ns['load']
def confidence(im):
    s = saliency(im).astype(np.float64); hi = s >= 0.5; unc = (s > 0.1) & (s < 0.9)
    p = np.clip(s, 1e-6, 1 - 1e-6); ent = -(p * np.log2(p) + (1 - p) * np.log2(1 - p))
    return dict(area=round(float((s >= 0.9).mean()), 4), half=round(float(hi.mean()), 4),
                mean_hi=round(float(s[hi].mean()) if hi.any() else 0.0, 4), unc=round(float(unc.mean()), 4),
                unc_rel=round(float(unc.sum() / max(1, hi.sum())), 4), entropy=round(float(ent.mean()), 4),
                peak=round(float(np.percentile(s, 99)), 4),
                contrast=round(float(s[hi].mean() - s[~hi].mean()) if hi.any() and (~hi).any() else 0.0, 4))
if __name__ == '__main__':
    import sys
    which = sys.argv[1] if len(sys.argv) > 1 else 'dev'
    PD = os.path.join(HERE, '..', '..', 'auto/data/pd12m/eval_originals')
    rows = []
    if which == 'dev':
        dev = json.load(open(os.path.join(W, 'u2netp-shape-dev.json')))
        # Same photos and labels as the shape run, recomputed by name.
        sel = json.load(open(os.path.join(W, 'u2netp-independent.json')))
        F = os.path.join(W, 'u2netp-fresh'); s1 = json.load(open(os.path.join(F, 'selection.json'))); s2 = json.load(open(os.path.join(F, 'selection-batch2.json')))
        def path(name):
            if name.startswith('indep'): return os.path.join(PD, sel[int(name[5:])]['id'] + '.jpg')
            if name.startswith('fresh-B'): return os.path.join(PD, s2[int(name[7:])]['id'] + '.jpg')
            if name.startswith('fresh-'): return os.path.join(PD, s1[int(name[6:])]['id'] + '.jpg')
            if name.startswith('subject_'): return os.path.join(W, 'u2netp-edges', 'photos', name + '.jpg')
            return os.path.join(W, 'u2netp-heldout', 'photos', name + '.jpg')
        for r in dev: rows.append(dict(name=r['name'], label=r['label'], **confidence(load(path(r['name'])))))
        json.dump(rows, open(os.path.join(W, 'u2netp-confidence-dev.json'), 'w'), indent=1)
    elif which == 'devext':
        V = os.path.join(W, 'a5-devext'); sel = json.load(open(os.path.join(V, 'selection.json'))); lab = json.load(open(os.path.join(V, 'labels.json')))
        for x in sel: rows.append(dict(name=x['name'], label=lab[x['name']], **confidence(load(os.path.join(PD, x['id'] + '.jpg')))))
        json.dump(rows, open(os.path.join(W, 'u2netp-confidence-devext.json'), 'w'), indent=1)
    else:
        V = os.path.join(W, 'a5-validation'); sel = json.load(open(os.path.join(V, 'selection.json'))); lab = json.load(open(os.path.join(V, 'labels.json')))
        for x in sel: rows.append(dict(name=x['name'], label=lab[x['name']], **confidence(load(os.path.join(PD, x['id'] + '.jpg')))))
        json.dump(rows, open(os.path.join(W, 'u2netp-confidence-validation.json'), 'w'), indent=1)
    print(len(rows), 'rows')
