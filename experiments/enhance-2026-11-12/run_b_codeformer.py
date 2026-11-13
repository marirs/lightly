"""Enhance step 1b: CodeFormer faces on the same general-x4v3 background as GFPGAN (outputs/bg from run_a).

Runs with the CodeFormer repository's own basicsr/facelib (repos/CodeFormer first on sys.path), so it is a separate
process from run_a, which uses the pip basicsr. Fidelity weights 0.5 (repo default) and 0.8 (closer to the input).
Run: .venv/bin/python run_b_codeformer.py   (after run_a)
"""
import json
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE / "repos" / "CodeFormer"
sys.path.insert(0, str(REPO))
os.chdir(REPO)  # facelib downloads its detector weights into REPO/weights/facelib

import cv2  # noqa: E402
import torch  # noqa: E402
from torchvision.transforms.functional import normalize  # noqa: E402
from basicsr.utils import img2tensor, tensor2img  # noqa: E402
from basicsr.utils.registry import ARCH_REGISTRY  # noqa: E402
import basicsr.archs.codeformer_arch  # noqa: E402,F401  (registers CodeFormer)
from facelib.utils.face_restoration_helper import FaceRestoreHelper  # noqa: E402

OUT = HERE / "outputs"
SCALE = 4
DEVICE = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
FIDELITY_WEIGHTS = [0.5, 0.8]


def load_codeformer() -> torch.nn.Module:
    net = ARCH_REGISTRY.get("CodeFormer")(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9,
                                          connect_list=["32", "64", "128", "256"]).to(DEVICE)
    checkpoint = torch.load(HERE / "weights/codeformer/codeformer.pth", map_location="cpu", weights_only=False)
    net.load_state_dict(checkpoint["params_ema"])
    return net.eval()


def restore(net, helper, low, background, fidelity: float):
    helper.clean_all()
    helper.read_image(low)
    faces = helper.get_face_landmarks_5(only_center_face=False, resize=640, eye_dist_threshold=5)
    helper.align_warp_face()
    for cropped in helper.cropped_faces:
        tensor = img2tensor(cropped / 255.0, bgr2rgb=True, float32=True)
        normalize(tensor, (0.5, 0.5, 0.5), (0.5, 0.5, 0.5), inplace=True)
        with torch.no_grad():
            output = net(tensor.unsqueeze(0).to(DEVICE), w=fidelity, adain=True)[0]
        helper.add_restored_face(tensor2img(output, rgb2bgr=True, min_max=(-1, 1)).astype("uint8"), cropped)
    helper.get_inverse_affine(None)
    return helper.paste_faces_to_input_image(upsample_img=background), faces


def main() -> None:
    net = load_codeformer()
    helper = FaceRestoreHelper(SCALE, face_size=512, crop_ratio=(1, 1), det_model="retinaface_resnet50",
                               save_ext="png", use_parse=True, device=DEVICE)
    timings = {}
    for background_path in sorted((OUT / "bg").glob("*.png")):
        stem = background_path.stem
        low = cv2.imread(str(OUT / stem / "1-degraded.png"), cv2.IMREAD_COLOR)
        background = cv2.imread(str(background_path), cv2.IMREAD_COLOR)
        timings[stem] = {}
        for fidelity in FIDELITY_WEIGHTS:
            start = time.perf_counter()
            image, faces = restore(net, helper, low, background, fidelity)
            if DEVICE.type == "mps":
                torch.mps.synchronize()
            timings[stem][f"codeformer w{fidelity} (faces only)"] = round(time.perf_counter() - start, 2)
            timings[stem]["faces"] = faces
            cv2.imwrite(str(OUT / stem / f"5-codeformer-w{fidelity}.png"), image)
        print(stem, timings[stem], flush=True)
    (OUT / "timings-b.json").write_text(json.dumps({"device": str(DEVICE), "seconds": timings}, indent=2))


if __name__ == "__main__":
    main()
