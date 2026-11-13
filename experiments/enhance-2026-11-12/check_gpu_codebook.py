"""Enhance step 1d: the GPU-friendly codebook step (codeformer_gpu.py) against the original CodeFormer on real aligned
faces. Prints the logit gap between the best and second code, the share of tokens whose pick is not one-hot, and the
mean output difference in 0-255 units. Run: .venv/bin/python check_gpu_codebook.py
"""
import os
import sys
import types
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

import codeformer_gpu  # noqa: E402
from check_coreml_face import to_image, to_tensor  # noqa: E402

PHOTOS = sorted((HERE / "outputs/real").glob("*/input.png")) + [HERE / "outputs/profile_colour_woman_01/1-degraded.png"]


def main() -> None:
    net = ARCH_REGISTRY.get("CodeFormer")(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9,
                                          connect_list=["32", "64", "128", "256"])
    net.load_state_dict(torch.load(HERE / "weights/codeformer/codeformer.pth", map_location="cpu",
                                   weights_only=False)["params_ema"])
    net.eval()
    patched = types.MethodType(codeformer_gpu.forward_gpu_friendly, net)
    helper = FaceRestoreHelper(1, face_size=512, crop_ratio=(1, 1), det_model="retinaface_resnet50",
                               save_ext="png", use_parse=False, device=torch.device("mps"))
    for path in PHOTOS:
        helper.clean_all()
        helper.read_image(cv2.imread(str(path)))
        helper.get_face_landmarks_5(only_center_face=False, resize=640, eye_dist_threshold=5)
        helper.align_warp_face()
        for index, face in enumerate(helper.cropped_faces[:3]):
            tensor = torch.from_numpy(to_tensor(face))
            with torch.no_grad():
                reference = to_image(net(tensor, w=0.8, adain=True)[0].numpy())
                output, logits = patched(tensor, w=0.8, adain=True)
            top2 = logits[0].topk(2, dim=1).values
            gap = (top2[:, 0] - top2[:, 1]).numpy()
            weights = torch.softmax((logits - logits.amax(2, keepdim=True)) * codeformer_gpu.SHARPEN, 2)[0]
            blended = int((weights.max(1).values < 0.999).sum())
            difference = np.abs(reference.astype(int) - to_image(output.numpy()).astype(int))
            print(f"{path.parent.name}[{index}] logits {float(logits.min()):.1f}..{float(logits.max()):.1f}, "
                  f"min gap {gap.min():.3f}, blended tokens {blended}/256, "
                  f"mean diff {difference.mean():.3f}, max {difference.max()}", flush=True)


if __name__ == "__main__":
    main()
