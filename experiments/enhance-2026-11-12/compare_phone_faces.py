"""Enhance step 1d: on-phone CodeFormer outputs against the PyTorch reference (export_phone_faces.py).

Reads outputs/phone-faces/<device>/<name>.bin (float32 [1, 3, 512, 512], [-1, 1]), prints the mean and 99th-percentile
absolute difference in 0-255 units, and writes outputs/phone-faces/<device>-sheet.png (rows: input | PyTorch | phone).
Run: .venv/bin/python compare_phone_faces.py android
"""
import sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
FACES = HERE / "outputs" / "phone-faces"


def to_image(output: np.ndarray) -> np.ndarray:
    rgb = np.clip((output[0].transpose(1, 2, 0) + 1) / 2, 0, 1)
    return (rgb[:, :, ::-1] * 255).round().astype(np.uint8)


def main(device: str) -> None:
    rows = []
    for phone_file in sorted((FACES / device).glob("*.bin")):
        name = phone_file.stem
        phone = to_image(np.fromfile(phone_file, dtype="<f4").reshape(1, 3, 512, 512))
        reference = cv2.imread(str(FACES / f"{name}-pytorch.png"))
        difference = np.abs(reference.astype(int) - phone.astype(int))
        print(f"{name}: mean diff {difference.mean():.2f}, 99th percentile {np.percentile(difference, 99):.0f} (0-255)")
        rows.append(np.hstack([cv2.imread(str(FACES / f"{name}-input.png")), reference, phone]))
    sheet = np.vstack(rows)
    cv2.imwrite(str(FACES / f"{device}-sheet.png"), cv2.resize(sheet, None, fx=0.5, fy=0.5, interpolation=cv2.INTER_AREA))


if __name__ == "__main__":
    main(sys.argv[1])
