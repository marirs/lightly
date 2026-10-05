"""Independent check of the experimental U²-Netp "no clear subject" rule (>= 2 % of the 320 x 320 raw saliency at
>= 0.9), on 41 PD12M photos (CC0, experiments/auto/data/pd12m/eval_originals) chosen by caption only, without
people, seeded random (20261005). Labels were set by looking at the photos before any model output
(work/u2netp-independent-labels.json). The rule is scored as it is; nothing is fitted here."""
import os, json, numpy as np
from PIL import Image, ImageOps, ImageDraw
from skimage import transform
from ai_edge_litert.interpreter import Interpreter
HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, '..', 'work'); REPO = os.path.join(HERE, '..', '..', '..')
sel = json.load(open(os.path.join(W, 'u2netp-independent.json'))); labels = json.load(open(os.path.join(W, 'u2netp-independent-labels.json')))
it = Interpreter(model_path=os.path.join(HERE, '..', 'models', 'u2netp_320_fp32.tflite')); it.allocate_tensors()
i, o = it.get_input_details()[0], it.get_output_details()[0]
M = np.array([0.485, 0.456, 0.406]); SD = np.array([0.229, 0.224, 0.225])
rows, out = [], []
for k, x in enumerate(sel):
    im = np.asarray(ImageOps.exif_transpose(Image.open(os.path.join(REPO, 'experiments/auto/data/pd12m/eval_originals', x['id'] + '.jpg'))).convert('RGB'))
    t = transform.resize(im, (320, 320), mode='constant'); t = ((t / t.max() - M) / SD).transpose(2, 0, 1)[None].astype(np.float32)
    it.set_tensor(i['index'], t); it.invoke(); d = it.get_tensor(o['index']).reshape(320, 320)
    area = float((d >= 0.9).mean()); lab = labels[str(k)]
    out.append({'index': k, 'id': x['id'], 'label': lab, 'confident_area': round(area, 4), 'rule': 'subject' if area >= 0.02 else 'none'})
    a = Image.fromarray(im); a.thumbnail((240, 240)); b = Image.fromarray((d * 255).astype(np.uint8)).resize(a.size).convert('RGB')
    row = Image.new('RGB', (480, a.height + 16), 'white'); row.paste(a, (0, 16)); row.paste(b, (240, 16))
    ImageDraw.Draw(row).text((2, 2), f"{k} label={lab} area={area*100:.1f}% rule={'subject' if area >= .02 else 'none'}", fill='black'); rows.append(row)
cols = 4; h = max(r.height for r in rows); sheet = Image.new('RGB', (480 * cols, h * ((len(rows) + cols - 1) // cols)), 'white')
for k, r in enumerate(rows): sheet.paste(r, ((k % cols) * 480, (k // cols) * h))
sheet.save(os.path.join(W, 'u2netp-independent-sheet.jpg'), quality=80)
json.dump(out, open(os.path.join(W, 'u2netp-independent-results.json'), 'w'), indent=1)
for lab in ('subject', 'none', 'ambiguous'):
    g = [r for r in out if r['label'] == lab]
    print(f"{lab:9} n={len(g):2}  rule says subject: {sum(r['rule']=='subject' for r in g):2}   " + ' '.join(f"{r['index']}:{r['confident_area']*100:.1f}" for r in g))
