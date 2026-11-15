"""Enhance step 2c: compares full-pipeline outputs (phone_pipeline.py on the Mac, the phone harnesses) per photo.

For each face of the Mac run (outputs/phone-pipeline/mac/<id>.json) it reports the mean difference (0-255, all three
channels) in a square around the face in the 2x output: side 3 x the eye gap, centred between eyes and mouth. Away
from the faces it reports the background's mean and 99.9th-percentile difference. Writes a sheet of face crops
(columns: input, then each compared output) to outputs/phone-pipeline/sheets/<id>.jpg.

Run: .venv/bin/python compare_phone_pipeline.py <name>=<folder or reference> ...
  e.g. reference=codeformer mac=outputs/phone-pipeline/mac a069=outputs/phone-pipeline/a069
  `codeformer` stands for CodeFormer's own pipeline (outputs/app-models/<id>-reference.png, step 2a); a source with
  {} is a path pattern for the photo id. The first name is the baseline the others are measured against.
"""
import json
import sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
MAC = HERE / "outputs" / "phone-pipeline" / "mac"
SCALE = 2


def image_for(source: str, photo: str):
    """source: `codeformer`, a folder of <id>.png, or a path pattern with {} for the photo id."""
    if source == "codeformer":
        source = "outputs/app-models/{}-reference.png"
    path = HERE / source.format(photo) if "{}" in source else HERE / source / f"{photo}.png"
    if not path.exists():
        return None
    image = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    # CodeFormer's helper saves 16-bit when a grey photo's restored face overshoots 256 (7fsmqjUKrCc reaches 257):
    # the values are still on the 8-bit scale.
    if image.ndim == 3 and image.shape[2] == 4:   # Android's Bitmap PNGs carry an (opaque) alpha channel
        image = image[:, :, :3]
    return np.clip(image, 0, 255).astype(np.uint8) if image.dtype == np.uint16 else image


def face_box(five: np.ndarray, shape):
    centre = (five[0] + five[1] + five[3] + five[4]) / 4 * SCALE
    half = int(np.linalg.norm(five[0] - five[1]) * SCALE * 1.5)
    x, y = int(centre[0]), int(centre[1])
    return max(y - half, 0), min(y + half, shape[0]), max(x - half, 0), min(x + half, shape[1])


def main() -> None:
    sources = dict(argument.split("=", 1) for argument in sys.argv[1:])
    names = list(sources)
    (HERE / "outputs" / "phone-pipeline" / "sheets").mkdir(parents=True, exist_ok=True)
    summary = {name: {"faces": [], "background_mean": [], "background_p999": []} for name in names[1:]}
    for record_path in sorted(MAC.glob("*.json")):
        photo = record_path.stem
        record = json.loads(record_path.read_text())
        images = {name: image_for(source, photo) for name, source in sources.items()}
        base = images[names[0]]
        if base is None:
            continue
        fives = [np.array(face["five_used"]) for face in record["faces"]]
        boxes = [face_box(five, base.shape) for five in fives]
        away = np.ones(base.shape[:2], bool)
        for y0, y1, x0, x1 in boxes:
            away[y0:y1, x0:x1] = False
        line = [photo]
        for name in names[1:]:
            other = images[name]
            if other is None or other.shape != base.shape:
                line.append(f"{name}: missing")
                continue
            difference = np.abs(other.astype(np.float32) - base.astype(np.float32)).mean(2)
            faces = [float(difference[y0:y1, x0:x1].mean()) for y0, y1, x0, x1 in boxes]
            summary[name]["faces"] += faces
            summary[name]["background_mean"].append(float(difference[away].mean()))
            summary[name]["background_p999"].append(float(np.percentile(difference[away], 99.9)))
            line.append(f"{name}: faces {[round(f, 1) for f in faces]} background {difference[away].mean():.2f} "
                        f"(99.9% {np.percentile(difference[away], 99.9):.1f})")
        print(" | ".join(line), flush=True)
        rows = []
        low = cv2.resize(cv2.imread(str(HERE / "outputs" / "real" / photo / "input.png")), None, fx=SCALE, fy=SCALE,
                         interpolation=cv2.INTER_CUBIC)
        for y0, y1, x0, x1 in boxes:
            crops = [low[y0:y1, x0:x1]] + [images[n][y0:y1, x0:x1] for n in names if images[n] is not None]
            rows.append(np.hstack([cv2.resize(c, (192, 192), interpolation=cv2.INTER_AREA) for c in crops]))
        if rows:
            cv2.imwrite(str(HERE / "outputs" / "phone-pipeline" / "sheets" / f"{photo}.jpg"), np.vstack(rows),
                        [cv2.IMWRITE_JPEG_QUALITY, 92])
    for name, values in summary.items():
        if values["faces"]:
            print(f"{name} vs {names[0]}: {len(values['faces'])} faces, median {np.median(values['faces']):.2f}, "
                  f"largest {max(values['faces']):.2f}; background mean {np.mean(values['background_mean']):.2f}, "
                  f"worst 99.9% {max(values['background_p999']):.1f}")


if __name__ == "__main__":
    main()
