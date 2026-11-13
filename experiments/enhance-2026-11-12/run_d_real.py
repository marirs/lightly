"""Enhance step 1b: real old photos (Unsplash, real-photos/SOURCES.txt) through the provisional pipeline.

Each photo is reduced to 1200 px wide (a typical phone copy of an old print), then enhanced x2:
  stage "bg"    (pip basicsr process): Real-ESRGAN general x4 v3 at outscale 2 -> outputs/real/<id>/bg.png
  stage "faces" (CodeFormer repo process): CodeFormer w=0.8 faces pasted onto bg -> outputs/real/<id>/codeformer-0.8.png
The two stages need different basicsr packages, so this file runs itself twice in separate processes.
Run: .venv/bin/python run_d_real.py
"""
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PHOTOS = HERE / "real-photos"
OUT = HERE / "outputs" / "real"
INPUT_WIDTH = 1200
SCALE = 2
FIDELITY = 0.8  # owner preference 2026-11-13


def stage_background() -> None:
    import cv2
    import torch
    from realesrgan import RealESRGANer
    from realesrgan.archs.srvgg_arch import SRVGGNetCompact

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    upsampler = RealESRGANer(scale=4, model_path=str(HERE / "weights/realesr-general-x4v3/realesr-general-x4v3.pth"),
                             model=SRVGGNetCompact(num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4,
                                                   act_type="prelu"), tile=0, half=False, device=device)
    for path in sorted(PHOTOS.glob("*.jpg")):
        folder = OUT / path.stem
        folder.mkdir(parents=True, exist_ok=True)
        image = cv2.imread(str(path), cv2.IMREAD_COLOR)
        height = round(image.shape[0] * INPUT_WIDTH / image.shape[1])
        small = cv2.resize(image, (INPUT_WIDTH, height), interpolation=cv2.INTER_AREA)
        cv2.imwrite(str(folder / "input.png"), small)
        start = time.perf_counter()
        background, _ = upsampler.enhance(small, outscale=SCALE)
        print(path.stem, "bg", round(time.perf_counter() - start, 2), flush=True)
        cv2.imwrite(str(folder / "bg.png"), background)


def stage_faces() -> None:
    import os
    sys.path.insert(0, str(HERE / "repos" / "CodeFormer"))
    os.chdir(HERE / "repos" / "CodeFormer")
    import cv2
    import torch
    from torchvision.transforms.functional import normalize
    from basicsr.utils import img2tensor, tensor2img
    from basicsr.utils.registry import ARCH_REGISTRY
    import basicsr.archs.codeformer_arch  # noqa: F401  (registers CodeFormer)
    from facelib.utils.face_restoration_helper import FaceRestoreHelper

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    net = ARCH_REGISTRY.get("CodeFormer")(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9,
                                          connect_list=["32", "64", "128", "256"]).to(device)
    net.load_state_dict(torch.load(HERE / "weights/codeformer/codeformer.pth", map_location="cpu",
                                   weights_only=False)["params_ema"])
    net.eval()
    helper = FaceRestoreHelper(SCALE, face_size=512, crop_ratio=(1, 1), det_model="retinaface_resnet50",
                               save_ext="png", use_parse=True, device=device)
    summary = {}
    for folder in sorted(p for p in OUT.iterdir() if (p / "bg.png").exists()):
        low = cv2.imread(str(folder / "input.png"), cv2.IMREAD_COLOR)
        background = cv2.imread(str(folder / "bg.png"), cv2.IMREAD_COLOR)
        start = time.perf_counter()
        helper.clean_all()
        helper.read_image(low)
        faces = helper.get_face_landmarks_5(only_center_face=False, resize=640, eye_dist_threshold=5)
        helper.align_warp_face()
        for cropped in helper.cropped_faces:
            tensor = img2tensor(cropped / 255.0, bgr2rgb=True, float32=True)
            normalize(tensor, (0.5, 0.5, 0.5), (0.5, 0.5, 0.5), inplace=True)
            with torch.no_grad():
                output = net(tensor.unsqueeze(0).to(device), w=FIDELITY, adain=True)[0]
            helper.add_restored_face(tensor2img(output, rgb2bgr=True, min_max=(-1, 1)).astype("uint8"), cropped)
        helper.get_inverse_affine(None)
        result = helper.paste_faces_to_input_image(upsample_img=background)
        seconds = round(time.perf_counter() - start, 2)
        cv2.imwrite(str(folder / f"codeformer-{FIDELITY}.png"), result)
        summary[folder.name] = {"faces": faces, "seconds": seconds}
        print(folder.name, summary[folder.name], flush=True)
    (OUT / "summary.json").write_text(json.dumps(summary, indent=2))


if __name__ == "__main__":
    if len(sys.argv) > 1:
        {"bg": stage_background, "faces": stage_faces}[sys.argv[1]]()
    else:
        for stage in ("bg", "faces"):
            subprocess.run([sys.executable, __file__, stage], check=True)
