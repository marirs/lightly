"""Enhance step 1f: can CodeFormer's own confidence tell painted or drawn faces from photographed ones?

For every test image with a face (art-test/ from fetch_art_test_set.py, the Unsplash real photos, experiments/test-photos)
at 1200 px wide: RetinaFace (up to three faces, eyes at least 20 px apart), then per face from CodeFormer's transformer
(the middle stage, already computed by Enhance): mean top-1 code probability, mean gap between the top two logits, and
how much CodeFormer w=0.8 changes the face. Writes outputs/art/faces.csv. Labels: painting/drawing = skip,
photo = enhance (SpeUAC9IOng in the real photos is a painting).
Run: .venv/bin/python run_f_art.py
"""
import csv
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

OUT = HERE / "outputs" / "art"
PAINTINGS_IN_REAL_PHOTOS = {"SpeUAC9IOng"}


def test_images():
    for label in ("painting", "drawing", "photo"):
        for path in sorted((HERE / "art-test" / label).glob("*.jpg")):
            yield label, path
    for path in sorted((HERE / "real-photos").glob("*.jpg")):
        yield ("painting" if path.stem in PAINTINGS_IN_REAL_PHOTOS else "photo"), path
    for path in sorted((HERE.parent / "test-photos").glob("*.jpg")):
        yield "photo", path


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    device = torch.device("mps")
    net = ARCH_REGISTRY.get("CodeFormer")(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9,
                                          connect_list=["32", "64", "128", "256"]).to(device)
    net.load_state_dict(torch.load(HERE / "weights/codeformer/codeformer.pth", map_location="cpu",
                                   weights_only=False)["params_ema"])
    net.eval()
    helper = FaceRestoreHelper(1, face_size=512, crop_ratio=(1, 1), det_model="retinaface_resnet50",
                               save_ext="png", use_parse=False, device=device)
    with (OUT / "faces.csv").open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["label", "image", "face", "top1_probability", "top_logit_gap", "change"])
        for label, path in test_images():
            image = cv2.imread(str(path))
            if image is None:
                continue
            image = cv2.resize(image, (1200, round(image.shape[0] * 1200 / image.shape[1])), interpolation=cv2.INTER_AREA)
            helper.clean_all()
            helper.read_image(image)
            helper.get_face_landmarks_5(only_center_face=False, resize=640, eye_dist_threshold=20)
            helper.align_warp_face()
            for index, face in enumerate(helper.cropped_faces[:3]):
                with torch.no_grad():
                    output, logits, _ = net(torch.from_numpy(to_tensor(face)).to(device), w=0.8, adain=True)
                probabilities = torch.softmax(logits[0], dim=1)
                top2 = logits[0].topk(2, dim=1).values
                restored = to_image(output.cpu().numpy())
                change = float(np.abs(cv2.GaussianBlur(restored, (0, 0), 2).astype(float)
                                      - cv2.GaussianBlur(face, (0, 0), 2).astype(float)).mean())
                writer.writerow([label, path.name, index, f"{float(probabilities.max(1).values.mean()):.4f}",
                                 f"{float((top2[:, 0] - top2[:, 1]).mean()):.3f}", f"{change:.2f}"])
                handle.flush()
                cv2.imwrite(str(OUT / f"{label}-{path.stem}-{index}.jpg"), np.hstack([face, restored]))
            print(label, path.name, len(helper.cropped_faces), flush=True)


if __name__ == "__main__":
    main()
