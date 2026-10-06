"""A5 diagnostic (2026-10-06): can a depth step along the U2-Netp mask boundary decide "no clear subject" where no
area threshold can (independent set: scenes up to 35.6 %, weakest subject 8.4 %)? A separable subject stands in front
of its background, so nearness just inside the mask's edge should exceed nearness just outside. Nothing fitted: the
labels were set before any model output (u2netp-independent-labels.json; held-out scenes by eye in
android-vision-evaluation.md). Depth: the app's Depth Anything V2 Small LiteRT file with DepthModelInput's
preprocessing (area resize to 518 x 392, ImageNet mean/std, NCHW); nearness normalised to the photo's p1..p99."""
import os, json, numpy as np, cv2
from PIL import Image, ImageOps
from skimage import transform
from ai_edge_litert.interpreter import Interpreter
HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, '..', 'work'); REPO = os.path.join(HERE, '..', '..', '..')
u2 = Interpreter(model_path=os.path.join(HERE, '..', 'models', 'u2netp_320_fp32.tflite')); u2.allocate_tensors()
da = Interpreter(model_path=os.path.join(REPO, 'experiments/depth/models/converted/da2_small_518x392_wi8.tflite')); da.allocate_tensors()
MEAN = np.array([0.485, 0.456, 0.406]); STD = np.array([0.229, 0.224, 0.225])
def saliency(im):
    t = transform.resize(im, (320, 320), mode='constant'); t = ((t / t.max() - MEAN) / STD).transpose(2, 0, 1)[None].astype(np.float32)
    u2.set_tensor(u2.get_input_details()[0]['index'], t); u2.invoke(); return u2.get_tensor(u2.get_output_details()[0]['index']).reshape(320, 320)
def nearness(im):
    x = cv2.resize(im.astype(np.float32) / 255, (518, 392), interpolation=cv2.INTER_AREA)
    x = ((x - MEAN) / STD).transpose(2, 0, 1)[None].astype(np.float32)
    da.set_tensor(da.get_input_details()[0]['index'], x); da.invoke(); d = da.get_tensor(da.get_output_details()[0]['index']).reshape(392, 518)
    lo, hi = np.percentile(d, [1, 99]); return np.clip((d - lo) / max(hi - lo, 1e-6), 0, 1)   # larger = nearer (disparity)
def step(im):
    s = saliency(im); mask = (s >= 0.9).astype(np.uint8); area = float(mask.mean())
    if area < 0.005: return area, None
    n = cv2.resize(nearness(im), (320, 320), interpolation=cv2.INTER_LINEAR)
    k = np.ones((7, 7), np.uint8); inner = (mask - cv2.erode(mask, k)) > 0; outer = (cv2.dilate(mask, k) - mask) > 0
    # ignore the frame border: a mask touching the edge has no outside there
    border = np.zeros_like(mask, bool); border[:4] = border[-4:] = True; border[:, :4] = border[:, -4:] = True
    inner &= ~border; outer &= ~border
    if inner.sum() < 20 or outer.sum() < 20: return area, None
    return area, float(np.median(n[inner]) - np.median(n[outer]))
rows = []
sel = json.load(open(os.path.join(W, 'u2netp-independent.json'))); labels = json.load(open(os.path.join(W, 'u2netp-independent-labels.json')))
for k, x in enumerate(sel):
    im = np.asarray(ImageOps.exif_transpose(Image.open(os.path.join(REPO, 'experiments/auto/data/pd12m/eval_originals', x['id'] + '.jpg'))).convert('RGB'))
    rows.append(('indep%02d' % k, labels[str(k)]) + step(im))
for n in ('landscape_01', 'night_01', 'night_02', 'sunset_01', 'sunset_03', 'wellexposed_01', 'wellexposed_02', 'wellexposed_03'):
    rows.append((n, 'none') + step(np.asarray(Image.open(os.path.join(W, 'u2netp-heldout', 'photos', n + '.jpg')).convert('RGB'))))
for n in ('subject_boat', 'subject_swan'):
    rows.append((n, 'subject') + step(np.asarray(ImageOps.exif_transpose(Image.open(os.path.join(W, 'u2netp-edges', 'photos', n + '.jpg'))).convert('RGB'))))
json.dump(rows, open(os.path.join(W, 'u2netp-depth-step.json'), 'w'), indent=1)
for lab in ('subject', 'none', 'ambiguous'):
    g = [r for r in rows if r[1] == lab]
    print(f"{lab:9} n={len(g):2} " + ' '.join(f"{r[0]}:{r[2]*100:.1f}%/{'-' if r[3] is None else '%+.2f' % r[3]}" for r in g))
