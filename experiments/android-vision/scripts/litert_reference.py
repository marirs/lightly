"""Reference (numpy) implementation of the MediaPipe pre/post-processing used on Android, run with the
MediaPipe .tflite models on the LiteRT Python interpreter. Scratch: produces evidence and golden values
for the Kotlin port (android/core-vision)."""
import json, math, sys, pathlib
import numpy as np
from PIL import Image
from ai_edge_litert.interpreter import Interpreter

M = pathlib.Path(__file__).resolve().parent.parent / "models"  # models/ (MODELS.csv); .task files unzipped next to them


def bilinear(img, xs, ys):
    """img HxWxC float; xs, ys arrays of pixel-centre coordinates; zero outside (BORDER_ZERO)."""
    h, w = img.shape[:2]
    x0 = np.floor(xs - 0.5).astype(int); y0 = np.floor(ys - 0.5).astype(int)
    fx = (xs - 0.5) - x0; fy = (ys - 0.5) - y0
    out = np.zeros(xs.shape + (img.shape[2],), np.float32)
    for dy, wy in ((0, 1 - fy), (1, fy)):
        for dx, wx in ((0, 1 - fx), (1, fx)):
            xi = x0 + dx; yi = y0 + dy
            ok = (xi >= 0) & (xi < w) & (yi >= 0) & (yi < h)
            v = np.zeros(xs.shape + (img.shape[2],), np.float32)
            v[ok] = img[yi[ok], xi[ok]]
            out += v * (wx * wy)[..., None]
    return out


def warp_roi(img, cx, cy, rw, rh, angle, size_w, size_h):
    """Samples the rotated rect (centre, size in px, angle rad, x axis (cos, sin) in y-down coords)."""
    u = (np.arange(size_w) + 0.5) / size_w - 0.5
    v = (np.arange(size_h) + 0.5) / size_h - 0.5
    U, V = np.meshgrid(u, v)
    c, s = math.cos(angle), math.sin(angle)
    xs = cx + U * rw * c - V * rh * s
    ys = cy + U * rw * s + V * rh * c
    return bilinear(img, xs, ys)


def letterbox(img, size):
    h, w = img.shape[:2]
    scale = max(w, h)
    # Square ROI around the image centre, longer side = tensor side (keep_aspect_ratio, BORDER_ZERO).
    t = warp_roi(img, w / 2, h / 2, scale, scale, 0.0, size, size)
    pad_x = (1 - w / scale) / 2; pad_y = (1 - h / scale) / 2
    return t, (pad_x, pad_y, pad_x, pad_y)


def ssd_anchors(input_size, strides, num_layers, min_scale=0.1484375, max_scale=0.75, interp=1.0):
    anchors = []
    layer = 0
    while layer < num_layers:
        last_same = layer
        count = 0
        while last_same < num_layers and strides[last_same] == strides[layer]:
            # aspect_ratios [1.0] + interpolated (when interp > 0): 2 anchors per stride entry, else 1.
            count += 1 + (1 if interp > 0 else 0)
            last_same += 1
        stride = strides[layer]
        fm = math.ceil(input_size / stride)
        for y in range(fm):
            for x in range(fm):
                for _ in range(count):
                    anchors.append(((x + 0.5) / fm, (y + 0.5) / fm))
        layer = last_same
    return np.array(anchors, np.float32)


def decode(raw_boxes, raw_scores, anchors, scale, thresh):
    scores = 1 / (1 + np.exp(-np.clip(raw_scores[:, 0], -100, 100)))
    dets = []
    for i in np.nonzero(scores >= thresh)[0]:
        r = raw_boxes[i]; ax, ay = anchors[i]
        xc = r[0] / scale + ax; yc = r[1] / scale + ay; w = r[2] / scale; h = r[3] / scale
        kps = [(r[4 + 2 * k] / scale + ax, r[5 + 2 * k] / scale + ay) for k in range(6)]
        dets.append(dict(score=float(scores[i]), box=[xc - w / 2, yc - h / 2, xc + w / 2, yc + h / 2], kps=kps))
    return dets


def iou(a, b):
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0])); iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy; u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / u if u > 0 else 0


def weighted_nms(dets, thr=0.3):
    rest = sorted(dets, key=lambda d: -d['score']); out = []
    while rest:
        top = rest[0]; cands = [d for d in rest if iou(d['box'], top['box']) > thr]
        rest = [d for d in rest if iou(d['box'], top['box']) <= thr]
        if len(cands) > 1:
            wsum = sum(d['score'] for d in cands)
            box = [sum(d['box'][k] * d['score'] for d in cands) / wsum for k in range(4)]
            kps = [(sum(d['kps'][k][0] * d['score'] for d in cands) / wsum, sum(d['kps'][k][1] * d['score'] for d in cands) / wsum) for k in range(6)]
            top = dict(score=top['score'], box=box, kps=kps)
        out.append(top)
    return out


def detect_faces(img, variant):
    size, strides, layers, interp, thr, model = {
        'short': (128, [8, 16, 16, 16], 4, 1.0, 0.5, 'blaze_face_short_range.tflite'),
        'full': (192, [4], 1, 0.0, 0.6, 'blaze_face_full_range.tflite')}[variant]
    t, pad = letterbox(img, size)
    it = Interpreter(model_path=str(M / model), experimental_preserve_all_tensors=False); it.allocate_tensors()
    it.set_tensor(it.get_input_details()[0]['index'], (t * 2 - 1)[None].astype(np.float32))
    it.invoke()
    outs = {d['name']: it.get_tensor(d['index'])[0] for d in it.get_output_details()}
    boxes = [v for v in outs.values() if v.shape[-1] == 16][0]; scores = [v for v in outs.values() if v.shape[-1] == 1][0]
    anchors = ssd_anchors(size, strides, layers, interp=interp)
    assert len(anchors) == len(boxes), (len(anchors), len(boxes))
    dets = weighted_nms(decode(boxes, scores, anchors, size, thr))
    px, py = pad[0], pad[1]
    for d in dets:  # letterbox removal -> normalised image coordinates
        b = d['box']; d['box'] = [(b[0] - px) / (1 - 2 * px), (b[1] - py) / (1 - 2 * py), (b[2] - px) / (1 - 2 * px), (b[3] - py) / (1 - 2 * py)]
        d['kps'] = [((x - px) / (1 - 2 * px), (y - py) / (1 - 2 * py)) for x, y in d['kps']]
    return dets


def landmarks(img, det):
    h, w = img.shape[:2]
    b = det['box']; cx = (b[0] + b[2]) / 2 * w; cy = (b[1] + b[3]) / 2 * h
    bw = (b[2] - b[0]) * w; bh = (b[3] - b[1]) * h
    (x0, y0), (x1, y1) = det['kps'][0], det['kps'][1]
    angle = -math.atan2(-(y1 - y0) * h, (x1 - x0) * w)
    angle = (angle + math.pi) % (2 * math.pi) - math.pi
    rw, rh = bw * 1.5, bh * 1.5
    t = warp_roi(img, cx, cy, rw, rh, angle, 256, 256)
    it = Interpreter(model_path=str(M / 'face_landmarker/face_landmarks_detector.tflite')); it.allocate_tensors()
    it.set_tensor(it.get_input_details()[0]['index'], t[None].astype(np.float32))
    it.invoke()
    outs = {d['name']: it.get_tensor(d['index']) for d in it.get_output_details()}
    pts = outs['Identity'].reshape(478, 3)
    presence = float(1 / (1 + math.exp(-outs['Identity_1'].reshape(-1)[0])))
    c, s = math.cos(angle), math.sin(angle)
    u = pts[:, 0] / 256 - 0.5; v = pts[:, 1] / 256 - 0.5
    X = (cx + u * rw * c - v * rh * s) / w; Y = (cy + u * rw * s + v * rh * c) / h
    return np.stack([X, Y], 1), presence


def selfie(img):
    t = warp_roi(img, img.shape[1] / 2, img.shape[0] / 2, img.shape[1], img.shape[0], 0, 256, 256)
    it = Interpreter(model_path=str(M / 'selfie_segmenter.tflite')); it.allocate_tensors()
    it.set_tensor(it.get_input_details()[0]['index'], t[None].astype(np.float32)); it.invoke()
    return it.get_tensor(it.get_output_details()[0]['index'])[0, :, :, 0]


if __name__ == '__main__':
    photos = pathlib.Path(sys.argv[1]); out = pathlib.Path(sys.argv[2]); out.mkdir(exist_ok=True)
    report = {}
    for p in sorted(photos.glob('*.jpg')):
        im = Image.open(p).convert('RGB'); im.thumbnail((1600, 1600), Image.BILINEAR)
        img = np.asarray(im, np.float32) / 255
        entry = {}
        for variant in ('short', 'full'):
            dets = detect_faces(img, variant)
            faces = []
            for d in sorted(dets, key=lambda d: d['box'][0]):
                lm, pres = landmarks(img, d)
                faces.append(dict(score=round(d['score'], 3), box=[round(v, 4) for v in d['box']], presence=round(pres, 3),
                                  eyes=[[round(float(v), 4) for v in lm[i]] for i in (33, 263)], mouth=[round(float(v), 4) for v in lm[13]]))
            entry[variant] = faces
        m = selfie(img)
        entry['selfie_coverage'] = round(float((m > 0.5).mean()), 4)
        entry['selfie_max'] = round(float(m.max()), 3)
        Image.fromarray((m * 255).astype(np.uint8)).resize(im.size, Image.BILINEAR).save(out / f'{p.stem}__selfie.png')
        report[p.stem] = entry
        print(p.stem, 'short', [(f['score'], f['box']) for f in entry['short']], '\n   full', [(f['score'], f['presence'], f['box']) for f in entry['full']], 'selfie', entry['selfie_coverage'], entry['selfie_max'])
    json.dump(report, open(out / "mp_ref.json", "w"), indent=1, default=float)
