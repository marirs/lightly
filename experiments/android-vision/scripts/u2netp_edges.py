"""Android object cut-out edges (offline, same steps as the app): display image (1600 long edge), U²-Netp raw saliency
with the reference preprocessing, MatteRefiner (bilinear to the display size, guided filter on luma, r = 0.25 % of the
long edge = 4 px, eps 1e-3). Measured against Apple Vision's foreground matte for the same photo (a reference, not
ground truth): mean |difference| in the edge band, and the halo on a dark replacement: mean luma in the 1–12 px ring
just outside Vision's subject edge (it should be the replacement's). Candidates are listed, nothing is chosen here."""
import os, numpy as np, cv2
from PIL import Image
from skimage import transform
from ai_edge_litert.interpreter import Interpreter
HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, '..', 'work', 'u2netp-edges')  # photos/ and vision/ (Vision mattes)
it = Interpreter(model_path=os.path.join(HERE, '..', 'models', 'u2netp_320_fp32.tflite')); it.allocate_tensors()
i, o = it.get_input_details()[0], it.get_output_details()[0]
M = np.array([0.485, 0.456, 0.406]); SD = np.array([0.229, 0.224, 0.225])
def box(x, r): return cv2.boxFilter(x, -1, (2 * r + 1, 2 * r + 1), normalize=True, borderType=cv2.BORDER_REFLECT)
def guided(I, p, r, eps):
    mI, mp = box(I, r), box(p, r); a = (box(I * p, r) - mI * mp) / (box(I * I, r) - mI * mI + eps); b = mp - a * mI
    return box(a, r) * I + box(b, r)
def lin(e): return np.where(e <= 0.04045, e / 12.92, ((e + 0.055) / 1.055) ** 2.4)
def guided_rgb(I, p, r, eps):
    h, w, _ = I.shape; mI = np.stack([box(I[..., c], r) for c in range(3)], -1); mp = box(p, r)
    cov = np.stack([box(I[..., c] * p, r) for c in range(3)], -1) - mI * mp[..., None]
    var = np.zeros((h, w, 3, 3))
    for a_ in range(3):
        for b_ in range(3): var[..., a_, b_] = box(I[..., a_] * I[..., b_], r) - mI[..., a_] * mI[..., b_]
    var += eps * np.eye(3); a = np.linalg.solve(var, cov[..., None])[..., 0]; b = mp - (a * mI).sum(-1)
    return (np.stack([box(a[..., c], r) for c in range(3)], -1) * I).sum(-1) + box(b, r)
def sharpen(m, lo=0.4, hi=0.6):
    t = np.clip((m - lo) / (hi - lo), 0, 1); return t * t * (3 - 2 * t)
rows = {}
for name in sorted(f[:-4] for f in os.listdir(os.path.join(W, 'photos'))):
    full = np.asarray(Image.open(os.path.join(W, 'photos', name + '.jpg')).convert('RGB'))
    s = 1600 / max(full.shape[:2]); disp = cv2.resize(full, (round(full.shape[1] * s), round(full.shape[0] * s)), interpolation=cv2.INTER_AREA)
    h, w, _ = disp.shape
    x = transform.resize(disp, (320, 320), mode='constant'); x = ((x / x.max() - M) / SD).transpose(2, 0, 1)[None].astype(np.float32)
    it.set_tensor(i['index'], x); it.invoke(); low = it.get_tensor(o['index']).reshape(320, 320).astype(np.float64)
    up = cv2.resize(low, (w, h), interpolation=cv2.INTER_LINEAR)
    luma = (0.299 * disp[..., 0] + 0.587 * disp[..., 1] + 0.114 * disp[..., 2]) / 255.
    ref = cv2.resize(np.asarray(Image.open(os.path.join(W, 'vision', name + '.png')).convert('L')) / 255., (w, h))
    band = cv2.dilate(((ref > .02) & (ref < .98)).astype(np.uint8), np.ones((9, 9))) > 0
    inside = (ref > .5).astype(np.uint8); ring = (cv2.dilate(inside, np.ones((25, 25))) > 0) & (cv2.dilate(inside, np.ones((3, 3))) == 0)
    dark = lin(np.array([0x1F, 0x23, 0x28]) / 255.)
    cands = {'C0 current': np.clip(guided(luma, up, 4, 1e-3), 0, 1),
             'C1 sharpen+luma r4': np.clip(guided(luma, sharpen(up), 4, 1e-3), 0, 1),
             'C2 sharpen+colour r4': np.clip(guided_rgb(disp / 255., sharpen(up), 4, 1e-3), 0, 1)}
    for name_c, m in cands.items():
        out = lin(disp / 255.) * m[..., None] + dark * (1 - m[..., None])
        halo = (0.2126 * out[..., 0] + 0.7152 * out[..., 1] + 0.0722 * out[..., 2])[ring].mean() / (0.2126 * dark[0] + 0.7152 * dark[1] + 0.0722 * dark[2])
        soft = ((m > .05) & (m < .95)).sum() / max(1, ((ref > .05) & (ref < .95)).sum())
        rows.setdefault(name_c, []).append((np.abs(m - ref)[band].mean(), halo, soft))
        print(f"{name:13} {name_c:22} band MAD vs Vision {np.abs(m - ref)[band].mean():.3f}  ring luma / replacement luma {halo:.2f}  soft-edge area / Vision's {soft:.1f}  matte>0.5 outside Vision {((m>.5)&(ref<.05)).sum()/ (ref>.5).sum()*100:.1f}% of subject")
print('mean over photos:')
for k, v in rows.items(): v = np.array(v); print(f"  {k:22} band MAD {v[:,0].mean():.3f}  ring/replacement {v[:,1].mean():.2f}  soft area x{v[:,2].mean():.1f}")
