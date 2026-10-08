"""A5 experiment (2026-10-08): TinyCLIP zero-shot "is there a distinct subject" as a veto on the current Android rule.
Experimental only; nothing is bundled. Model: wkcn/TinyCLIP-ViT-8M-16-Text-3M-YFCC15M (MIT weights, YFCC-15M), run in an
isolated scratch environment (torch, transformers).

Rule: subject = current rule (U2-Netp confident area >= 2 %) AND p_subject >= T, where p_subject is the softmax (CLIP
logit scale) mass of the SUBJECT prompts against SUBJECT + NONE prompts. Prompts below are fixed before any model run.
T is chosen on the development photos only (original 156 + the 130-photo extension): the largest T that keeps at least
95 % of the subjects the current rule finds there. Prompts, scoring and T are frozen in tinyclip-a5-frozen.json before
the untouched 100-photo validation set is run, once.

Provisional engineering targets for the validation run (not owner-approved acceptance), each against the current rule
on the same photos:
  E1 subjects found >= current rule's count - 1 (a missed subject blocks Change background for that photo, the worse
     failure, so the veto may cost at most one of the 12);
  E2 false subjects <= half the current rule's (a real no-subject signal must remove most of them, not trim a few);
  E3 no subject type (vehicles, plants and flowers, statues and figures, structures and signs) loses more than one photo
     relative to the current rule.
"""
import os, sys, json, time
import numpy as np, torch
from PIL import Image, ImageOps
from transformers import CLIPModel, CLIPProcessor
HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, '..', 'work')
PD = os.path.join(HERE, '..', '..', 'auto/data/pd12m/eval_originals')
MODEL = "wkcn/TinyCLIP-ViT-8M-16-Text-3M-YFCC15M"
SUBJECT = ["a photo of a statue", "a photo of a sculpture", "a photo of a building", "a photo of a monument",
           "a photo of a car", "a photo of a vehicle", "a photo of a boat", "a photo of an animal", "a photo of a bird",
           "a photo of a flower", "a photo of a potted plant", "a photo of a vase", "a photo of a sign",
           "a photo of a tower", "a close-up photo of a single object", "a photo of an object on a table"]
NONE = ["a photo of a landscape", "a photo of the sky", "a photo of a street", "a photo of a room interior",
        "a photo of a church interior", "a photo of a forest", "a photo of a beach", "a photo of a city skyline",
        "a photo of a field", "a photo of a ceiling", "a photo of a wall", "a photo of a sunset", "a photo of a road",
        "a photo of a crowd of buildings", "a photo of the sea", "a photo of mountains"]

def photos(which):
    if which == 'dev':
        rows = json.load(open(os.path.join(W, 'u2netp-confidence-dev.json'))) + json.load(open(os.path.join(W, 'u2netp-confidence-devext.json')))
        sel = json.load(open(os.path.join(W, 'u2netp-independent.json')))
        F = os.path.join(W, 'u2netp-fresh'); s1 = json.load(open(os.path.join(F, 'selection.json'))); s2 = json.load(open(os.path.join(F, 'selection-batch2.json')))
        ext = {x['name']: x['id'] for x in json.load(open(os.path.join(W, 'a5-devext', 'selection.json')))}
        def path(n):
            if n.startswith('indep'): return os.path.join(PD, sel[int(n[5:])]['id'] + '.jpg')
            if n.startswith('fresh-B'): return os.path.join(PD, s2[int(n[7:])]['id'] + '.jpg')
            if n.startswith('fresh-'): return os.path.join(PD, s1[int(n[6:])]['id'] + '.jpg')
            if n.startswith('dev'): return os.path.join(PD, ext[n] + '.jpg')
            if n.startswith('subject_'): return os.path.join(W, 'u2netp-edges', 'photos', n + '.jpg')
            return os.path.join(W, 'u2netp-heldout', 'photos', n + '.jpg')
        return [(r['name'], r['label'], r['area'], path(r['name'])) for r in rows]
    rows = json.load(open(os.path.join(W, 'u2netp-confidence-validation.json')))
    sel = {x['name']: x['id'] for x in json.load(open(os.path.join(W, 'a5-validation', 'selection.json')))}
    return [(r['name'], r['label'], r['area'], os.path.join(PD, sel[r['name']] + '.jpg')) for r in rows]

def scores(items):
    m = CLIPModel.from_pretrained(MODEL).eval(); p = CLIPProcessor.from_pretrained(MODEL)
    with torch.no_grad():
        t = m.text_projection(m.text_model(**p(text=SUBJECT + NONE, return_tensors='pt', padding=True)).pooler_output); t = t / t.norm(dim=-1, keepdim=True)
        out, times = [], []
        for name, label, area, path in items:
            im = ImageOps.exif_transpose(Image.open(path)).convert('RGB')
            t0 = time.perf_counter(); v = m.visual_projection(m.vision_model(pixel_values=p(images=im, return_tensors='pt')['pixel_values']).pooler_output); times.append(time.perf_counter() - t0)
            v = v / v.norm(dim=-1, keepdim=True); prob = (m.logit_scale.exp() * v @ t.T).softmax(-1)[0]
            out.append(dict(name=name, label=label, area=area, p_subject=round(float(prob[:len(SUBJECT)].sum()), 4)))
    return out, float(np.median(times))

if __name__ == '__main__':
    which = sys.argv[1]
    if which == 'validation' and not os.path.exists(os.path.join(W, 'tinyclip-a5-frozen.json')):
        sys.exit('freeze first: validation runs only with tinyclip-a5-frozen.json')
    rows, median_s = scores(photos(which))
    json.dump(dict(median_image_seconds_mac_cpu=median_s, rows=rows), open(os.path.join(W, f'tinyclip-a5-{which}.json'), 'w'), indent=1)
    print(which, len(rows), 'photos, median image time %.3f s (Mac CPU)' % median_s)
