"""Enhance step 2a: can the apps' own face models replace CodeFormer's RetinaFace (104 MB) and ParseNet (81 MB)?

Both apps already ship MediaPipe BlazeFace full range (Android), Apple Vision face rectangles (iOS), Face Mesh V2 and
selfie multiclass (experiments/android-vision/models). On the ten real photos (outputs/real/<id>/input.png and bg.png
from run_d_real.py, enhanced x2) this restores every face with CodeFormer 0.8 plus the original colour (step 1e) and
pastes it with:

  reference  RetinaFace 5 points, ParseNet paste mask (CodeFormer's own pipeline; run_d_real.py faces-colour)
  jitter     the reference's points moved by up to 0.5 px: how much CodeFormer's output moves on its own
  mesh       Face Mesh 5 points (seeded from the RetinaFace box), ParseNet mask   -> the alignment alone
  multiclass RetinaFace 5 points, selfie multiclass face-skin mask                 -> the paste mask alone
  android    BlazeFace full range -> Face Mesh -> multiclass                        -> what Android would do
  ios        Apple Vision rectangles (vision.json from vision_faces.swift) -> Face Mesh -> multiclass

Per face it reports the mean difference from the reference inside the reference's paste mask (0-255) and writes
side-by-side crops to outputs/app-models/sheets/. Faces are matched to the reference by eye midpoint.
Run: swift vision_faces.swift outputs/real/*/input.png > outputs/app-models/vision.json
     .venv/bin/python run_g_app_models.py
"""
import json
import math
import os
import sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
REAL = HERE / "outputs" / "real"
OUT = HERE / "outputs" / "app-models"
VISION_MODELS = HERE.parent / "android-vision" / "models"
SCALE = 2
FIDELITY = 0.8

# Face Mesh V2 points standing in for RetinaFace's five, in its order (image-left eye first): iris centres 468 / 473,
# nose tip 1, mouth corners 61 / 291.
MESH_FIVE = [468, 473, 1, 61, 291]
MULTICLASS_FACE_SKIN = 3


class TfliteModel:
    def __init__(self, path):
        from ai_edge_litert.interpreter import Interpreter
        self.interpreter = Interpreter(model_path=str(path))
        self.interpreter.allocate_tensors()
        self.input = self.interpreter.get_input_details()[0]["index"]
        self.outputs = [d["index"] for d in self.interpreter.get_output_details()]

    def run(self, tensor):
        self.interpreter.set_tensor(self.input, tensor[None].astype(np.float32))
        self.interpreter.invoke()
        return [self.interpreter.get_tensor(i)[0] for i in self.outputs]


def blazeface_detect(model, rgb):
    """BlazeFaceDetector + SsdDecoder (android core-vision FaceAnalysis.kt / SsdDecoding.kt): letterboxed 192 x 192 in
    [-1, 1], 48 x 48 anchors, score >= 0.6, weighted NMS 0.3. Boxes and keypoints in photo pixels."""
    h, w = rgb.shape[:2]
    side = max(h, w)
    square = np.zeros((side, side, 3), np.uint8)
    off_x, off_y = (side - w) // 2, (side - h) // 2
    square[off_y:off_y + h, off_x:off_x + w] = rgb
    tensor = cv2.resize(square, (192, 192), interpolation=cv2.INTER_AREA).astype(np.float32) / 127.5 - 1
    outputs = model.run(tensor)
    regressors = next(o for o in outputs if o.shape[-1] == 16).reshape(-1, 16)
    logits = next(o for o in outputs if o.shape[-1] == 1).reshape(-1)
    grid = (np.arange(48) + 0.5) / 48
    anchor_x, anchor_y = np.meshgrid(grid, grid)
    anchors = np.stack([anchor_x.ravel(), anchor_y.ravel()], 1)
    scores = 1 / (1 + np.exp(-np.clip(logits, -100, 100)))
    candidates = []
    for i in np.where(scores >= 0.6)[0]:
        r = regressors[i] / 192
        xc, yc = r[0] + anchors[i, 0], r[1] + anchors[i, 1]
        points = r[4:].reshape(6, 2) + anchors[i]
        candidates.append((scores[i], np.array([xc - r[2] / 2, yc - r[3] / 2, xc + r[2] / 2, yc + r[3] / 2]), points))
    detections = []
    candidates.sort(key=lambda c: -c[0])
    while candidates:
        top = candidates[0]
        cluster = [c for c in candidates if iou(c[1], top[1]) > 0.3]
        candidates = [c for c in candidates if iou(c[1], top[1]) <= 0.3]
        weights = np.array([c[0] for c in cluster])
        box = sum(c[0] * c[1] for c in cluster) / weights.sum()
        points = sum(c[0] * c[2] for c in cluster) / weights.sum()
        to_photo = np.array([side, side])
        detections.append({"score": float(top[0]),
                           "box": (box.reshape(2, 2) * to_photo - [off_x, off_y]).ravel(),
                           "keypoints": points * to_photo - [off_x, off_y]})
    return detections


def iou(a, b):
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def face_mesh(model, rgb, centre, side, roll):
    """Face Mesh V2 on a rotated square crop (FaceMeshLandmarker): 256 x 256 in [0, 1]; points in photo pixels."""
    k = side / 256
    c, s = math.cos(roll), math.sin(roll)
    # Crop pixel (u, v) -> photo (x, y), rotated about the crop centre.
    to_photo = np.array([[k * c, -k * s, centre[0] - k * (c * 128 - s * 128)],
                         [k * s, k * c, centre[1] - k * (s * 128 + c * 128)]])
    crop = cv2.warpAffine(rgb, to_photo, (256, 256), flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP,
                          borderMode=cv2.BORDER_CONSTANT)
    outputs = model.run(crop.astype(np.float32) / 255)
    raw = next(o for o in outputs if o.size == 478 * 3).reshape(478, 3)[:, :2]
    presence = float(next(o for o in outputs if o.size == 1).ravel()[0])
    points = raw @ to_photo[:, :2].T + to_photo[:, 2]
    return points, 1 / (1 + math.exp(-presence))


def refined_mesh(model, rgb, centre, side, roll):
    """First pass on the detector's crop, then one re-crop on the mesh, upright along its eye line (33 -> 263), as
    MediaPipe's tracker does."""
    points, presence = face_mesh(model, rgb, centre, side, roll)
    eye_line = points[263] - points[33]
    lo, hi = points[:468].min(0), points[:468].max(0)
    refined, refined_presence = face_mesh(model, rgb, (lo + hi) / 2, (hi - lo).max() * 1.5,
                                          math.atan2(eye_line[1], eye_line[0]))
    return (refined, refined_presence) if refined_presence >= presence - 0.1 else (points, presence)


def multiclass_paste_mask(model, restored_bgr):
    """Selfie multiclass on the restored 512 face, face-skin class only (ParseNet's mask keeps face, brows, eyes, nose,
    lips, glasses and earrings; drops hair, hat, neck and clothes). Returned at 512 x 512 in 0-255."""
    # Grey photos: the helper's add_restored_face returns a float64 grey-then-AdaIN face.
    restored_bgr = np.clip(restored_bgr, 0, 255).astype(np.uint8)
    if restored_bgr.ndim == 2:
        restored_bgr = cv2.cvtColor(restored_bgr, cv2.COLOR_GRAY2BGR)
    rgb = cv2.cvtColor(cv2.resize(restored_bgr, (256, 256), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2RGB)
    logits = model.run(rgb.astype(np.float32) / 255)[0].reshape(256, 256, 6)
    face = (logits.argmax(-1) == MULTICLASS_FACE_SKIN).astype(np.uint8)
    # Fill enclosed holes (eyes, open mouth) the way ParseNet's eye/mouth classes would include them.
    flood = np.pad(1 - face, 1, constant_values=1)
    cv2.floodFill(flood, None, (0, 0), 0)
    face = np.maximum(face, flood[1:-1, 1:-1])
    return cv2.resize(face.astype(np.float32) * 255, (512, 512), interpolation=cv2.INTER_LINEAR)


class Restorer:
    """CodeFormer 0.8 + original colour (step 1e) on an aligned face; same helper as run_d_real.py."""

    def __init__(self):
        sys.path.insert(0, str(HERE / "repos" / "CodeFormer"))
        os.chdir(HERE / "repos" / "CodeFormer")
        import torch
        from basicsr.utils.registry import ARCH_REGISTRY
        import basicsr.archs.codeformer_arch  # noqa: F401
        from facelib.utils.face_restoration_helper import FaceRestoreHelper
        self.torch = torch
        self.device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
        self.net = ARCH_REGISTRY.get("CodeFormer")(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9,
                                                   connect_list=["32", "64", "128", "256"]).to(self.device)
        self.net.load_state_dict(torch.load(HERE / "weights/codeformer/codeformer.pth", map_location="cpu",
                                            weights_only=False)["params_ema"])
        self.net.eval()
        self.helper_class = FaceRestoreHelper

    def helper(self):
        return self.helper_class(SCALE, face_size=512, crop_ratio=(1, 1), det_model="retinaface_resnet50",
                                 save_ext="png", use_parse=True, device=self.device)

    def restore(self, cropped):
        from torchvision.transforms.functional import normalize
        from basicsr.utils import img2tensor, tensor2img
        sys.path.insert(0, str(HERE))
        from colour_from_original import restored_detail_original_colour
        tensor = img2tensor(cropped / 255.0, bgr2rgb=True, float32=True)
        normalize(tensor, (0.5, 0.5, 0.5), (0.5, 0.5, 0.5), inplace=True)
        with self.torch.no_grad():
            output = self.net(tensor.unsqueeze(0).to(self.device), w=FIDELITY, adain=True)[0]
        restored = tensor2img(output, rgb2bgr=True, min_max=(-1, 1)).astype("uint8")
        return restored_detail_original_colour(restored, cropped)


def paste(helper, low, background, landmarks, restorer, mask_model=None, cache=None):
    """Align on `landmarks`, restore, paste onto background. mask_model None = ParseNet (CodeFormer), else the
    multiclass mask replaces the parse mask. Returns the image and each face's soft paste mask (output pixels)."""
    helper.clean_all()
    helper.read_image(low)
    helper.all_landmarks_5 = [np.asarray(l, np.float32) for l in landmarks]
    helper.align_warp_face()
    for index, cropped in enumerate(helper.cropped_faces):
        key = None if cache is None else tuple(np.round(landmarks[index], 3).ravel())
        if cache is not None and key in cache:
            restored = cache[key]
        else:
            restored = restorer.restore(cropped)
            if cache is not None:
                cache[key] = restored
        helper.add_restored_face(restored, cropped)
    helper.get_inverse_affine(None)
    if mask_model is None:
        return helper.paste_faces_to_input_image(upsample_img=background), parse_masks(helper)
    return paste_with_masks(helper, background, [multiclass_paste_mask(mask_model, f) for f in helper.restored_faces])


def parse_masks(helper):
    """The ParseNet masks the helper just used, recomputed for scoring (same steps as paste_faces_to_input_image)."""
    masks = []
    for restored, inverse in zip(helper.restored_faces, helper.inverse_affine_matrices):
        masks.append(soft_mask_from_face_mask(helper, parsenet_mask(helper, restored), inverse))
    return masks


def parsenet_mask(helper, restored):
    from torchvision.transforms.functional import normalize
    from basicsr.utils import img2tensor
    import torch
    face = img2tensor(cv2.resize(restored, (512, 512)).astype("float32") / 255., bgr2rgb=True, float32=True)
    normalize(face, (0.5, 0.5, 0.5), (0.5, 0.5, 0.5), inplace=True)
    with torch.no_grad():
        out = helper.face_parse(face.unsqueeze(0).to(helper.device))[0].argmax(dim=1).squeeze().cpu().numpy()
    keep = np.array([0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0, 255, 0, 0, 0], np.float32)
    return keep[out]


def soft_mask_from_face_mask(helper, face_mask, inverse):
    """CodeFormer's paste-mask steps for one face (face_restoration_helper.paste_faces_to_input_image, use_parse)."""
    h, w = helper.input_img.shape[:2]
    size = (w * SCALE, h * SCALE)
    inverse = inverse.copy()  # the helper already added its 0.5 x scale offset
    square = cv2.warpAffine(np.ones(helper.face_size, np.float32), inverse, size)
    square = cv2.erode(square, np.ones((2 * SCALE, 2 * SCALE), np.uint8))
    edge = int(square.sum() ** 0.5) // 20
    soft_square = cv2.GaussianBlur(cv2.erode(square, np.ones((edge * 2, edge * 2), np.uint8)), (edge * 2 + 1, edge * 2 + 1), 0)
    parse = cv2.GaussianBlur(face_mask, (101, 101), 11)
    parse = cv2.GaussianBlur(parse, (101, 101), 11)
    parse[:10, :] = 0
    parse[-10:, :] = 0
    parse[:, :10] = 0
    parse[:, -10:] = 0
    parse = cv2.warpAffine(cv2.resize(parse / 255., helper.face_size), inverse, size, flags=3)
    return np.where(parse < soft_square, parse, soft_square), square


def paste_with_masks(helper, background, face_masks):
    h, w = helper.input_img.shape[:2]
    size = (w * SCALE, h * SCALE)
    image = cv2.resize(background, size, interpolation=cv2.INTER_LANCZOS4).astype(np.float32)
    masks = []
    for restored, inverse, face_mask in zip(helper.restored_faces, helper.inverse_affine_matrices, face_masks):
        # The helper's own paste adds this offset in place before warping ("more precise back alignment").
        inverse[:, 2] += 0.5 * SCALE
        soft, square = soft_mask_from_face_mask(helper, face_mask, inverse)
        restored = restored if restored.ndim == 3 else cv2.cvtColor(np.clip(restored, 0, 255).astype(np.uint8), cv2.COLOR_GRAY2BGR)
        pasted = cv2.warpAffine(restored.astype(np.float32), inverse, size) * square[:, :, None]
        image = soft[:, :, None] * pasted + (1 - soft[:, :, None]) * image
        masks.append((soft, square))
    return image.astype(np.uint8), masks


def eye_midpoint(five):
    return (np.asarray(five[0]) + np.asarray(five[1])) / 2


def match(reference_fives, other_fives):
    """Index into other_fives for each reference face (None when not found): eye midpoints within half an eye gap."""
    found = []
    for five in reference_fives:
        gap = np.linalg.norm(np.asarray(five[0]) - np.asarray(five[1]))
        distances = [np.linalg.norm(eye_midpoint(five) - eye_midpoint(o)) for o in other_fives]
        best = int(np.argmin(distances)) if distances else None
        found.append(best if best is not None and distances[best] < 0.5 * gap else None)
    return found


def face_crop(image, five, size=192):
    """Square crop around a face (output coordinates), for the sheets."""
    centre = eye_midpoint(five) * SCALE
    side = int(np.linalg.norm(np.asarray(five[0]) - np.asarray(five[1])) * SCALE * 3.2)
    x0, y0 = int(centre[0] - side / 2), int(centre[1] - side * 0.42)
    padded = cv2.copyMakeBorder(image, side, side, side, side, cv2.BORDER_CONSTANT)
    return cv2.resize(padded[y0 + side:y0 + 2 * side, x0 + side:x0 + 2 * side], (size, size), interpolation=cv2.INTER_AREA)


def main():
    blaze = TfliteModel(VISION_MODELS / "blaze_face_full_range.tflite")
    # Extracted from face_landmarker.task (unzip -d outputs/app-models/face_landmarker); sha256 c7d54204… as MODELS.csv.
    mesh = TfliteModel(OUT / "face_landmarker" / "face_landmarks_detector.tflite")
    multiclass = TfliteModel(VISION_MODELS / "selfie_multiclass_256x256.tflite")
    vision = {Path(k).parent.name: v for k, v in json.loads((OUT / "vision.json").read_text()).items()}
    restorer = Restorer()
    (OUT / "sheets").mkdir(parents=True, exist_ok=True)
    report = {}
    for folder in sorted(p for p in REAL.iterdir() if (p / "bg.png").exists()):
        low = cv2.imread(str(folder / "input.png"))
        background = cv2.imread(str(folder / "bg.png"))
        rgb = cv2.cvtColor(low, cv2.COLOR_BGR2RGB)
        helper = restorer.helper()
        helper.read_image(low)
        helper.get_face_landmarks_5(only_center_face=False, resize=640, eye_dist_threshold=5)
        reference_fives = [np.asarray(l) for l in helper.all_landmarks_5]
        reference_boxes = [np.asarray(b[:4]) for b in helper.det_faces]

        def mesh_fives(seeds):
            fives, presences = [], []
            for centre, side, roll in seeds:
                points, presence = refined_mesh(mesh, rgb, centre, side, roll)
                fives.append(points[MESH_FIVE])
                presences.append(presence)
            return fives, presences

        # Mesh seeded from RetinaFace's box and eye line (isolates the 5-point change).
        mesh_from_reference, _ = mesh_fives([((b[:2] + b[2:]) / 2, (b[2:] - b[:2]).max() * 1.5,
                                              math.atan2(*(f[1] - f[0])[::-1])) for b, f in zip(reference_boxes, reference_fives)])
        # Android: BlazeFace ROI (box x 1.5, rotated so its eye keypoints 0 -> 1 lie flat).
        detections = blazeface_detect(blaze, rgb)
        android_fives, android_presence = mesh_fives([((d["box"][:2] + d["box"][2:]) / 2, (d["box"][2:] - d["box"][:2]).max() * 1.5,
                                                       math.atan2(*(d["keypoints"][1] - d["keypoints"][0])[::-1])) for d in detections])
        # iOS: Vision rectangle, upright first pass (no keypoints), crop 1.6 x the box (SunglassesAnalysis).
        ios_fives, ios_presence = mesh_fives([(np.array([x + w / 2, y + h / 2]), max(w, h) * 1.6, 0.0)
                                              for x, y, w, h in vision.get(folder.name, [])])
        android_keep = [i for i, p in enumerate(android_presence) if p >= 0.5]
        ios_keep = [i for i, p in enumerate(ios_presence) if p >= 0.5]
        android_fives = [android_fives[i] for i in android_keep]
        ios_fives = [ios_fives[i] for i in ios_keep]

        cache = {}
        results = {
            "reference": paste(helper, low, background, reference_fives, restorer, cache=cache),
            # Baseline for the differences: RetinaFace's own points moved by up to half a pixel (fixed seed).
            "jitter": paste(helper, low, background, [f + np.random.default_rng(index).uniform(-0.5, 0.5, f.shape)
                                                      for index, f in enumerate(reference_fives)], restorer, cache=cache),
            "mesh": paste(helper, low, background, mesh_from_reference, restorer, cache=cache),
            "multiclass": paste(helper, low, background, reference_fives, restorer, multiclass, cache=cache),
            "android": paste(helper, low, background, android_fives, restorer, multiclass, cache=cache) if android_fives else (cv2.resize(background, (low.shape[1] * SCALE, low.shape[0] * SCALE)), []),
            "ios": paste(helper, low, background, ios_fives, restorer, multiclass, cache=cache) if ios_fives else (cv2.resize(background, (low.shape[1] * SCALE, low.shape[0] * SCALE)), []),
        }
        for name, (image, _) in results.items():
            cv2.imwrite(str(OUT / f"{folder.name}-{name}.png"), image)
        reference_image, reference_masks = results["reference"]
        found = {"android": match(reference_fives, android_fives), "ios": match(reference_fives, ios_fives)}
        faces = []
        rows = []
        for index, five in enumerate(reference_fives):
            soft = reference_masks[index][0] > 0.5
            row = {"eye_gap": round(float(np.linalg.norm(five[0] - five[1])), 1)}
            for name in ("jitter", "mesh", "multiclass", "android", "ios"):
                if name in found and found[name][index] is None:
                    row[name] = None
                    continue
                difference = np.abs(results[name][0].astype(np.float32) - reference_image.astype(np.float32)).mean(2)
                row[name] = round(float(difference[soft].mean()), 2)
            faces.append(row)
            rows.append(np.hstack([face_crop(cv2.resize(low, None, fx=SCALE, fy=SCALE, interpolation=cv2.INTER_CUBIC), five)]
                                  + [face_crop(results[n][0], five) for n in ("reference", "mesh", "multiclass", "android", "ios")]))
        if rows:
            cv2.imwrite(str(OUT / "sheets" / f"{folder.name}.jpg"), np.vstack(rows), [cv2.IMWRITE_JPEG_QUALITY, 92])
        report[folder.name] = {"retinaface": len(reference_fives), "blazeface": len(detections),
                               "blazeface_mesh_ok": len(android_fives), "vision": len(vision.get(folder.name, [])),
                               "vision_mesh_ok": len(ios_fives),
                               "android_extra": len(android_fives) - sum(f is not None for f in found["android"]),
                               "ios_extra": len(ios_fives) - sum(f is not None for f in found["ios"]),
                               "faces": faces}
        print(folder.name, json.dumps(report[folder.name]), flush=True)
    (OUT / "report.json").write_text(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
