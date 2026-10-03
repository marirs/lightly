"""Depth candidate comparison sheet + a simple, ground-truth-free ordinal check.

Ordinal check ("subject in front"): for photos with a Vision subject matte, the median disparity
inside the subject must exceed the median disparity in a ring of background just outside it. It
cannot rank fine detail, but a candidate that fails it would put the wrong thing in focus.
Edge alignment: mean |gradient of disparity| on the matte boundary divided by the mean elsewhere —
higher means depth edges coincide with the subject outline (less halo risk before refinement).
"""
import json

import numpy as np
from PIL import Image
from scipy import ndimage

import common
import sheet_utils

CANDIDATES = ["da2_small", "apple_coreml_da2_small", "da1_small", "midas31_swin2_tiny", "midas21_small"]


def load_disparity(candidate: str, stem: str, shape) -> np.ndarray:
    raw = np.load(common.CACHE_DIR / "depth" / candidate / f"{stem}.npy")
    return np.asarray(Image.fromarray(raw).resize((shape[1], shape[0]), Image.BILINEAR))


def main() -> None:
    rows, metrics = [], {c: {"subject_in_front": [], "edge_alignment": []} for c in CANDIDATES}
    for stem in common.DEMO_PHOTOS + common.REPLACEMENT_BACKGROUNDS:
        image = common.load_working_image(stem)
        matte = common.load_subject_matte(stem, image.shape)
        row = [sheet_utils.tile(image, stem, 300)]
        row.append(sheet_utils.tile(matte if matte is not None else np.zeros(image.shape[:2]),
                                    "Vision matte" if matte is not None else "no subject", 300))
        for candidate in CANDIDATES:
            disparity = load_disparity(candidate, stem, image.shape)
            row.append(sheet_utils.tile(sheet_utils.colourise_disparity(disparity), candidate, 300))
            if matte is not None:
                inside = matte > 0.5
                ring = ndimage.binary_dilation(inside, iterations=60) & ~ndimage.binary_dilation(inside, iterations=12)
                metrics[candidate]["subject_in_front"].append(
                    float(np.median(disparity[inside]) - np.median(disparity[ring])))
                gradient = np.hypot(*np.gradient(disparity))
                boundary = ndimage.binary_dilation(inside, iterations=2) & ~ndimage.binary_erosion(inside, iterations=2)
                metrics[candidate]["edge_alignment"].append(float(gradient[boundary].mean() / gradient[~boundary].mean()))
        rows.append(row)
    common.SHEETS_DIR.mkdir(parents=True, exist_ok=True)
    sheet_utils.grid(rows, "Monocular depth candidates (near = bright). Working input 518x392 / 392x518; MiDaS 256x256").save(
        common.SHEETS_DIR / "00_depth_candidates.jpg", quality=88)
    summary = {c: {"subject_in_front_margin": [round(v, 3) for v in m["subject_in_front"]],
                   "subject_in_front_pass": sum(v > 0.02 for v in m["subject_in_front"]),
                   "edge_alignment_mean": round(float(np.mean(m["edge_alignment"])), 2)} for c, m in metrics.items()}
    (common.RESULTS_DIR / "depth_ordinal_check.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
