"""Enhance step 1: one comparison sheet per test photo, the same face crop from every method side by side.

The face box comes from RetinaFace (facexlib) on the original; every output is at the original's scale (x4 of the
1/4-size input), so the same box crops the same region. Writes outputs/sheets/<photo>.jpg.
Run: .venv/bin/python make_sheets.py   (after run_a, run_b, run_c)
"""
from pathlib import Path

import cv2
import numpy as np
from facexlib.detection import init_detection_model

HERE = Path(__file__).resolve().parent
OUT = HERE / "outputs"
TILE = 360
COLUMNS = [
    ("0-original.png", "Original"),
    ("1-degraded.png", "Input (1/4, JPEG 35)"),
    ("2-bicubic.png", "Bicubic x4"),
    ("3-general-x4v3.png", "ESRGAN general v3"),
    ("3-x4plus.png", "ESRGAN x4plus"),
    ("4-gfpgan-v1.4.png", "GFPGAN 1.4"),
    ("5-codeformer-w0.5.png", "CodeFormer 0.5"),
    ("5-codeformer-w0.8.png", "CodeFormer 0.8"),
    ("6-gpen-bfr-512.png", "GPEN 512"),
]


def face_boxes(detector, image: np.ndarray, limit: int = 3) -> list:
    """Up to `limit` square boxes around the largest faces, padded to include hair and chin."""
    with __import__("torch").no_grad():
        detections = detector.detect_faces(image, 0.5)
    boxes = []
    for x1, y1, x2, y2, *_ in sorted(detections, key=lambda d: -(d[2] - d[0]) * (d[3] - d[1]))[:limit]:
        side = max(x2 - x1, y2 - y1) * 1.6
        cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
        boxes.append((int(cx - side / 2), int(cy - side / 2), int(side)))
    return boxes


def crop(image: np.ndarray, box: tuple, scale: float) -> np.ndarray:
    x, y, side = (int(round(v * scale)) for v in box)
    padded = cv2.copyMakeBorder(image, side, side, side, side, cv2.BORDER_CONSTANT, value=(255, 255, 255))
    region = padded[y + side:y + 2 * side, x + side:x + 2 * side]
    return cv2.resize(region, (TILE, TILE), interpolation=cv2.INTER_NEAREST if scale < 1 else cv2.INTER_AREA)


def label(tile: np.ndarray, text: str) -> np.ndarray:
    bar = np.full((34, TILE, 3), 255, np.uint8)
    cv2.putText(bar, text, (8, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.62, (20, 20, 20), 1, cv2.LINE_AA)
    return np.vstack([bar, tile])


def main() -> None:
    detector = init_detection_model("retinaface_resnet50", half=False, device="cpu")
    (OUT / "sheets").mkdir(parents=True, exist_ok=True)
    for folder in sorted(p for p in OUT.iterdir() if (p / "0-original.png").exists()):
        original = cv2.imread(str(folder / "0-original.png"))
        rows = []
        for box in face_boxes(detector, original):
            tiles = []
            for file_name, title in COLUMNS:
                image = cv2.imread(str(folder / file_name))
                if image is None:
                    tiles.append(label(np.full((TILE, TILE, 3), 230, np.uint8), f"{title} (missing)"))
                    continue
                tiles.append(label(crop(image, box, image.shape[1] / original.shape[1]), title))
            rows.append(np.hstack(tiles))
        if rows:
            cv2.imwrite(str(OUT / "sheets" / f"{folder.name}.jpg"), np.vstack(rows), [cv2.IMWRITE_JPEG_QUALITY, 90])
            print(folder.name, f"{len(rows)} face row(s)")


if __name__ == "__main__":
    main()
