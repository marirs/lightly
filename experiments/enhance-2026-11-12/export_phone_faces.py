"""Enhance step 1d: real aligned faces for the on-phone quality check, and the PyTorch reference for each.

Writes outputs/phone-faces/<name>.bin (float32 [1, 3, 512, 512], range [-1, 1], little-endian: the TFLite and Core ML
input), <name>-input.png and <name>-pytorch.png (original CodeFormer, w=0.8). compare_phone_faces.py reads them back.
Run: .venv/bin/python export_phone_faces.py
"""
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "repos" / "CodeFormer"))
os.chdir(HERE / "repos" / "CodeFormer")

import cv2  # noqa: E402
import numpy as np  # noqa: E402
import torch  # noqa: E402
from basicsr.utils.registry import ARCH_REGISTRY  # noqa: E402
import basicsr.archs.codeformer_arch  # noqa: E402,F401
from facelib.utils.face_restoration_helper import FaceRestoreHelper  # noqa: E402

from check_coreml_face import to_image, to_tensor  # noqa: E402

OUT = HERE / "outputs" / "phone-faces"
# Black-and-white group, sepia portrait (the colour problem), colour portrait, painting.
SOURCES = {"bw-group": (HERE / "outputs/real/Ar9j8V6oMzo/input.png", 0),
           "sepia": (HERE / "outputs/real/q8ZnolGToXw/input.png", 0),
           "bw-family": (HERE / "outputs/real/eTOiqGqdCf8/input.png", 2),
           "colour-woman": (HERE / "outputs/profile_colour_woman_01/1-degraded.png", 0),
           "painting": (HERE / "outputs/real/SpeUAC9IOng/input.png", 1)}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    net = ARCH_REGISTRY.get("CodeFormer")(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9,
                                          connect_list=["32", "64", "128", "256"])
    net.load_state_dict(torch.load(HERE / "weights/codeformer/codeformer.pth", map_location="cpu",
                                   weights_only=False)["params_ema"])
    net.eval()
    helper = FaceRestoreHelper(1, face_size=512, crop_ratio=(1, 1), det_model="retinaface_resnet50",
                               save_ext="png", use_parse=False, device=torch.device("mps"))
    for name, (path, face_index) in SOURCES.items():
        helper.clean_all()
        helper.read_image(cv2.imread(str(path)))
        helper.get_face_landmarks_5(only_center_face=False, resize=640, eye_dist_threshold=5)
        helper.align_warp_face()
        face = helper.cropped_faces[face_index]
        tensor = to_tensor(face).astype("<f4")
        tensor.tofile(OUT / f"{name}.bin")
        with torch.no_grad():
            reference = to_image(net(torch.from_numpy(tensor), w=0.8, adain=True)[0].numpy())
        cv2.imwrite(str(OUT / f"{name}-input.png"), face)
        cv2.imwrite(str(OUT / f"{name}-pytorch.png"), reference)
        print("wrote", name, flush=True)


if __name__ == "__main__":
    main()
