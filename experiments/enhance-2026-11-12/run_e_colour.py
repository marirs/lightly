"""Enhance step 1e: face sheets for the colour fix (colour_from_original.py) on toned and colour photos.

Rows: original aligned face | CodeFormer w=0.8 | CodeFormer detail + original colour. Writes
outputs/colour/<photo>-<face>.png and outputs/colour/sheet-toned.png / sheet-colour.png, and prints how far each face's
colour moved from the original (mean Lab a/b distance, both blurred) before and after the fix.
Run: .venv/bin/python run_e_colour.py
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
from colour_from_original import restored_detail_original_colour  # noqa: E402

OUT = HERE / "outputs" / "colour"
TONED = ["q8ZnolGToXw", "wobEQvA3A9A", "ky5_VsML4Xc", "Q-lUWYs7Ms0", "M_d3JYC3vok"]
COLOUR = [("profile_colour_woman_01", HERE.parent / "test-photos/profile_colour_woman_01.jpg"),
          ("profile_beard_man_01", HERE.parent / "test-photos/profile_beard_man_01.jpg"),
          ("group_three_01", HERE.parent / "test-photos/group_three_01.jpg"),
          ("glasses_black_front_01", HERE.parent / "test-photos/glasses_black_front_01.jpg")]


def colour_shift(face: np.ndarray, original: np.ndarray) -> float:
    def chroma(image):
        lab = cv2.cvtColor(cv2.GaussianBlur(image, (0, 0), 6).astype(np.float32) / 255.0, cv2.COLOR_BGR2LAB)
        return lab[..., 1:]
    return float(np.linalg.norm(chroma(face) - chroma(original), axis=2).mean())


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    net = ARCH_REGISTRY.get("CodeFormer")(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9,
                                          connect_list=["32", "64", "128", "256"])
    net.load_state_dict(torch.load(HERE / "weights/codeformer/codeformer.pth", map_location="cpu",
                                   weights_only=False)["params_ema"])
    net.eval()
    helper = FaceRestoreHelper(1, face_size=512, crop_ratio=(1, 1), det_model="retinaface_resnet50",
                               save_ext="png", use_parse=False, device=torch.device("mps"))
    sources = [(name, HERE / "outputs/real" / name / "input.png") for name in TONED] + COLOUR
    rows = {"toned": [], "colour": []}
    for name, path in sources:
        image = cv2.imread(str(path))
        if "test-photos" in str(path):  # same treatment as the real photos: a 1200 px wide copy
            image = cv2.resize(image, (1200, round(image.shape[0] * 1200 / image.shape[1])), interpolation=cv2.INTER_AREA)
        helper.clean_all()
        helper.read_image(image)
        helper.get_face_landmarks_5(only_center_face=False, resize=640, eye_dist_threshold=5)
        helper.align_warp_face()
        for index, face in enumerate(helper.cropped_faces[:2]):
            with torch.no_grad():
                restored = to_image(net(torch.from_numpy(to_tensor(face)), w=0.8, adain=True)[0].numpy())
            fixed = restored_detail_original_colour(restored, face)
            row = np.hstack([face, restored, fixed])
            cv2.imwrite(str(OUT / f"{name}-{index}.png"), row)
            group = "toned" if name in TONED else "colour"
            rows[group].append(cv2.resize(row, None, fx=0.4, fy=0.4, interpolation=cv2.INTER_AREA))
            print(f"{group:6s} {name}[{index}] colour shift from original: CodeFormer {colour_shift(restored, face):.2f}, "
                  f"fixed {colour_shift(fixed, face):.2f}", flush=True)
    for group, group_rows in rows.items():
        cv2.imwrite(str(OUT / f"sheet-{group}.png"), np.vstack(group_rows))


if __name__ == "__main__":
    main()
