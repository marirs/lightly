import json, sys, numpy as np
from PIL import Image
sys.path.insert(0, '.')
from litert_reference import detect_faces, landmarks
V = json.load(open('../vision_ref/vision.json'))
# FaceMesh indices: eye corners (33,133) and (362,263); outer lip ring corners/centres 61,291,0,17.
for name in ['group_three_01', 'portrait_medium_02', 'portrait_deep_02', 'portrait_deep_03', 'portrait_light_01']:
    im = Image.open(f'../photos/{name}.jpg').convert('RGB'); W, H = im.size; im.thumbnail((1600, 1600)); img = np.asarray(im, np.float32) / 255
    vf = V[name]['faces']
    for det in sorted(detect_faces(img, 'full'), key=lambda d: d['box'][0]):
        lm, pres = landmarks(img, det)
        e1 = lm[[33, 133]].mean(0); e2 = lm[[362, 263]].mean(0); lips = lm[[61, 291, 0, 17]].mean(0)
        cx = (det['box'][0] + det['box'][2]) / 2
        # Vision: y up, normalised; flip.
        best = min(vf, key=lambda f: abs(f['box'][0] + f['box'][2] / 2 - cx))
        def c(k): a = np.array(best[k]); return np.array([a[:, 0].mean(), 1 - a[:, 1].mean()])
        ve = sorted([c('leftEye'), c('rightEye')], key=lambda p: p[0]); me = sorted([e1, e2], key=lambda p: p[0])
        scale = best['box'][2]  # face width (normalised x)
        err = [np.hypot((me[i][0] - ve[i][0]) * W, (me[i][1] - ve[i][1]) * H) / (scale * W) for i in range(2)]
        lerr = np.hypot((lips[0] - c('outerLips')[0]) * W, (lips[1] - c('outerLips')[1]) * H) / (scale * W)
        print(f'{name:20s} face@{cx:.2f} presence={pres:.2f} eye err/faceW={err[0]:.3f},{err[1]:.3f} lips err/faceW={lerr:.3f}')
