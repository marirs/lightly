import sys, numpy as np, pathlib
from PIL import Image
from ai_edge_litert.interpreter import Interpreter
sys.path.insert(0, '.')
from litert_reference import letterbox, ssd_anchors, iou, M
def detect_people(img, thr=0.5):
    t, pad = letterbox(img, 224)
    it = Interpreter(model_path=str(M / 'pose_landmarker/pose_detector.tflite')); it.allocate_tensors()
    it.set_tensor(it.get_input_details()[0]['index'], (t * 2 - 1)[None].astype(np.float32)); it.invoke()
    outs = [it.get_tensor(d['index'])[0] for d in it.get_output_details()]
    boxes = [o for o in outs if o.shape[-1] == 12][0]; scores = [o for o in outs if o.shape[-1] == 1][0]
    anchors = ssd_anchors(224, [8, 16, 32, 32, 32], 5, interp=1.0); assert len(anchors) == len(boxes), (len(anchors), boxes.shape)
    s = 1 / (1 + np.exp(-np.clip(scores[:, 0], -100, 100)))
    dets = []
    for i in np.argsort(-s):
        if s[i] < thr: break
        r = boxes[i]; ax, ay = anchors[i]; xc = r[0] / 224 + ax; yc = r[1] / 224 + ay; w = r[2] / 224; h = r[3] / 224
        b = [xc - w / 2, yc - h / 2, xc + w / 2, yc + h / 2]
        if all(iou(b, d[1]) <= 0.3 for d in dets): dets.append((float(s[i]), b))
    px, py = pad[0], pad[1]
    return [(sc, [(b[0] - px) / (1 - 2 * px), (b[1] - py) / (1 - 2 * py), (b[2] - px) / (1 - 2 * px), (b[3] - py) / (1 - 2 * py)]) for sc, b in dets]
for p in sorted(pathlib.Path('../photos').glob('*.jpg')):
    im = Image.open(p).convert('RGB'); im.thumbnail((1600, 1600)); img = np.asarray(im, np.float32) / 255
    print(f'{p.stem:20s}', [(round(sc, 2), [round(float(v), 2) for v in b]) for sc, b in detect_people(img)])
