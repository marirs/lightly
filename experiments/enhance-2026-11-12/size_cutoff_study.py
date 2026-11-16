"""Enhance step 2g: below which face size does restoring a face stop helping?

Ground truth: sharp faces (eye gap >= 60 px) in experiments/test-photos and experiments/lut3d/photos, found with
RetinaFace ResNet-50 (any aspect ratio). Each face is cut out with context (a square of 10 x its eye gap) and shrunk
(area) so its eye gap becomes g px, g in SIZES; variant "clean" is only shrunk, variant "old" is also blurred
(Gaussian sigma 0.6 px) and saved as JPEG quality 75 at the small size, like a soft old print.

Each small image is enhanced to 2x two ways, exactly as phone_pipeline.py except that the background is one
general-x4v3 pass (equal to the 384 / 16 tiles, step 2e) because the cut-outs are smaller than a tile:
- background only: general-x4v3, averaged 2 x 2;
- restored: the same background with the face pasted: Face Mesh points seeded from the scaled true box and five
  points (the pipeline's presence rule), CodeFormer 0.8, original colour, grey where grey, multiclass mask.
Both are compared with the truth (the cut-out shrunk to the same 2x size) on the face square (side 3 x the 2x eye
gap, as compare_phone_pipeline.py): LPIPS (AlexNet; lower is closer; the square is resized to 224 px for both) and
PSNR. Sheets (truth | background only | restored per face) in outputs/size-cutoff/sheet-<variant>-<g>.png.
Results are appended per face to outputs/size-cutoff/results.jsonl, so a run stopped by the 600 s cap resumes.
Run: .venv/bin/python size_cutoff_study.py [summary]
"""
import json
import math
import sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import phone_pipeline as pp  # noqa: E402

OUT = HERE / "outputs" / "size-cutoff"
RESULTS = OUT / "results.jsonl"
SIZES = [6, 8, 10, 12, 14, 16, 20, 24, 30]
VARIANTS = ["clean", "old"]
SOURCES = [HERE.parent / "test-photos", HERE.parent / "lut3d" / "photos"]
MIN_TRUTH_GAP = 60
# Checked by eye on the sheets (2026-11-16): the face square of these shows a profile's nose and cheek, or no face at
# all (backlit_01 / 03 are ResNet-50 detections on hair and an ear), so they say nothing about frontal restoration.
NOT_FRONTAL = {"profile_beard_man_01#0", "profile_bw_boy_01#0", "profile_bw_woman_01#0", "profile_bw_woman_hair_01#0",
               "profile_colour_woman_01#0", "backlit_01#0", "backlit_03#0"}


class Background:
    """general-x4v3 in PyTorch on MPS, one pass, 4x averaged 2 x 2 (as the tiles, which equal one pass)."""

    def __init__(self, torch):
        # realesrgan's own module cannot be imported once CodeFormer's repo (its older basicsr) is on the path, so
        # the network is rebuilt here: realesrgan.archs.srvgg_arch.SRVGGNetCompact, prelu, same parameter names.
        class SRVGGNetCompact(torch.nn.Module):
            def __init__(self, num_feat=64, num_conv=32, upscale=4):
                super().__init__()
                self.upscale = upscale
                body = [torch.nn.Conv2d(3, num_feat, 3, 1, 1), torch.nn.PReLU(num_parameters=num_feat)]
                for _ in range(num_conv):
                    body += [torch.nn.Conv2d(num_feat, num_feat, 3, 1, 1), torch.nn.PReLU(num_parameters=num_feat)]
                body.append(torch.nn.Conv2d(num_feat, 3 * upscale * upscale, 3, 1, 1))
                self.body = torch.nn.ModuleList(body)
                self.upsampler = torch.nn.PixelShuffle(upscale)

            def forward(self, x):
                out = x
                for layer in self.body:
                    out = layer(out)
                return self.upsampler(out) + torch.nn.functional.interpolate(x, scale_factor=self.upscale, mode="nearest")

        self.torch = torch
        net = SRVGGNetCompact()
        net.load_state_dict(torch.load(HERE / "weights/realesr-general-x4v3/realesr-general-x4v3.pth", map_location="cpu")["params"])
        self.net = net.eval().to("mps")

    def upscale(self, rgb: np.ndarray) -> np.ndarray:
        with self.torch.no_grad():
            tensor = self.torch.from_numpy((rgb / 255).transpose(2, 0, 1)[None].astype(np.float32)).to("mps")
            up = np.clip(self.net(tensor)[0].cpu().numpy(), 0, 1).transpose(1, 2, 0)
        h, w = up.shape[0] // 4 * 2, up.shape[1] // 4 * 2
        return up.reshape(h, 2, w, 2, 3).mean((1, 3)) * 255


def truth_faces(restorer, bgr):
    helper = restorer.helper("retinaface_resnet50")
    helper.read_image(bgr)
    helper.get_face_landmarks_5(only_center_face=False, resize=640, eye_dist_threshold=5)
    faces = []
    for box, five in zip(helper.det_faces, helper.all_landmarks_5):
        five = np.asarray(five, np.float64).reshape(5, 2)
        if math.dist(five[0], five[1]) >= MIN_TRUTH_GAP:
            faces.append((np.asarray(box[:4], np.float64), five))
    return faces


def cut_out(rgb, box, five):
    """Square of 10 x the eye gap around the eyes-and-mouth centre, clipped to the photo."""
    gap = math.dist(five[0], five[1])
    centre = (five[0] + five[1] + five[3] + five[4]) / 4
    half = 5 * gap
    x0, y0 = int(max(centre[0] - half, 0)), int(max(centre[1] - half, 0))
    x1, y1 = int(min(centre[0] + half, rgb.shape[1])), int(min(centre[1] + half, rgb.shape[0]))
    offset = np.array([x0, y0], np.float64)
    return rgb[y0:y1, x0:x1], box - np.tile(offset, 2), five - offset


def degrade(small_rgb: np.ndarray, variant: str) -> np.ndarray:
    if variant == "clean":
        return small_rgb
    blurred = cv2.GaussianBlur(small_rgb, (0, 0), 0.6)
    ok, jpeg = cv2.imencode(".jpg", cv2.cvtColor(np.clip(blurred, 0, 255).astype(np.uint8), cv2.COLOR_RGB2BGR),
                            [cv2.IMWRITE_JPEG_QUALITY, 75])
    return cv2.cvtColor(cv2.imdecode(jpeg, cv2.IMREAD_COLOR), cv2.COLOR_BGR2RGB).astype(np.float32)


def face_square(five2x: np.ndarray, shape):
    centre = (five2x[0] + five2x[1] + five2x[3] + five2x[4]) / 4
    half = int(math.dist(five2x[0], five2x[1]) * 1.5)
    x, y = int(centre[0]), int(centre[1])
    return max(y - half, 0), min(y + half, shape[0]), max(x - half, 0), min(x + half, shape[1])


class Scorer:
    def __init__(self, torch):
        import lpips
        self.torch = torch
        self.model = lpips.LPIPS(net="alex", verbose=False)

    def lpips(self, a: np.ndarray, b: np.ndarray) -> float:
        def tensor(image):
            image = cv2.resize(np.clip(image, 0, 255).astype(np.float32), (224, 224), interpolation=cv2.INTER_CUBIC)
            return self.torch.from_numpy((image / 127.5 - 1).transpose(2, 0, 1)[None].astype(np.float32))
        with self.torch.no_grad():
            return float(self.model(tensor(a), tensor(b)).item())


def psnr(a: np.ndarray, b: np.ndarray) -> float:
    mse = float(((np.clip(a, 0, 255) - np.clip(b, 0, 255)) ** 2).mean())
    return 10 * math.log10(255 ** 2 / max(mse, 1e-9))


def run() -> None:
    import torch
    OUT.mkdir(parents=True, exist_ok=True)
    done = set()
    if RESULTS.exists():
        done = {json.loads(line)["key"] for line in RESULTS.read_text().splitlines() if line.strip()}
    codeformer = pp.CodeFormer()
    mesh = pp.FaceMesh()
    multiclass = pp.Tflite(HERE.parent / "android-vision" / "models" / "selfie_multiclass_256x256.tflite")
    background = Background(torch)
    scorer = Scorer(torch)
    for folder in SOURCES:
        for path in sorted(folder.glob("*.jpg")):
            bgr = cv2.imread(str(path))
            rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB).astype(np.float32)
            for index, (box, five) in enumerate(truth_faces(codeformer.restorer, bgr)):
                key = f"{path.stem}#{index}"
                if key in done:
                    continue
                crop, crop_box, crop_five = cut_out(rgb, box, five)
                gap = math.dist(crop_five[0], crop_five[1])
                record = {"key": key, "truth_gap": round(gap, 1), "sizes": {}}
                tiles = {}
                for g in SIZES:
                    s = g / gap
                    sw, sh = max(round(crop.shape[1] * s), 8), max(round(crop.shape[0] * s), 8)
                    clean = cv2.resize(crop, (sw, sh), interpolation=cv2.INTER_AREA)
                    truth2 = cv2.resize(crop, (sw * 2, sh * 2), interpolation=cv2.INTER_AREA)
                    sx, sy = sw / crop.shape[1], sh / crop.shape[0]
                    scale = np.array([sx, sy])
                    detection = {"box": (crop_box * np.tile(scale, 2)).tolist(), "five": (crop_five * scale).tolist()}
                    for variant in VARIANTS:
                        small = degrade(clean, variant)
                        plain = background.upscale(small)
                        used, presence = mesh.five(small, detection)
                        to_face = pp.similarity(np.asarray(used, np.float64), pp.FACE_TEMPLATE)
                        face_crop = pp.warp_bilinear(small, pp.invert_affine(to_face), 512, 512, pp.CROP_BORDER_RGB)
                        restored = pp.original_colour(codeformer.restore(face_crop), face_crop)
                        if pp.is_grey(small):
                            restored = pp.grey_like(restored, face_crop)
                        mask = pp.face_mask(multiclass, restored)
                        pasted = plain.copy()
                        pp.paste_face(pasted, restored, mask, to_face)
                        y0, y1, x0, x1 = face_square(crop_five * scale * 2, truth2.shape)
                        t, p, r = truth2[y0:y1, x0:x1], plain[y0:y1, x0:x1], pasted[y0:y1, x0:x1]
                        record["sizes"][f"{variant}-{g}"] = {
                            "lpips_plain": round(scorer.lpips(p, t), 4), "lpips_restored": round(scorer.lpips(r, t), 4),
                            "psnr_plain": round(psnr(p, t), 2), "psnr_restored": round(psnr(r, t), 2),
                            "mesh_presence": round(float(presence), 3)}
                        tiles[f"{variant}-{g}"] = np.hstack([cv2.resize(np.clip(i, 0, 255).astype(np.uint8), (128, 128),
                                                                        interpolation=cv2.INTER_AREA) for i in (t, p, r)])
                np.savez_compressed(OUT / f"tiles-{key}.npz", **tiles)
                with RESULTS.open("a") as handle:
                    handle.write(json.dumps(record) + "\n")
                print(key, "gap", round(gap), {k: (v["lpips_plain"], v["lpips_restored"]) for k, v in record["sizes"].items()
                                               if k.startswith("old")}, flush=True)


def summary() -> None:
    every = [json.loads(line) for line in RESULTS.read_text().splitlines() if line.strip()]
    records = [r for r in every if r["key"] not in NOT_FRONTAL]
    print(len(every), "faces,", len(records), "frontal (summary); sheets show all")
    print("variant  g   LPIPS plain  restored  restored better  PSNR plain restored")
    for variant in VARIANTS:
        for g in SIZES:
            rows = [r["sizes"][f"{variant}-{g}"] for r in records]
            plain = np.median([x["lpips_plain"] for x in rows])
            restored = np.median([x["lpips_restored"] for x in rows])
            better = sum(x["lpips_restored"] < x["lpips_plain"] for x in rows)
            print(f"{variant:6} {g:3}   {plain:.3f}      {restored:.3f}     {better:2}/{len(rows)}         "
                  f"{np.median([x['psnr_plain'] for x in rows]):.1f}   {np.median([x['psnr_restored'] for x in rows]):.1f}")
        # Sheets: one row per face, truth | background only | restored.
    for variant in VARIANTS:
        for g in SIZES:
            rows = []
            for record in every:
                tiles = np.load(OUT / f"tiles-{record['key']}.npz")
                tile = cv2.cvtColor(tiles[f"{variant}-{g}"], cv2.COLOR_RGB2BGR).copy()
                cv2.putText(tile, record["key"][:14], (3, 12), cv2.FONT_HERSHEY_SIMPLEX, 0.35, (0, 255, 255), 1, cv2.LINE_AA)
                rows.append(tile)
            columns = 3
            while len(rows) % columns:
                rows.append(np.zeros_like(rows[0]))
            sheet = np.vstack([np.hstack(rows[i:i + columns]) for i in range(0, len(rows), columns)])
            cv2.imwrite(str(OUT / f"sheet-{variant}-{g}.png"), sheet)


if __name__ == "__main__":
    summary() if len(sys.argv) > 1 and sys.argv[1] == "summary" else run()
