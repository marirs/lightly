"""Enhance step 2f: the glasses-like ring CodeFormer draws on the 18 px eye-gap children in eTOiqGqdCf8 (step 2b).

Is it the pipeline's points, or CodeFormer being unstable on tiny faces? Each small face is aligned (the pipeline's
least-squares similarity) on: the pipeline's points (Face Mesh), MobileNet's own five, the reference RetinaFace
ResNet-50 five, and 8 sub-pixel jitters (uniform +-0.5 px per coordinate, fixed seeds) of the pipeline's and of the
reference points; restored with CodeFormer 0.8 and the original colour exactly as phone_pipeline.py. Writes a sheet of
eye-region crops per face to outputs/ring-study/<photo>-<face>.png (rows labelled), for checking by eye.
Run: .venv/bin/python ring_study.py [photo] [max eye gap]
     .venv/bin/python ring_study.py grid [max eye gap]   (every photo: per face a row of 5 alignments - the points and
     4 jitters - from each source, Face Mesh | MobileNet | ResNet-50 reference; outputs/ring-study/grid-<photo>.png)
     .venv/bin/python ring_study.py met [max eye gap]    (the same rows for every small face the pipeline's detector
     and Face Mesh find in art-test/photo, the 56 Met photographs; 12 rows per outputs/ring-study/met-<n>.png)
"""
import json
import math
import sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import phone_pipeline as pp  # noqa: E402

OUT = HERE / "outputs" / "ring-study"
EYES = (slice(170, 310), slice(120, 392))   # eye region of the 512 aligned face (template eyes at y 240)


def reference_fives(low_bgr: np.ndarray, restorer) -> list:
    helper = restorer.helper("retinaface_resnet50")
    helper.read_image(low_bgr)
    helper.get_face_landmarks_5(only_center_face=False, resize=640, eye_dist_threshold=5)
    return [np.asarray(five, np.float64).reshape(5, 2) for five in helper.all_landmarks_5]


def restore(codeformer, rgb: np.ndarray, five: np.ndarray, grey: bool = False) -> np.ndarray:
    to_face = pp.similarity(five, pp.FACE_TEMPLATE)
    crop = pp.warp_bilinear(rgb, pp.invert_affine(to_face), 512, 512, pp.CROP_BORDER_RGB)
    restored = pp.original_colour(codeformer.restore(crop), crop)
    return (pp.grey_like(restored, crop) if grey else restored), crop


def grid(max_gap: float) -> None:
    """Per photo with faces under max_gap: rows of 15 half-size eye crops (5 alignments x 3 point sources)."""
    codeformer = pp.CodeFormer()
    for record_path in sorted(pp.OUT.glob("*.json")):
        photo = record_path.stem
        record = json.loads(record_path.read_text())
        small = [f for f in record["faces"] if math.dist(f["five_used"][0], f["five_used"][1]) < max_gap]
        if not small:
            continue
        low = cv2.imread(str(HERE / "outputs" / "real" / photo / "input.png"))
        rgb = cv2.cvtColor(low, cv2.COLOR_BGR2RGB).astype(np.float32)
        references = reference_fives(low, codeformer.restorer)
        rows = []
        for face in small:
            ours = np.array(face["five_used"])
            nearest = min(references, key=lambda r: np.linalg.norm((r[0] + r[1]) / 2 - (ours[0] + ours[1]) / 2))
            tiles = []
            for name, base in (("mesh", ours), ("mobile", np.array(face["five"])), ("ref", nearest)):
                for seed in range(5):
                    five = base if seed == 0 else base + np.random.default_rng(seed).uniform(-0.5, 0.5, base.shape)
                    restored, _ = restore(codeformer, rgb, five, record["grey"])
                    tile = labelled(restored, f"{name} {seed}")
                    tiles.append(cv2.resize(tile, (tile.shape[1] // 2, tile.shape[0] // 2), interpolation=cv2.INTER_AREA))
            rows.append(np.hstack(tiles))
        cv2.imwrite(str(OUT / f"grid-{photo}.png"), np.vstack(rows))
        print(photo, len(small), "faces", flush=True)


def labelled(image_rgb: np.ndarray, text: str) -> np.ndarray:
    tile = cv2.cvtColor(np.clip(image_rgb, 0, 255).astype(np.uint8)[EYES], cv2.COLOR_RGB2BGR).copy()
    cv2.putText(tile, text, (6, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 255), 1, cv2.LINE_AA)
    return tile


def face_row(codeformer, rgb, grey, mesh_five, mobile_five, reference, label):
    """15 half-size eye crops: 5 alignments (the points, then 4 jitters) per source; reference may be None."""
    tiles = []
    for name, base in (("mesh", mesh_five), ("mobile", mobile_five), ("ref", reference)):
        for seed in range(5):
            if base is None:
                tiles.append(np.zeros((70, 136, 3), np.uint8))
                continue
            five = base if seed == 0 else base + np.random.default_rng(seed).uniform(-0.5, 0.5, base.shape)
            restored, _ = restore(codeformer, rgb, five, grey)
            tile = labelled(restored, f"{label} {name} {seed}" if seed == 0 and name == "mesh" else f"{name} {seed}")
            tiles.append(cv2.resize(tile, (136, 70), interpolation=cv2.INTER_AREA))
    return np.hstack(tiles)


def met(max_gap: float) -> None:
    detector, mesh, codeformer = pp.Detector(), pp.FaceMesh(), pp.CodeFormer()
    rows, sheet, counted = [], 0, 0
    for path in sorted((HERE / "art-test" / "photo").glob("*.jpg")):
        low = cv2.imread(str(path))
        rgb = cv2.cvtColor(low, cv2.COLOR_BGR2RGB).astype(np.float32)
        try:
            found = detector.detect(rgb, 640)
            found += [d for d in detector.detect(rgb, 960) if all(pp.iou(d["box"], k["box"]) < pp.EXTRA_IOU for k in found)]
        except ValueError as error:   # longer than 1.6:1, beyond the detector's fixed canvases
            print(path.stem, "skipped:", error, flush=True)
            continue
        small = []
        for detection in found:
            five, _ = mesh.five(rgb, detection)
            five = np.asarray(five, np.float64)
            if math.dist(five[0], five[1]) < max_gap:
                small.append((five, np.asarray(detection["five"], np.float64)))
        if not small:
            continue
        references = reference_fives(low, codeformer.restorer)
        grey = bool(pp.is_grey(rgb))
        for number, (mesh_five, mobile_five) in enumerate(small):
            gap = math.dist(mesh_five[0], mesh_five[1])
            centre = (mesh_five[0] + mesh_five[1]) / 2
            close = [r for r in references if np.linalg.norm((r[0] + r[1]) / 2 - centre) < gap / 2]
            label = f"{path.stem[:10]}#{number} {gap:.0f}px"
            rows.append(face_row(codeformer, rgb, grey, mesh_five, mobile_five, close[0] if close else None, label))
            counted += 1
            if len(rows) == 12:
                cv2.imwrite(str(OUT / f"met-{sheet}.png"), np.vstack(rows))
                rows, sheet = [], sheet + 1
        print(path.stem, len(small), "small faces", flush=True)
    if rows:
        cv2.imwrite(str(OUT / f"met-{sheet}.png"), np.vstack(rows))
    print(counted, "small faces in", sheet + (1 if rows else 0), "sheets")


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "met":
        OUT.mkdir(parents=True, exist_ok=True)
        return met(float(sys.argv[2]) if len(sys.argv) > 2 else 30)
    if len(sys.argv) > 1 and sys.argv[1] == "grid":
        OUT.mkdir(parents=True, exist_ok=True)
        return grid(float(sys.argv[2]) if len(sys.argv) > 2 else 30)
    photo = sys.argv[1] if len(sys.argv) > 1 else "eTOiqGqdCf8"
    max_gap = float(sys.argv[2]) if len(sys.argv) > 2 else 20
    OUT.mkdir(parents=True, exist_ok=True)
    low = cv2.imread(str(HERE / "outputs" / "real" / photo / "input.png"))
    rgb = cv2.cvtColor(low, cv2.COLOR_BGR2RGB).astype(np.float32)
    record = json.loads((pp.OUT / f"{photo}.json").read_text())
    codeformer = pp.CodeFormer()
    references = reference_fives(low, codeformer.restorer)
    for index, face in enumerate(record["faces"]):
        ours = np.array(face["five_used"])
        if math.dist(ours[0], ours[1]) > max_gap:
            continue
        nearest = min(references, key=lambda r: np.linalg.norm((r[0] + r[1]) / 2 - (ours[0] + ours[1]) / 2))
        sets = [("pipeline (Face Mesh)", ours), ("MobileNet five", np.array(face["five"])), ("ResNet-50 reference", nearest)]
        for name, base in (("pipeline", ours), ("reference", nearest)):
            for seed in range(8):
                jitter = np.random.default_rng(seed).uniform(-0.5, 0.5, base.shape)
                sets.append((f"{name} jitter {seed}", base + jitter))
        tiles = []
        for name, five in sets:
            restored, crop = restore(codeformer, rgb, five)
            tiles.append(labelled(restored, name))
        _, crop = restore(codeformer, rgb, ours)
        tiles.insert(0, labelled(crop, "input (pipeline crop)"))
        while len(tiles) % 4:
            tiles.append(np.zeros_like(tiles[0]))
        sheet = np.vstack([np.hstack(tiles[i:i + 4]) for i in range(0, len(tiles), 4)])
        path = OUT / f"{photo}-{index}.png"
        cv2.imwrite(str(path), sheet)
        print(path.name, "eye gap", round(math.dist(ours[0], ours[1]), 1), "reference vs pipeline points (px):",
              np.round(np.linalg.norm(nearest - ours, axis=1), 2).tolist(), flush=True)


if __name__ == "__main__":
    main()
