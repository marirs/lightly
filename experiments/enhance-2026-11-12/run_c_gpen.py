"""Enhance step 1c: GPEN-BFR-512 faces, with the same detection, alignment and paste-back as CodeFormer (run_b) and
the same general-x4v3 background (outputs/bg from run_a), so only the face model differs.

GPEN's own pipeline needs extra detector weights and CUDA ops; its generator runs on plain PyTorch ops off Linux/CUDA.
Settings follow GPEN's demo for GPEN-BFR-512: 512 px, channel multiplier 2, narrow 1.
Run: .venv/bin/python run_c_gpen.py   (after run_a and run_b, which fetched the detector weights)
"""
import json
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CODEFORMER = HERE / "repos" / "CodeFormer"
GPEN_MODEL_DIR = HERE / "repos" / "GPEN" / "face_model"
sys.path.insert(0, str(CODEFORMER))
sys.path.insert(0, str(GPEN_MODEL_DIR))
os.chdir(CODEFORMER)  # facelib looks for its detector weights under CODEFORMER/weights/facelib

import cv2  # noqa: E402
import numpy as np  # noqa: E402
import torch  # noqa: E402
from facelib.utils.face_restoration_helper import FaceRestoreHelper  # noqa: E402
from gpen_model import FullGenerator  # noqa: E402

OUT = HERE / "outputs"
SCALE = 4
# GPEN's StyleGAN2 ops have no MPS path in its fallback code; CPU keeps the comparison honest (timings are CPU).
DEVICE = torch.device("cpu")


def load_gpen() -> FullGenerator:
    model = FullGenerator(512, 512, 8, 2, narrow=1, device="cpu")
    model.load_state_dict(torch.load(HERE / "weights/gpen-bfr-512/GPEN-BFR-512.pth", map_location="cpu", weights_only=False))
    return model.to(DEVICE).eval()


def run_face(model: FullGenerator, face_bgr: np.ndarray) -> np.ndarray:
    tensor = torch.from_numpy(cv2.resize(face_bgr, (512, 512))).float().to(DEVICE) / 255.0
    tensor = ((tensor - 0.5) / 0.5).permute(2, 0, 1).unsqueeze(0).flip(1)  # BGR -> RGB, [-1, 1]
    with torch.no_grad():
        output, _ = model(tensor)
    output = (output * 0.5 + 0.5).squeeze(0).permute(1, 2, 0).flip(2)  # RGB -> BGR
    return (np.clip(output.cpu().numpy(), 0, 1) * 255).astype(np.uint8)


def main() -> None:
    model = load_gpen()
    # facelib's RetinaFace moves its inputs to its own default device (MPS), so the helper stays on MPS; only GPEN
    # runs on the CPU.
    helper_device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    helper = FaceRestoreHelper(SCALE, face_size=512, crop_ratio=(1, 1), det_model="retinaface_resnet50",
                               save_ext="png", use_parse=True, device=helper_device)
    timings = {}
    for background_path in sorted((OUT / "bg").glob("*.png")):
        stem = background_path.stem
        low = cv2.imread(str(OUT / stem / "1-degraded.png"), cv2.IMREAD_COLOR)
        background = cv2.imread(str(background_path), cv2.IMREAD_COLOR)
        start = time.perf_counter()
        helper.clean_all()
        helper.read_image(low)
        faces = helper.get_face_landmarks_5(only_center_face=False, resize=640, eye_dist_threshold=5)
        helper.align_warp_face()
        for cropped in helper.cropped_faces:
            helper.add_restored_face(run_face(model, cropped), cropped)
        helper.get_inverse_affine(None)
        image = helper.paste_faces_to_input_image(upsample_img=background)
        timings[stem] = {"gpen-bfr-512 (faces only, CPU)": round(time.perf_counter() - start, 2), "faces": faces}
        cv2.imwrite(str(OUT / stem / "6-gpen-bfr-512.png"), image)
        print(stem, timings[stem], flush=True)
    (OUT / "timings-c.json").write_text(json.dumps({"device": str(DEVICE), "seconds": timings}, indent=2))


if __name__ == "__main__":
    main()
