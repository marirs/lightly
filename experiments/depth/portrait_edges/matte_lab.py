"""Offline reproduction of Android's Background cut-out for one bounded experiment.

Current Android: MediaPipe selfie segmenter (256x256, stretched) -> bilinear to the photo -> guided filter on
luma (r = 0.25 % of long edge, eps 1e-3) -> composite with de-contamination against the original background
plate (BackgroundStage.decontaminate, f47c3c1). Candidate: the same, with the guided filter driven by the RGB
photo (He et al. colour guided filter) at a larger radius.

Reference: Apple Vision's foreground matte for the same photos (ios/Tests/Fixtures/SubjectMattes).
"""
import sys, json
import numpy as np, cv2
from PIL import Image
from ai_edge_litert.interpreter import Interpreter

REPO = '/Users/sg/Documents/Dev/Projects/lightly'
OUT = sys.argv[1] if len(sys.argv) > 1 else '/tmp'

def srgb_to_lin(e): return np.where(e <= 0.04045, e / 12.92, ((e + 0.055) / 1.055) ** 2.4)
def lin_to_srgb(l): l = np.clip(l, 0, 1); return np.where(l <= 0.0031308, l * 12.92, 1.055 * l ** (1 / 2.4) - 0.055)

def selfie(rgb):
    it = Interpreter(model_path=f'{REPO}/experiments/android-vision/models/selfie_segmenter_builtin.tflite'); it.allocate_tensors()
    i, o = it.get_input_details()[0], it.get_output_details()[0]
    x = cv2.resize(rgb.astype(np.float32), (256, 256), interpolation=cv2.INTER_AREA)[None]
    it.set_tensor(i['index'], x); it.invoke()
    return it.get_tensor(o['index']).reshape(256, 256).astype(np.float64)

_modnet = None
def modnet(rgb, short):
    """MODNet portrait matting (ZHKKKe/MODNet via Xenova/modnet ONNX, Apache-2.0): short edge `short`, sides a
    multiple of 32, (x - 0.5) / 0.5, NCHW; alpha at that size, bilinear back to the photo."""
    global _modnet
    import onnxruntime as ort
    if _modnet is None: _modnet = ort.InferenceSession('/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/out/portrait-edges-2026-10-05/modnet/model.onnx')
    h, w, _ = rgb.shape
    scale = short / min(h, w)
    nh, nw = max(32, int(round(h * scale / 32)) * 32), max(32, int(round(w * scale / 32)) * 32)
    x = cv2.resize(rgb.astype(np.float32), (nw, nh), interpolation=cv2.INTER_AREA)
    x = ((x - 0.5) / 0.5).transpose(2, 0, 1)[None].astype(np.float32)
    alpha = _modnet.run(None, {'input': x})[0][0, 0].astype(np.float64)
    return np.clip(cv2.resize(alpha, (w, h), interpolation=cv2.INTER_LINEAR), 0, 1)

def box(x, r): return cv2.boxFilter(x, -1, (2 * r + 1, 2 * r + 1), normalize=True, borderType=cv2.BORDER_REFLECT)

def guided_grey(I, p, r, eps):
    mI, mp = box(I, r), box(p, r)
    a = (box(I * p, r) - mI * mp) / (box(I * I, r) - mI * mI + eps)
    b = mp - a * mI
    return box(a, r) * I + box(b, r)

def guided_rgb(I, p, r, eps):
    h, w, _ = I.shape
    mI = np.stack([box(I[..., c], r) for c in range(3)], -1); mp = box(p, r)
    cov_Ip = np.stack([box(I[..., c] * p, r) for c in range(3)], -1) - mI * mp[..., None]
    var = np.zeros((h, w, 3, 3))
    for i in range(3):
        for j in range(3):
            var[..., i, j] = box(I[..., i] * I[..., j], r) - mI[..., i] * mI[..., j]
    var += eps * np.eye(3)
    a = np.linalg.solve(var, cov_Ip[..., None])[..., 0]
    b = mp - (a * mI).sum(-1)
    ma = np.stack([box(a[..., c], r) for c in range(3)], -1)
    return (ma * I).sum(-1) + box(b, r)

def plate(lin, matte):
    """Original background (matte < 0.1) filled into the subject: a pull-push style fill."""
    w8 = (matte < 0.1).astype(np.float64)
    num, den, out = lin * w8[..., None], w8.copy(), None
    levels = [(num, den)]
    while min(levels[-1][1].shape) > 2:
        n, d = levels[-1]
        levels.append((cv2.resize(n, (max(1, n.shape[1] // 2), max(1, n.shape[0] // 2)), interpolation=cv2.INTER_AREA),
                       cv2.resize(d, (max(1, d.shape[1] // 2), max(1, d.shape[0] // 2)), interpolation=cv2.INTER_AREA)))
    fill = levels[-1][0] / np.maximum(levels[-1][1], 1e-6)[..., None]
    for n, d in reversed(levels[:-1]):
        fill = cv2.resize(fill, (n.shape[1], n.shape[0]), interpolation=cv2.INTER_LINEAR)
        a = np.clip(d * 4, 0, 1)[..., None] if False else np.clip(d, 0, 1)[..., None]
        fill = n / np.maximum(d, 1e-6)[..., None] * a + fill * (1 - a)
    return fill

def composite(lin, matte, B, repl):
    a = np.clip(matte, 0, 1)[..., None]
    F = np.clip((lin - (1 - a) * B) / np.maximum(a, 0.05), 0, 1)
    return F * a + repl * (1 - a)

def run(name):
    rgb = np.asarray(Image.open(f'{REPO}/docs/ui/assets/photos/{name}.jpg').convert('RGB')) / 255.0
    ref = np.asarray(Image.open(f'{REPO}/ios/Tests/Fixtures/SubjectMattes/{name}.png').convert('L')) / 255.0
    h, w, _ = rgb.shape
    lin = srgb_to_lin(rgb)
    low = selfie(rgb)
    up = cv2.resize(low, (w, h), interpolation=cv2.INTER_LINEAR)
    luma = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    r0 = max(1, round(max(w, h) * 0.0025))
    cands = {'current-luma-r4': np.clip(guided_grey(luma, up, r0, 1e-3), 0, 1)}
    cands['modnet-512'] = modnet(rgb, 512)
    def sstep(x, lo, hi): t = np.clip((x - lo) / (hi - lo), 0, 1); return t * t * (3 - 2 * t)
    for lo, hi in ():
        sharp = sstep(up, lo, hi)
        cands[f'sharp{lo}-{hi}-luma-r4'] = np.clip(guided_grey(luma, sharp, r0, 1e-3), 0, 1)
        for r in (12,):
            cands[f'sharp{lo}-{hi}-rgb-r{r}'] = np.clip(guided_rgb(rgb, sharp, r, 1e-4), 0, 1)
    band = (cv2.dilate(((ref > 0.02) & (ref < 0.98)).astype(np.uint8), np.ones((9, 9))) > 0)
    results = {}
    from pymatting import estimate_foreground_ml
    cands = {k: v for k, v in cands.items() if k in ('current-luma-r4', 'modnet-512')}
    fg = {k: np.clip(estimate_foreground_ml(lin, m), 0, 1) for k, m in cands.items()}
    for k in list(cands):
        cands[k + '+fgml'] = cands[k]
    for k, m in cands.items():
        B = plate(lin, m)
        res = {'band_mad_vs_vision': float(np.abs(m - ref)[band].mean()),
               'iou_vs_vision': float(((m > 0.5) & (ref > 0.5)).sum() / ((m > 0.5) | (ref > 0.5)).sum())}
        for tag, hexc in (('light', (0xF4, 0xF1, 0xEC)), ('dark', (0x1F, 0x23, 0x28))):
            repl = srgb_to_lin(np.array(hexc) / 255.0)
            if k.endswith('+fgml'):
                out = lin_to_srgb(fg[k[:-5]] * np.clip(m, 0, 1)[..., None] + repl * (1 - np.clip(m, 0, 1)[..., None]))
            else:
                out = lin_to_srgb(composite(lin, m, B, repl))
            cyan = np.clip((out[..., 1] + out[..., 2]) / 2 - out[..., 0], 0, 1)
            res[f'{tag}_band_cyan_excess'] = float(cyan[band].mean() * 255)
            truth = lin_to_srgb(composite(lin, ref, plate(lin, ref), repl))
            redx = np.clip(out[..., 0] - (out[..., 1] + out[..., 2]) / 2, 0, 1)
            res[f'{tag}_band_dE_vs_vision_composite'] = float(np.abs(out - truth)[band].mean() * 255)
            res[f'{tag}_band_red_excess'] = float(redx[band].mean() * 255)
            Image.fromarray((out * 255 + 0.5).astype(np.uint8)).save(f'{OUT}/{name}__{k}__{tag}.png')
        Image.fromarray((m * 255 + 0.5).astype(np.uint8)).save(f'{OUT}/{name}__{k}__matte.png')
        results[k] = res
    Image.fromarray((ref * 255).astype(np.uint8)).save(f'{OUT}/{name}__vision__matte.png')
    return results

if __name__ == '__main__':
    import os; os.makedirs(OUT, exist_ok=True)
    allr = {n: run(n) for n in ('portrait_medium_02', 'portrait_deep_03')}
    json.dump(allr, open(f'{OUT}/results.json', 'w'), indent=1)
    for n, rs in allr.items():
        print(n)
        for k, r in rs.items(): print(f'  {k:18}', ' '.join(f'{m}={v:.3f}' for m, v in r.items()))
