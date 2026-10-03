"""How should a portrait photo enter a fixed-shape depth model? -> results/orientation_check.json

Reference: DA-V2 Small at the photo's own aspect (518x392 landscape / 392x518 portrait). Compared:
  rotate  — portrait photo rotated 90° into Apple's landscape-only Core ML package (cached output of
            estimate_depth.py), rotated back
  stretch — portrait photo resized (not cropped) into 518x392
  square  — every photo resized into 518x518
Metric: Pearson correlation of the disparity maps at the reference resolution.
"""
import json
import os

os.environ.setdefault("OMP_NUM_THREADS", "4")

import numpy as np
import torch
from PIL import Image
from transformers import AutoModelForDepthEstimation

import common
from estimate_depth import IMAGENET_MEAN, IMAGENET_STD, to_tensor


def main() -> None:
    model = AutoModelForDepthEstimation.from_pretrained(common.MODELS_DIR / "da2_small").eval()

    def run(image, size):
        with torch.inference_mode():
            return model(pixel_values=torch.from_numpy(to_tensor(image, size, IMAGENET_MEAN, IMAGENET_STD))).predicted_depth[0].numpy()

    def correlation(candidate, reference):
        if candidate.shape != reference.shape:
            candidate = np.asarray(Image.fromarray(candidate.astype(np.float32)).resize(reference.shape[::-1], Image.BILINEAR))
        return round(float(np.corrcoef(candidate.ravel(), reference.ravel())[0, 1]), 4)

    report = {}
    for stem in common.DEMO_PHOTOS + common.REPLACEMENT_BACKGROUNDS:
        image = common.load_working_image(stem)
        portrait = image.shape[0] > image.shape[1]
        reference = run(image, (392, 518) if portrait else (518, 392))
        entry = {"portrait": portrait, "square": correlation(run(image, (518, 518)), reference)}
        if portrait:
            entry["stretch"] = correlation(run(image, (518, 392)), reference)
            apple_rotated = np.load(common.CACHE_DIR / "depth" / "apple_coreml_da2_small" / f"{stem}.npy")
            entry["rotate_apple"] = correlation(apple_rotated, reference)
        report[stem] = entry
        print(stem, entry, flush=True)
    (common.RESULTS_DIR / "orientation_check.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
