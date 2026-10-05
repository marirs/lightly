"""Goldens for Android's U²-Netp preprocessing (SubjectSaliency.input / ReferenceResize) from the reference pipeline:
u2net_test.py RescaleT(320) = skimage.transform.resize(image, (320, 320), mode='constant') and ToTensorLab(flag=0).
Writes PNG inputs (lossless, so the JVM test decodes the same bytes) and, per input, every 7th value of the resized
RGB (HWC) and of the normalised NCHW tensor, little-endian float32, plus the full tensor's max and sum.
Cases: downscale (anti-aliasing on both axes), odd-sized portrait downscale, upscale (no anti-aliasing)."""
import json, os, sys, numpy as np
from PIL import Image
from skimage import transform
import skimage
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
PHOTOS = os.environ.get('U2NETP_PHOTOS', os.path.join(REPO, 'experiments/android-vision/work/u2netp-eval/photos'))
OUT = os.path.join(REPO, 'android/core-vision/src/test/resources/u2netp')
STRIDE = 7
os.makedirs(OUT, exist_ok=True)
cases = [
    ('boat_600x400', 'subject_boat.jpg', lambda im: im.resize((600, 400), Image.LANCZOS)),
    ('swan_301x457', 'subject_swan.jpg', lambda im: im.crop((700, 100, 1001, 557))),
    ('lake_200x150', 'landscape_02.jpg', lambda im: im.resize((200, 150), Image.LANCZOS)),
]
index = {'skimage': skimage.__version__, 'stride': STRIDE, 'cases': []}
for name, src, make in cases:
    im = make(Image.open(os.path.join(PHOTOS, src)).convert('RGB'))
    im.save(os.path.join(OUT, f'{name}.png'))
    a = np.asarray(Image.open(os.path.join(OUT, f'{name}.png')).convert('RGB'))
    resized = transform.resize(a, (320, 320), mode='constant')           # HWC float64 in [0, 1]
    x = resized / np.max(resized)
    t = np.zeros_like(x)
    for c, (m, s) in enumerate(((0.485, 0.229), (0.456, 0.224), (0.406, 0.225))): t[..., c] = (x[..., c] - m) / s
    nchw = t.transpose(2, 0, 1)
    resized.reshape(-1)[::STRIDE].astype('<f4').tofile(os.path.join(OUT, f'{name}.resized.f32'))
    nchw.reshape(-1)[::STRIDE].astype('<f4').tofile(os.path.join(OUT, f'{name}.tensor.f32'))
    index['cases'].append({'name': name, 'width': a.shape[1], 'height': a.shape[0], 'resized_max': float(resized.max()),
                           'tensor_sum': float(nchw.sum())})
json.dump(index, open(os.path.join(OUT, 'index.json'), 'w'), indent=1)
print(json.dumps(index))
