"""Held-out check of the experimental U²-Netp "no clear subject" rule (area >= 0.9 of the raw sigmoid >= 2 %),
on photos NOT used to choose it: reference preprocessing (u2net_test.py), the converted LiteRT model.
Writes a contact sheet (photo | saliency | Vision matte) and heldout.json. Labels are by visual inspection;
Vision's verdict is a second reference, not ground truth."""
import os, json, numpy as np
from PIL import Image, ImageDraw
from skimage import transform
from ai_edge_litert.interpreter import Interpreter
HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, '..', 'work', 'u2netp-heldout')
it = Interpreter(model_path=os.path.join(HERE, '..', 'models', 'u2netp_320_fp32.tflite')); it.allocate_tensors()
i, o = it.get_input_details()[0], it.get_output_details()[0]
M = np.array([0.485, 0.456, 0.406]); SD = np.array([0.229, 0.224, 0.225])
vision = json.load(open(os.path.join(W, 'vision', 'vision.json')))
rows, out = [], {}
for f in sorted(os.listdir(os.path.join(W, 'photos'))):
    n = f[:-4]; im = np.asarray(Image.open(os.path.join(W, 'photos', f)).convert('RGB'))
    x = transform.resize(im, (320, 320), mode='constant'); x = ((x / x.max() - M) / SD).transpose(2, 0, 1)[None].astype(np.float32)
    it.set_tensor(i['index'], x); it.invoke(); d = it.get_tensor(o['index']).reshape(320, 320)
    area = float((d >= 0.9).mean()); v = vision[n]
    out[n] = {'confident_area': round(area, 4), 'rule_subject': area >= 0.02, 'vision_instances': v['instances'], 'vision_faces': len(v['faces']), 'vision_humans': len(v['humans'])}
    print(n.ljust(18), out[n])
    a = Image.fromarray(im).resize((300, int(300 * im.shape[0] / im.shape[1])))
    b = Image.fromarray((d * 255).astype(np.uint8)).resize(a.size).convert('RGB')
    vp = os.path.join(W, 'vision', n + '.png'); c = Image.open(vp).convert('RGB').resize(a.size) if os.path.exists(vp) else Image.new('RGB', a.size)
    row = Image.new('RGB', (900, a.height + 22), 'white'); row.paste(a, (0, 22)); row.paste(b, (300, 22)); row.paste(c, (600, 22))
    ImageDraw.Draw(row).text((4, 4), f"{n}  U2Netp confident {area*100:.1f}% -> {'subject' if area >= .02 else 'none'} | Vision instances {v['instances']}", fill='black')
    rows.append(row)
sheet = Image.new('RGB', (900, sum(r.height for r in rows)), 'white'); y = 0
for r in rows: sheet.paste(r, (0, y)); y += r.height
sheet.save(os.path.join(W, 'heldout_sheet.jpg'), quality=85); json.dump(out, open(os.path.join(W, 'heldout.json'), 'w'), indent=1)
