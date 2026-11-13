"""Core ML CodeFormer (fp16) against PyTorch on real aligned faces: writes coreml/check-<photo>.png
(aligned input | PyTorch w=0.8 | Core ML) and prints the mean absolute difference in 0-255 units.
Run: .venv/bin/python check_coreml_face.py
"""
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "repos" / "CodeFormer"))
os.chdir(HERE / "repos" / "CodeFormer")

import coremltools as ct  # noqa: E402
import cv2  # noqa: E402
import numpy as np  # noqa: E402
import torch  # noqa: E402
from basicsr.utils.registry import ARCH_REGISTRY  # noqa: E402
import basicsr.archs.codeformer_arch  # noqa: E402,F401
from facelib.utils.face_restoration_helper import FaceRestoreHelper  # noqa: E402

PHOTOS = [HERE / "outputs/real/Ar9j8V6oMzo/input.png", HERE / "outputs/real/q8ZnolGToXw/input.png",
          HERE / "outputs/profile_colour_woman_01/1-degraded.png"]


def to_tensor(face_bgr: np.ndarray) -> np.ndarray:
    rgb = face_bgr[:, :, ::-1].astype(np.float32) / 255.0
    return ((rgb - 0.5) / 0.5).transpose(2, 0, 1)[None]


def to_image(output: np.ndarray) -> np.ndarray:
    rgb = np.clip((output[0].transpose(1, 2, 0) + 1) / 2, 0, 1)
    return (rgb[:, :, ::-1] * 255).round().astype(np.uint8)


def main() -> None:
    net = ARCH_REGISTRY.get("CodeFormer")(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9,
                                          connect_list=["32", "64", "128", "256"])
    net.load_state_dict(torch.load(HERE / "weights/codeformer/codeformer.pth", map_location="cpu",
                                   weights_only=False)["params_ema"])
    net.eval()
    mlmodel = ct.models.MLModel(str(HERE / "coreml/codeformer-w0.8-512.mlpackage"))
    input_name = mlmodel.get_spec().description.input[0].name
    helper = FaceRestoreHelper(1, face_size=512, crop_ratio=(1, 1), det_model="retinaface_resnet50",
                               save_ext="png", use_parse=False, device=torch.device("mps"))  # facelib RetinaFace uses MPS
    for path in PHOTOS:
        helper.clean_all()
        helper.read_image(cv2.imread(str(path)))
        helper.get_face_landmarks_5(only_center_face=True, resize=640, eye_dist_threshold=5)
        helper.align_warp_face()
        face = helper.cropped_faces[0]
        with torch.no_grad():
            reference = to_image(net(torch.from_numpy(to_tensor(face)), w=0.8, adain=True)[0].numpy())
        converted = to_image(mlmodel.predict({input_name: to_tensor(face)})["output"])
        difference = np.abs(reference.astype(int) - converted.astype(int)).mean()
        print(path.parent.name, "mean abs difference (0-255):", round(float(difference), 2), flush=True)
        cv2.imwrite(str(HERE / f"coreml/check-{path.parent.name}.png"), np.hstack([face, reference, converted]))


if __name__ == "__main__":
    main()
