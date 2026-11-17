"""Enhance step 3a: a small fixture for the apps' engine tests (ios EnhanceEngineTests, android EnhanceEngineTest).

One face of eTOiqGqdCf8 (the child of step 2f) cropped to 480 x 400 px, and the Mac copy's output for that crop
(phone_pipeline.py), so the simulator and emulator run CodeFormer once rather than five times.
Writes outputs/engine-check/input.png, mac.png and mac.json (git-ignored, like every output).

Run: .venv/bin/python engine_check.py
"""
import json
from pathlib import Path

import cv2
import numpy as np

import phone_pipeline as pp

HERE = Path(__file__).resolve().parent
OUT = HERE / "outputs" / "engine-check"


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    rgb = cv2.cvtColor(cv2.imread(str(pp.REAL / "eTOiqGqdCf8" / "input.png")), cv2.COLOR_BGR2RGB)
    record = json.loads((pp.OUT / "eTOiqGqdCf8.json").read_text())
    five = np.array(min(record["faces"], key=lambda face: np.linalg.norm(np.subtract(*face["five"][:2])))["five"])
    centre = five.mean(0)
    x0 = int(np.clip(centre[0] - 240, 0, rgb.shape[1] - 480))
    y0 = int(np.clip(centre[1] - 200, 0, rgb.shape[0] - 400))
    crop = np.ascontiguousarray(rgb[y0:y0 + 400, x0:x0 + 480])
    image, result = pp.Pipeline().enhance(crop.astype(np.float32))
    cv2.imwrite(str(OUT / "input.png"), cv2.cvtColor(crop, cv2.COLOR_RGB2BGR))
    cv2.imwrite(str(OUT / "mac.png"), cv2.cvtColor(image, cv2.COLOR_RGB2BGR))
    (OUT / "mac.json").write_text(json.dumps({**result, "crop": [x0, y0, 480, 400]}, indent=1))
    print("crop", x0, y0, "faces", [(round(float(np.linalg.norm(np.subtract(*f["five"][:2]))), 1), f["restored"])
                                    for f in result["faces"]])


if __name__ == "__main__":
    main()
