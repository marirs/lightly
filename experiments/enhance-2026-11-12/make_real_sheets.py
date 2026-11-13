"""Before/after face crops for the real old photos (outputs/real/<id>/), up to four faces per photo:
input (1200 px, shown x2) | general-x4v3 only | CodeFormer 0.8 on general-x4v3. Writes outputs/real/sheets/<id>.jpg.
Run: .venv/bin/python make_real_sheets.py   (after run_d_real)
"""
from pathlib import Path

import cv2
import numpy as np
from facexlib.detection import init_detection_model

from make_sheets import crop, face_boxes, label

HERE = Path(__file__).resolve().parent
OUT = HERE / "outputs" / "real"
COLUMNS = [("input.png", "Old photo (1200 px)"), ("bg.png", "ESRGAN general v3 x2"),
           ("codeformer-0.8.png", "+ CodeFormer 0.8")]


def main() -> None:
    detector = init_detection_model("retinaface_resnet50", half=False, device="cpu")
    (OUT / "sheets").mkdir(exist_ok=True)
    for folder in sorted(p for p in OUT.iterdir() if (p / "input.png").exists()):
        reference = cv2.imread(str(folder / "input.png"))
        rows = []
        for box in face_boxes(detector, reference, limit=4):
            tiles = []
            for file_name, title in COLUMNS:
                image = cv2.imread(str(folder / file_name))
                tiles.append(label(crop(image, box, image.shape[1] / reference.shape[1]), title))
            rows.append(np.hstack(tiles))
        if rows:
            grid = [np.hstack(rows[i:i + 2]) if i + 1 < len(rows) else np.hstack([rows[i], np.full_like(rows[i], 255)])
                    for i in range(0, len(rows), 2)]
            cv2.imwrite(str(OUT / "sheets" / f"{folder.name}.jpg"), np.vstack(grid), [cv2.IMWRITE_JPEG_QUALITY, 90])
            print(folder.name, len(rows))


if __name__ == "__main__":
    main()
