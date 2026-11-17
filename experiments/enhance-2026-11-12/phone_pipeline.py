"""Enhance step 2c: the full Enhance pipeline exactly as the phone harnesses run it (Mac copy, for comparison).

phone/EnhancePipeline.kt (Android) and phone/EnhancePipelineTests.swift (iOS) implement the same steps with the same
plain float maths, so a phone output that differs from this one points at the model runtimes (Core ML fp16, LiteRT GPU),
not at a different resize or blur. Steps per photo (RGB, float32 in 0-255 throughout, rounded only at the end):

 1. Painting check: five 224 px views (export_art_classifier.five_views_uint8 geometry, PIL-style bilinear resize,
    rounded to uint8) -> art classifier; art probability >= ART_THRESHOLD skips the faces (step 1f).
 2. Faces: RetinaFace MobileNet-0.25 (export_face_detector.py) on the photo resized to short side 640 and 960, each
    drawn at the top left of a fixed square canvas filled with the network's mean colour; score > 0.8, NMS 0.4, eye
    gap >= 5 px (CodeFormer's settings); 960 detections kept only where no 640 box overlaps (IoU < 0.3) (step 2b).
    Faces whose detector eye gap is under RESTORE_EYE_GAP_MIN (8 px) are recorded but left to the background upscale:
    below that CodeFormer invents the face rather than restoring it (step 2g).
 3. Face points: Face Mesh V2 on a rotated crop (box x 1.5, rolled to the detector's eye line), refined once on its
    own points; its iris centres, nose tip and mouth corners are used when its face presence is >= 0.5, otherwise
    the detector's five points.
 4. Alignment: least-squares similarity onto CodeFormer's 512 template (CodeFormer uses cv2.estimateAffinePartial2D
    with LMEDS; with five good points the two agree closely, measured in README step 2c); bilinear warp, grey border.
 5. CodeFormer w = 0.8, then the original colour (colour_from_original.py: Lab, guided filter radius 8, eps 1e-3);
    grey photos (CodeFormer's is_gray) go grey and take the crop's channel means and spreads (its adain_npy).
 6. Paste mask: selfie multiclass on the restored face (512 -> 256), face-skin class, enclosed holes filled; blurred
    twice (101 px, sigma 11), 10 px edge cleared, combined with CodeFormer's eroded and blurred square mask.
 7. Background: realesr-general-x4v3 on evenly spaced 384 px tiles with at least 16 px of context (step 2e; equal to
    one pass over the photo), 4x output averaged 2 x 2 to 2x.
 8. Each face warped back (bilinear) and blended with its mask.

Differences from CodeFormer's own pipeline, all measured against it in README step 2c: least squares instead of
LMEDS, bilinear instead of OpenCV's fixed-point and bicubic warps, PIL-style resizes, tiled background with a 2 x 2
average instead of one whole-image pass and a Lanczos reduction.

Outputs: outputs/phone-pipeline/mac/<id>.png and <id>.json (detections, points, art score, times).
Run: .venv/bin/python phone_pipeline.py [photo ids...]
"""
import json
import math
import os
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REAL = HERE / "outputs" / "real"
OUT = HERE / "outputs" / "phone-pipeline" / "mac"
TFLITE = HERE / "tflite"

SCALE = 2
FIDELITY = 0.8
ART_THRESHOLD = 0.8
DETECTION_SIZES = {640: 1024, 960: 1536}   # short side -> square canvas (export_face_detector.CANVASES)
DETECTOR_MEAN_RGB = np.array([123.0, 117.0, 104.0], np.float32)
SCORE_THRESHOLD, NMS_THRESHOLD, EXTRA_IOU, EYE_GAP_MIN = 0.8, 0.4, 0.3, 5.0
# Step 2g (size_cutoff_study.py): restoring still scores closer to the truth at 6 px, but by eye the 6 px faces are
# invented (teeth, smiles, glasses lost); from 8 px they are mostly faithful. Owner chose 8 px (2026-11-16).
RESTORE_EYE_GAP_MIN = 8.0
INPUT_LONG_SIDE_MAX = 2000   # owner, 2026-11-17: larger photos are shrunk to this long side first (output 2x that)
MESH_FIVE = [468, 473, 1, 61, 291]
MESH_PRESENCE_MIN = 0.5
FACE_SKIN = 3
FACE_TEMPLATE = np.array([[192.98138, 239.94708], [318.90277, 240.1936], [256.63416, 314.01935],
                          [201.26117, 371.41043], [313.08905, 371.15118]], np.float64)
CROP_BORDER_RGB = np.array([132.0, 133.0, 135.0], np.float32)   # CodeFormer's borderValue (135, 133, 132) in BGR
# Step 2e: 384 px windows with at least 16 px of context on every inner side (step 2c: 256 px clamped, 10 px, whose
# seams left up to 30 of 255 against one pass over the photo; tile_study.py). PIPELINE_TILE=512 selects 512 px windows.
TILE, TILE_PAD = int(os.environ.get("PIPELINE_TILE", "384")), 16


# ---------------------------------------------------------------------------------------------------------------------
# Image maths shared with the phones (float32, HxWxC)

def resample_weights(in_size: int, out_size: int) -> np.ndarray:
    """PIL's bilinear (triangle) resampling weights, antialiased when shrinking: [out_size, in_size]."""
    scale = in_size / out_size
    filter_scale = max(scale, 1.0)
    support = filter_scale
    weights = np.zeros((out_size, in_size), np.float64)
    for x in range(out_size):
        centre = (x + 0.5) * scale
        lo = max(int(centre - support + 0.5), 0)
        hi = min(int(centre + support + 0.5), in_size)
        taps = np.arange(lo, hi)
        w = np.maximum(0.0, 1.0 - np.abs((taps - centre + 0.5) / filter_scale))
        if w.sum() > 0:
            weights[x, lo:hi] = w / w.sum()
    return weights.astype(np.float32)


def resize(image: np.ndarray, width: int, height: int) -> np.ndarray:
    wy = resample_weights(image.shape[0], height)
    wx = resample_weights(image.shape[1], width)
    return np.einsum("yi,ijc,xj->yxc", wy, image.astype(np.float32), wx, optimize=True).astype(np.float32)


def warp_bilinear(source: np.ndarray, to_source: np.ndarray, width: int, height: int, border) -> np.ndarray:
    """Output pixel (u, v) samples the source at to_source @ (u, v, 1), pixel centres on integers (OpenCV's
    convention); taps outside the source take `border`."""
    u, v = np.meshgrid(np.arange(width, dtype=np.float64), np.arange(height, dtype=np.float64))
    x = to_source[0, 0] * u + to_source[0, 1] * v + to_source[0, 2]
    y = to_source[1, 0] * u + to_source[1, 1] * v + to_source[1, 2]
    x0, y0 = np.floor(x).astype(np.int64), np.floor(y).astype(np.int64)
    fx, fy = (x - x0).astype(np.float32)[..., None], (y - y0).astype(np.float32)[..., None]
    h, w = source.shape[:2]
    channels = source.shape[2]
    border = np.broadcast_to(np.asarray(border, np.float32), (channels,))

    def tap(yy, xx):
        inside = (xx >= 0) & (xx < w) & (yy >= 0) & (yy < h)
        values = source[np.clip(yy, 0, h - 1), np.clip(xx, 0, w - 1)].astype(np.float32)
        return np.where(inside[..., None], values, border)

    top = tap(y0, x0) * (1 - fx) + tap(y0, x0 + 1) * fx
    bottom = tap(y0 + 1, x0) * (1 - fx) + tap(y0 + 1, x0 + 1) * fx
    return (top * (1 - fy) + bottom * fy).astype(np.float32)


def gaussian_kernel(size: int, sigma: float) -> np.ndarray:
    """OpenCV's getGaussianKernel, including its fixed kernels for sizes up to 7 when sigma <= 0."""
    fixed = {1: [1.0], 3: [0.25, 0.5, 0.25], 5: [0.0625, 0.25, 0.375, 0.25, 0.0625],
             7: [0.03125, 0.109375, 0.21875, 0.28125, 0.21875, 0.109375, 0.03125]}
    if sigma <= 0 and size in fixed:
        return np.array(fixed[size], np.float32)
    if sigma <= 0:
        sigma = 0.3 * ((size - 1) * 0.5 - 1) + 0.8
    x = np.arange(size) - (size - 1) / 2
    k = np.exp(-(x * x) / (2 * sigma * sigma))
    return (k / k.sum()).astype(np.float32)


def reflect101_index(index: np.ndarray, size: int) -> np.ndarray:
    if size == 1:
        return np.zeros_like(index)
    period = 2 * size - 2
    index = np.mod(index, period)
    return np.where(index < size, index, period - index)


def reflect_index(index: np.ndarray, size: int) -> np.ndarray:
    """OpenCV BORDER_REFLECT: fedcba|abcdefgh|hgfedcb."""
    period = 2 * size
    index = np.mod(index, period)
    return np.where(index < size, index, period - 1 - index)


def gaussian_blur(plane: np.ndarray, size: int, sigma: float) -> np.ndarray:
    """2-D plane, OpenCV GaussianBlur with BORDER_REFLECT_101."""
    k = gaussian_kernel(size, sigma)
    r = size // 2
    out = plane.astype(np.float32)
    for axis in (1, 0):
        n = out.shape[axis]
        acc = np.zeros_like(out)
        for i, weight in enumerate(k):
            idx = reflect101_index(np.arange(n) + i - r, n)
            acc += weight * np.take(out, idx, axis=axis)
        out = acc
    return out


def erode(plane: np.ndarray, size: int) -> np.ndarray:
    """OpenCV erode with a size x size rectangle (anchor size // 2); outside the image counts as the maximum."""
    if size <= 1:
        return plane.copy()
    anchor = size // 2
    out = plane.astype(np.float32)
    for axis in (1, 0):
        n = out.shape[axis]
        acc = np.full_like(out, np.inf)
        for i in range(size):
            idx = np.arange(n) + i - anchor
            inside = (idx >= 0) & (idx < n)
            values = np.take(out, np.clip(idx, 0, n - 1), axis=axis)
            shape = [1, 1]
            shape[axis] = n
            values = np.where(inside.reshape(shape), values, np.inf)
            acc = np.minimum(acc, values)
        out = acc
    return out


def box_mean_reflect(plane: np.ndarray, radius: int) -> np.ndarray:
    out = plane.astype(np.float32)
    for axis in (1, 0):
        n = out.shape[axis]
        acc = np.zeros_like(out)
        for i in range(-radius, radius + 1):
            acc += np.take(out, reflect_index(np.arange(n) + i, n), axis=axis)
        out = acc / (2 * radius + 1)
    return out


SRGB_TO_XYZ = np.array([[0.412453, 0.357580, 0.180423], [0.212671, 0.715160, 0.072169],
                        [0.019334, 0.119193, 0.950227]], np.float32)   # OpenCV's matrix (D65)
WHITE = np.array([0.950456, 1.0, 1.088754], np.float32)


def rgb_to_lab(rgb01: np.ndarray) -> np.ndarray:
    linear = np.where(rgb01 <= 0.04045, rgb01 / 12.92, ((rgb01 + 0.055) / 1.055) ** 2.4)
    xyz = linear @ SRGB_TO_XYZ.T / WHITE
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    y = xyz[..., 1]
    lightness = np.where(y > 0.008856, 116 * f[..., 1] - 16, 903.3 * y)
    return np.dstack([lightness, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])]).astype(np.float32)


def lab_to_rgb(lab: np.ndarray) -> np.ndarray:
    lightness, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    fy = np.where(lightness > 8.0, (lightness + 16) / 116, lightness / 903.3 * 7.787 + 16 / 116)
    y = np.where(lightness > 8.0, fy ** 3, lightness / 903.3)
    fx, fz = fy + a / 500, fy - b / 200

    def inverse(f):
        return np.where(f > 0.206893, f ** 3, (f - 16 / 116) / 7.787)

    xyz = np.dstack([inverse(fx), y, inverse(fz)]) * WHITE
    linear = xyz @ np.linalg.inv(SRGB_TO_XYZ).T.astype(np.float32)
    linear = np.clip(linear, 0, 1)
    return np.where(linear <= 0.0031308, 12.92 * linear, 1.055 * np.power(linear, 1 / 2.4) - 0.055).astype(np.float32)


def original_colour(restored: np.ndarray, original: np.ndarray, radius=8, epsilon=1e-3) -> np.ndarray:
    """colour_from_original.restored_detail_original_colour on 0-255 RGB float faces."""
    restored_lab = rgb_to_lab(np.clip(restored, 0, 255) / 255)
    original_lab = rgb_to_lab(np.clip(original, 0, 255) / 255)
    guide = restored_lab[..., 0] / 100
    mean_guide = box_mean_reflect(guide, radius)
    variance = box_mean_reflect(guide * guide, radius) - mean_guide * mean_guide
    channels = [restored_lab[..., 0]]
    for c in (1, 2):
        source = original_lab[..., c]
        mean_source = box_mean_reflect(source, radius)
        covariance = box_mean_reflect(guide * source, radius) - mean_guide * mean_source
        slope = covariance / (variance + epsilon)
        offset = mean_source - slope * mean_guide
        channels.append(box_mean_reflect(slope, radius) * guide + box_mean_reflect(offset, radius))
    return np.clip(lab_to_rgb(np.dstack(channels)), 0, 1) * 255


def is_grey(rgb: np.ndarray) -> bool:
    """CodeFormer's is_gray(threshold 10): mean variance of the channel differences."""
    r, g, b = (rgb[..., i].astype(np.int16).astype(np.float64) for i in range(3))
    return ((r - g).var() + (g - b).var() + (b - r).var()) / 3 <= 10


def grey_like(restored: np.ndarray, crop: np.ndarray) -> np.ndarray:
    """CodeFormer's bgr2gray + adain_npy for grey photos (per channel mean and std of the crop, eps 1e-5)."""
    grey = 0.2989 * restored[..., 0] + 0.5870 * restored[..., 1] + 0.1140 * restored[..., 2]
    content = np.repeat(grey[..., None], 3, 2).astype(np.float64)
    style = crop.astype(np.float64)
    c_mean, c_std = content.reshape(-1, 3).mean(0), np.sqrt(content.reshape(-1, 3).var(0) + 1e-5)
    s_mean, s_std = style.reshape(-1, 3).mean(0), np.sqrt(style.reshape(-1, 3).var(0) + 1e-5)
    return ((content - c_mean) / c_std * s_std + s_mean).astype(np.float32)


def fill_holes(face: np.ndarray) -> np.ndarray:
    """Pixels not reachable from outside the image through non-face pixels (4-connected) become face."""
    h, w = face.shape
    outside = np.zeros((h, w), bool)
    stack = [(y, x) for x in range(w) for y in (0, h - 1) if not face[y, x]]
    stack += [(y, x) for y in range(h) for x in (0, w - 1) if not face[y, x]]
    for y, x in stack:
        outside[y, x] = True
    while stack:
        y, x = stack.pop()
        for yy, xx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
            if 0 <= yy < h and 0 <= xx < w and not outside[yy, xx] and not face[yy, xx]:
                outside[yy, xx] = True
                stack.append((yy, xx))
    return ~outside


def similarity(points: np.ndarray, template: np.ndarray) -> np.ndarray:
    """Least-squares x' = a x - b y + tx, y' = b x + a y + ty: 2 x 3 photo -> face."""
    rows, values = [], []
    for (x, y), (u, v) in zip(points.astype(np.float64), template):
        rows += [[x, -y, 1, 0], [y, x, 0, 1]]
        values += [u, v]
    a, b, tx, ty = np.linalg.lstsq(np.array(rows), np.array(values), rcond=None)[0]
    return np.array([[a, -b, tx], [b, a, ty]])


def invert_affine(m: np.ndarray) -> np.ndarray:
    full = np.vstack([m, [0, 0, 1]])
    return np.linalg.inv(full)[:2]


def iou(a, b) -> float:
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


# ---------------------------------------------------------------------------------------------------------------------
# Models (TFLite fp32 on the Mac, the files the Android harness runs)

class Tflite:
    def __init__(self, path: Path):
        from ai_edge_litert.interpreter import Interpreter
        self.interpreter = Interpreter(model_path=str(path), num_threads=8)
        self.interpreter.allocate_tensors()
        self.inputs = self.interpreter.get_input_details()
        self.outputs = self.interpreter.get_output_details()

    def run(self, *tensors):
        for detail, tensor in zip(self.inputs, tensors):
            self.interpreter.set_tensor(detail["index"], tensor.astype(np.float32))
        self.interpreter.invoke()
        return [self.interpreter.get_tensor(d["index"]) for d in self.outputs]


def priors(canvas: int) -> np.ndarray:
    """RetinaFace PriorBox for a square canvas, in canvas pixels: [N, 4] centre x, centre y, w, h."""
    out = []
    for step, sizes in ((8, (16, 32)), (16, (64, 128)), (32, (256, 512))):
        cells = math.ceil(canvas / step)
        for i in range(cells):
            for j in range(cells):
                for size in sizes:
                    out.append([(j + 0.5) * step, (i + 0.5) * step, size, size])
    return np.array(out, np.float32)


def nms(boxes: np.ndarray, scores: np.ndarray, threshold: float) -> list:
    order = list(np.argsort(-scores, kind="stable"))
    keep = []
    while order:
        best = order.pop(0)
        keep.append(best)
        order = [i for i in order if iou(boxes[best], boxes[i]) <= threshold]
    return keep


class Detector:
    def __init__(self):
        self.models = {short: Tflite(TFLITE / f"face-detector-{short}.tflite") for short in DETECTION_SIZES}
        self.priors = {short: priors(canvas) for short, canvas in DETECTION_SIZES.items()}

    def detect(self, rgb: np.ndarray, short: int):
        h, w = rgb.shape[:2]
        canvas = DETECTION_SIZES[short]
        scale = detection_scale(w, h, short, canvas)
        nh, nw = int(h * scale), int(w * scale)
        board = np.broadcast_to(DETECTOR_MEAN_RGB, (canvas, canvas, 3)).copy()
        board[:nh, :nw] = resize(rgb, nw, nh)
        # The model's own output order: names from the converted signature are not stable, so pick by shape.
        outputs = self.models[short].run((board / 255).transpose(2, 0, 1)[None])
        loc = next(o for o in outputs if o.shape[-1] == 4)[0]
        landmarks = next(o for o in outputs if o.shape[-1] == 10)[0]
        score = next(o for o in outputs if o.ndim == 2)[0]
        return decode_detections(loc, score, landmarks, self.priors[short], scale)


def input_size(w: int, h: int, cap: int = INPUT_LONG_SIDE_MAX) -> tuple:
    """The size a photo is enhanced at: unchanged up to `cap` on the long side, else shrunk to it (half-up rounding)."""
    long = max(w, h)
    if long <= cap:
        return w, h
    return max(1, int(w * cap / long + 0.5)), max(1, int(h * cap / long + 0.5))


def detection_scale(w: int, h: int, short: int, canvas: int) -> float:
    """The short side goes to `short`; a photo longer than the canvas allows (over 1.6 : 1) has its long side fitted
    to the canvas instead, so it is detected at a lower resolution rather than refused. Photos that fitted before keep
    exactly the scale they had."""
    scale = short / min(h, w)
    return scale if int(max(h, w) * scale) <= canvas else canvas / max(h, w)


def decode_detections(loc, score, landmarks, prior, scale):
    keep = np.where(score > SCORE_THRESHOLD)[0]
    p = prior[keep]
    centre = p[:, :2] + loc[keep, :2] * 0.1 * p[:, 2:]
    size = p[:, 2:] * np.exp(loc[keep, 2:] * 0.2)
    boxes = np.hstack([centre - size / 2, centre + size / 2]) / scale
    points = (p[:, None, :2] + landmarks[keep].reshape(-1, 5, 2) * 0.1 * p[:, None, 2:]) / scale
    found = []
    for i in nms(boxes, score[keep], NMS_THRESHOLD):
        five = points[i]
        if np.linalg.norm(five[0] - five[1]) >= EYE_GAP_MIN:
            found.append({"box": boxes[i].tolist(), "score": float(score[keep][i]), "five": five.tolist()})
    return found


class FaceMesh:
    def __init__(self):
        self.model = Tflite(HERE / "outputs" / "app-models" / "face_landmarker" / "face_landmarks_detector.tflite")

    def run(self, rgb, centre, side, roll):
        k = side / 256
        c, s = math.cos(roll), math.sin(roll)
        to_photo = np.array([[k * c, -k * s, centre[0] - k * (c * 128 - s * 128)],
                             [k * s, k * c, centre[1] - k * (s * 128 + c * 128)]])
        crop = warp_bilinear(rgb, to_photo, 256, 256, 0.0)
        outputs = self.model.run((crop / 255)[None])
        raw = next(o for o in outputs if o.size == 1434).reshape(478, 3)[:, :2]
        presence = float(next(o for o in outputs if o.size == 1).ravel()[0])
        return raw @ to_photo[:, :2].T + to_photo[:, 2], 1 / (1 + math.exp(-presence))

    def five(self, rgb, detection):
        box, five = np.array(detection["box"]), np.array(detection["five"])
        eye_line = five[1] - five[0]
        points, presence = self.run(rgb, (box[:2] + box[2:]) / 2, (box[2:] - box[:2]).max() * 1.5,
                                    math.atan2(eye_line[1], eye_line[0]))
        line = points[263] - points[33]
        lo, hi = points[:468].min(0), points[:468].max(0)
        refined, refined_presence = self.run(rgb, (lo + hi) / 2, (hi - lo).max() * 1.5, math.atan2(line[1], line[0]))
        if refined_presence >= presence - 0.1:
            points, presence = refined, refined_presence
        return (points[MESH_FIVE] if presence >= MESH_PRESENCE_MIN else five), presence


class CodeFormer:
    def __init__(self):
        sys.path.insert(0, str(HERE))
        from run_g_app_models import Restorer
        self.restorer = Restorer()

    def restore(self, face_rgb: np.ndarray) -> np.ndarray:
        torch = self.restorer.torch
        tensor = torch.from_numpy((face_rgb / 127.5 - 1).transpose(2, 0, 1)[None].astype(np.float32))
        with torch.no_grad():
            out = self.restorer.net(tensor.to(self.restorer.device), w=FIDELITY, adain=True)[0]
        out = out[0].clamp(-1, 1).cpu().numpy().transpose(1, 2, 0)
        return ((out + 1) * 127.5).astype(np.float32)


def five_views(rgb: np.ndarray) -> np.ndarray:
    """export_art_classifier.five_views_uint8 with this file's resize, rounded to uint8 as PIL does."""
    h, w = rgb.shape[:2]
    whole = resize(rgb, 224, 224)
    if w <= h:
        lw, lh = 448, int(448 * h / w)
    else:
        lw, lh = int(448 * w / h), 448
    large = resize(rgb, lw, lh)
    corners = [((lw - 224) // 2, (lh - 224) // 2), ((lw - 224) // 2, round(lh * 0.15)),
               (max(0, round(lw * 0.2)), (lh - 224) // 2), (max(0, round(lw * 0.8) - 224), (lh - 224) // 2)]
    views = [whole] + [large[y:y + 224, x:x + 224] for x, y in corners]
    return np.clip(np.round(np.stack(views)), 0, 255).astype(np.uint8)


def tile_windows(size: int, tile: int = None, pad: int = None) -> list:
    """Per axis: (kept start, kept length, window start). The fewest windows of `tile` px that overlap by at least
    2 x pad, spread evenly (window i starts at round(i * (size - tile) / (n - 1))); each overlap is split at its middle,
    so every kept pixel has at least `pad` px of context on its inner sides. A photo axis no longer than a tile is one
    window starting at 0; its rows or columns past the photo are mirrored in (mirror_index)."""
    tile = TILE if tile is None else tile
    pad = TILE_PAD if pad is None else pad
    if size <= tile:
        return [(0, size, 0)]
    n = math.ceil((size - tile) / (tile - 2 * pad)) + 1
    starts = [round(i * (size - tile) / (n - 1)) for i in range(n)]   # Python round: halves to even
    cuts = [0] + [(starts[i] + tile + starts[i + 1]) // 2 for i in range(n - 1)] + [size]
    return [(cuts[i], cuts[i + 1] - cuts[i], starts[i]) for i in range(n)]


def mirror_index(i: int, size: int) -> int:
    """Reflect without repeating the edge pixel (PyTorch's 'reflect' pad, which Real-ESRGAN's own pre_pad uses),
    repeated for as long as needed: a 100 px axis fills a 384 px window. Identity for 0 <= i < size, so photos of a
    tile or more on each side read exactly the pixels they read before."""
    if size == 1:
        return 0
    period = 2 * (size - 1)
    j = i % period
    return period - j if j >= size else j


def upscale_background(model: Tflite, rgb: np.ndarray) -> np.ndarray:
    """realesr-general-x4v3 on TILE px windows laid out by tile_windows; the 4x result is averaged 2 x 2 to 2x."""
    h, w = rgb.shape[:2]
    out = np.zeros((h * SCALE, w * SCALE, 3), np.float32)
    for y, ch, wy in tile_windows(h):
        for x, cw, wx in tile_windows(w):
            rows = [mirror_index(wy + t, h) for t in range(TILE)]
            columns = [mirror_index(wx + t, w) for t in range(TILE)]
            tile = rgb[np.ix_(rows, columns)] / 255
            up = np.clip(model.run(tile.transpose(2, 0, 1)[None])[0][0], 0, 1).transpose(1, 2, 0) * 255
            region = up[(y - wy) * 4:(y - wy + ch) * 4, (x - wx) * 4:(x - wx + cw) * 4]
            out[y * 2:(y + ch) * 2, x * 2:(x + cw) * 2] = region.reshape(ch * 2, 2, cw * 2, 2, 3).mean((1, 3))
    return out


def paste_face(image: np.ndarray, restored: np.ndarray, face_mask01: np.ndarray, to_face: np.ndarray) -> None:
    """Blend one restored face into the 2x image in place. to_face: 2 x 3 photo -> face (CodeFormer's affine)."""
    inverse = invert_affine(to_face) * SCALE
    inverse[:, 2] += 0.5 * SCALE                                     # CodeFormer's back-alignment offset
    output_to_face = invert_affine(inverse)
    corners = np.array([[0, 0, 1], [512, 0, 1], [0, 512, 1], [512, 512, 1]], np.float64) @ inverse.T
    h, w = image.shape[:2]
    x0, y0 = max(int(math.floor(corners[:, 0].min())) - 2, 0), max(int(math.floor(corners[:, 1].min())) - 2, 0)
    x1, y1 = min(int(math.ceil(corners[:, 0].max())) + 3, w), min(int(math.ceil(corners[:, 1].max())) + 3, h)
    if x1 <= x0 or y1 <= y0:
        return
    shift = output_to_face.copy()
    shift[:, 2] += shift[:, 0] * x0 + shift[:, 1] * y0               # region pixel (u, v) -> output (u + x0, v + y0)
    rw, rh = x1 - x0, y1 - y0
    square = warp_bilinear(np.ones((512, 512, 1), np.float32), shift, rw, rh, 0.0)[..., 0]
    square = erode(square, 2 * SCALE)
    edge = int(float(square.sum()) ** 0.5) // 20
    soft_square = gaussian_blur(erode(square, edge * 2), edge * 2 + 1, 0)
    parse = warp_bilinear(face_mask01[..., None], shift, rw, rh, 0.0)[..., 0]
    soft = np.minimum(parse, soft_square)[..., None]
    pasted = warp_bilinear(restored, shift, rw, rh, 0.0) * square[..., None]
    region = image[y0:y1, x0:x1]
    image[y0:y1, x0:x1] = soft * pasted + (1 - soft) * region


def face_mask(multiclass: Tflite, restored: np.ndarray) -> np.ndarray:
    small = resize(np.clip(restored, 0, 255), 256, 256)
    logits = multiclass.run((small / 255)[None])[0].reshape(256, 256, 6)
    face = fill_holes(logits.argmax(-1) == FACE_SKIN).astype(np.float32)[..., None] * 255
    mask = resize(face, 512, 512)[..., 0]
    mask = gaussian_blur(gaussian_blur(mask, 101, 11), 101, 11)
    mask[:10] = 0
    mask[-10:] = 0
    mask[:, :10] = 0
    mask[:, -10:] = 0
    return mask / 255


class Pipeline:
    def __init__(self):
        self.art = Tflite(TFLITE / "art-classifier.tflite")
        self.detector = Detector()
        self.mesh = FaceMesh()
        self.multiclass = Tflite(HERE.parent / "android-vision" / "models" / "selfie_multiclass_256x256.tflite")
        self.upscaler = Tflite(TFLITE / f"general-x4v3-{TILE}.tflite")
        self.codeformer = CodeFormer()

    def enhance(self, rgb: np.ndarray):
        times, record = {}, {}
        w, h = input_size(rgb.shape[1], rgb.shape[0])
        if (w, h) != (rgb.shape[1], rgb.shape[0]):
            rgb = resize(rgb, w, h)   # stays float, like every other step (rounded only at the end)
        t = time.perf_counter()
        views = five_views(rgb)
        record["art"] = float(self.art.run(views.transpose(0, 3, 1, 2) / 255)[0].ravel()[0])
        times["art"] = time.perf_counter() - t
        record["grey"] = bool(is_grey(rgb))
        faces = []
        if record["art"] < ART_THRESHOLD:
            t = time.perf_counter()
            found = self.detector.detect(rgb, 640)
            extra = [d for d in self.detector.detect(rgb, 960)
                     if all(iou(d["box"], kept["box"]) < EXTRA_IOU for kept in found)]
            record["detections_640"], record["detections_960_added"] = len(found), len(extra)
            found += extra
            times["detect"] = time.perf_counter() - t
            t = time.perf_counter()
            for detection in found:
                detector_five = np.array(detection["five"])
                if np.linalg.norm(detector_five[0] - detector_five[1]) < RESTORE_EYE_GAP_MIN:
                    # Too small to restore: no Face Mesh run; five_used keeps the detector's points for the reports.
                    faces.append({**detection, "restored": False, "five_used": detection["five"]})
                    continue
                five, presence = self.mesh.five(rgb, detection)
                faces.append({**detection, "restored": True, "mesh_presence": presence,
                              "five_used": np.asarray(five).tolist()})
            times["mesh"] = time.perf_counter() - t
        t = time.perf_counter()
        image = upscale_background(self.upscaler, rgb)
        times["background"] = time.perf_counter() - t
        times["codeformer"] = times["colour_and_mask"] = times["paste"] = 0.0
        for face in faces:
            if not face["restored"]:
                continue
            to_face = similarity(np.array(face["five_used"]), FACE_TEMPLATE)
            crop = warp_bilinear(rgb, invert_affine(to_face), 512, 512, CROP_BORDER_RGB)
            t = time.perf_counter()
            restored = self.codeformer.restore(crop)
            times["codeformer"] += time.perf_counter() - t
            t = time.perf_counter()
            restored = original_colour(restored, crop)
            if record["grey"]:
                restored = grey_like(restored, crop)
            mask = face_mask(self.multiclass, restored)
            times["colour_and_mask"] += time.perf_counter() - t
            t = time.perf_counter()
            paste_face(image, restored, mask, to_face)
            times["paste"] += time.perf_counter() - t
        record["faces"] = faces
        record["times"] = {k: round(v, 3) for k, v in times.items()}
        return np.clip(np.round(image), 0, 255).astype(np.uint8), record


def main() -> None:
    import cv2
    ids = sys.argv[1:] or sorted(p.name for p in REAL.iterdir() if (p / "input.png").exists())
    OUT.mkdir(parents=True, exist_ok=True)
    pipeline = Pipeline()
    for photo in ids:
        rgb = cv2.cvtColor(cv2.imread(str(REAL / photo / "input.png")), cv2.COLOR_BGR2RGB)
        image, record = pipeline.enhance(rgb)
        cv2.imwrite(str(OUT / f"{photo}.png"), cv2.cvtColor(image, cv2.COLOR_RGB2BGR))
        (OUT / f"{photo}.json").write_text(json.dumps(record, indent=1))
        print(photo, len(record["faces"]), "faces", record["times"], flush=True)


if __name__ == "__main__":
    main()
