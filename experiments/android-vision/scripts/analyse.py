#!/usr/bin/env python3
"""Summarise VisionEval device results and render contact sheets.

Inputs
  results/<device>/<candidate>/result.json + masks/*.png   (pulled by run_device.sh)
  work/photos/*.jpg                                         (make_test_set.py)
  work/vision_ref/vision.json + masks/                      (vision_reference.swift; iOS parity)
  scripts/ground_truth.json                                 (hand labels)
Outputs
  results/summary.json                       per device x candidate metrics (committed)
  results/summary.md                         the same as markdown tables (committed)
  <sheets>/<device>/{faces,seg}_<candidate>.jpg, <sheets>/<device>/compare_*.jpg,
  <sheets>/vision_reference_{faces,seg}.jpg  contact sheets (outside the repo)
"""
import json
import math
import os
import pathlib
import statistics
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"
PHOTOS = ROOT / "work/photos"
VISION = ROOT / "work/vision_ref"
SHEETS = pathlib.Path(os.environ.get("SHEETS_DIR", pathlib.Path.home() / ".codex/artifacts/lightly/v1/android-vision"))
GROUND_TRUTH = json.load(open(ROOT / "scripts/ground_truth.json"))["photos"]
THUMB = 420
FONT = ImageFont.load_default()

# Which mask of each segmentation candidate represents "the person / main subject".
PRIMARY_MASK = {
    "mlkit_selfie": "person", "mlkit_subject": "foreground", "mp_selfie_square": "person",
    "mp_selfie_landscape": "person", "mp_multiclass": "person", "mp_multiclass_gpu": "person",
    "mp_hair": "hair", "mp_deeplab": "foreground", "mp_interactive_seeded": "subject",
}
PERSON_ONLY = {"mlkit_selfie", "mp_selfie_square", "mp_selfie_landscape", "mp_multiclass", "mp_multiclass_gpu"}
DETAIL_PHOTOS = ["portrait_light_02", "portrait_deep_01", "portrait_medium_02", "group_three_01", "backlit_02", "synthetic_group4"]


# ----------------------------------------------------------------------------- loading
def load_photo(stem, max_edge=None):
    image = Image.open(PHOTOS / f"{stem}.jpg").convert("RGB")
    if max_edge:
        image.thumbnail((max_edge, max_edge))
    return image


def load_mask(path, size):
    """Mask PNG as float array in [0,1] resized to `size` (w, h)."""
    mask = Image.open(path).convert("L").resize(size, Image.BILINEAR)
    return np.asarray(mask, dtype=np.float32) / 255.0


def load_device_results():
    devices = {}
    for device_dir in sorted(p for p in RESULTS.iterdir() if p.is_dir()):
        candidates = {}
        for candidate_dir in sorted(p for p in device_dir.iterdir() if p.is_dir()):
            result_file = candidate_dir / "result.json"
            if result_file.exists():
                candidates[candidate_dir.name] = json.load(open(result_file))
        if candidates:
            devices[device_dir.name] = candidates
    return devices


# ----------------------------------------------------------------------------- face metrics
def centre(box):
    return box[0] + box[2] / 2, box[1] + box[3] / 2


def inside(point, box):
    return box[0] <= point[0] <= box[0] + box[2] and box[1] <= point[1] <= box[1] + box[3]


def match_faces(detections, expected):
    """Greedy centre-in-box matching. Returns (matches {gt_index: det_index}, false_positive_indices)."""
    matches, used = {}, set()
    for gt_index, gt_face in enumerate(expected):
        best, best_distance = None, 1e9
        gx, gy = centre(gt_face["box"])
        for det_index, detection in enumerate(detections):
            if det_index in used or not inside(centre(detection["box"]), gt_face["box"]):
                continue
            dx, dy = centre(detection["box"])
            distance = math.hypot(dx - gx, dy - gy)
            if distance < best_distance:
                best, best_distance = det_index, distance
        if best is not None:
            matches[gt_index] = best
            used.add(best)
    false_positives = [i for i in range(len(detections)) if i not in used]
    return matches, false_positives


def eye_pair(face):
    """Two eye centres sorted by image x, from whichever representation the candidate provides."""
    landmarks = face.get("landmarks", {})
    if "left_eye" in landmarks and "right_eye" in landmarks:
        return sorted([landmarks["left_eye"], landmarks["right_eye"]])
    contours = face.get("contours", {})
    if contours.get("left_eye") and contours.get("right_eye"):
        means = [np.mean(np.array(contours[k])[:, :2], axis=0).tolist() for k in ("left_eye", "right_eye")]
        return sorted(means)
    return None


def face_has_edit_regions(face):
    """Per-face edits (skin / under-eye / eyes / teeth) need a face outline, eye outlines and lips."""
    if face.get("mesh_point_count", 0) >= 468:
        return True
    contours = face.get("contours", {})
    return all(contours.get(k) for k in ("face", "left_eye", "right_eye", "upper_lip_bottom", "lower_lip_top"))


def face_summary(candidate_result, vision):
    per_skin = {}
    required_total = required_hit = optional_hit = false_positives = 0
    regions_ok = matched_count = 0
    eye_errors = []
    per_face_rows = []
    for photo in candidate_result.get("photos", []):
        stem = photo["photo"]
        expected = GROUND_TRUTH.get(stem, {}).get("faces", [])
        detections = photo.get("output", {}).get("faces", []) if "error" not in photo else []
        matches, fps = match_faces(detections, expected)
        false_positives += len(fps)
        vision_faces = vision.get(stem, {}).get("faces", [])
        for gt_index, gt_face in enumerate(expected):
            hit = gt_index in matches
            if gt_face["required"]:
                required_total += 1
                required_hit += hit
                bucket = per_skin.setdefault(gt_face["skin"], [0, 0])
                bucket[0] += hit
                bucket[1] += 1
            else:
                optional_hit += hit
            row = {"photo": stem, "face": gt_index, "skin": gt_face["skin"], "detected": hit}
            if hit:
                detection = detections[matches[gt_index]]
                matched_count += 1
                has_regions = face_has_edit_regions(detection)
                regions_ok += has_regions
                row["edit_regions"] = has_regions
                row["points"] = detection.get("mesh_point_count") or sum(len(v) for v in detection.get("contours", {}).values()) + len(detection.get("landmarks", {}))
                # Eye agreement with Apple Vision pupils, normalised by Vision's inter-ocular distance.
                vision_match, _ = match_faces(vision_faces, [gt_face])
                ours = eye_pair(detection)
                if 0 in vision_match and ours:
                    theirs = eye_pair(vision_faces[vision_match[0]])
                    if theirs:
                        w = photo["width"]; h = photo["height"]
                        to_px = lambda p: (p[0] * w, p[1] * h)
                        iod = math.dist(to_px(theirs[0]), to_px(theirs[1]))
                        error = statistics.mean(math.dist(to_px(a), to_px(b)) for a, b in zip(ours, theirs)) / iod
                        eye_errors.append(error)
                        row["eye_error_iod"] = round(error, 3)
            per_face_rows.append(row)
    return {
        "required_recall": f"{required_hit}/{required_total}",
        "required_recall_ratio": required_hit / required_total if required_total else None,
        "recall_by_skin": {k: f"{v[0]}/{v[1]}" for k, v in sorted(per_skin.items())},
        "optional_hits": optional_hit,
        "false_positives": false_positives,
        "matched_with_edit_regions": f"{regions_ok}/{matched_count}",
        "eye_error_iod_median": round(statistics.median(eye_errors), 3) if eye_errors else None,
        "eye_error_iod_max": round(max(eye_errors), 3) if eye_errors else None,
        "per_face": per_face_rows,
    }


# ----------------------------------------------------------------------------- segmentation metrics
def iou(a, b):
    a = a >= 0.5
    b = b >= 0.5
    union = np.logical_or(a, b).sum()
    return float(np.logical_and(a, b).sum() / union) if union else None


def components(binary, min_fraction=0.003):
    """Count 4-connected components larger than min_fraction of the image (no scipy dependency)."""
    height, width = binary.shape
    labels = np.zeros(binary.shape, dtype=np.int32)
    count = 0
    sizes = []
    for y in range(height):
        for x in range(width):
            if binary[y, x] and not labels[y, x]:
                count += 1
                stack = [(y, x)]
                labels[y, x] = count
                size = 0
                while stack:
                    cy, cx = stack.pop()
                    size += 1
                    for ny, nx in ((cy + 1, cx), (cy - 1, cx), (cy, cx + 1), (cy, cx - 1)):
                        if 0 <= ny < height and 0 <= nx < width and binary[ny, nx] and not labels[ny, nx]:
                            labels[ny, nx] = count
                            stack.append((ny, nx))
                sizes.append(size)
    return sum(1 for s in sizes if s >= min_fraction * height * width)


def face_box_coverage(mask, box):
    height, width = mask.shape
    x0, y0 = int(box[0] * width), int(box[1] * height)
    x1, y1 = int((box[0] + box[2]) * width), int((box[1] + box[3]) * height)
    region = mask[max(0, y0):max(1, y1), max(0, x0):max(1, x1)]
    return float((region >= 0.5).mean()) if region.size else None


def seg_summary(device, candidate, candidate_result, vision):
    mask_name = PRIMARY_MASK.get(candidate)
    rows = {"iou_vs_vision_person": [], "iou_vs_vision_foreground": [], "no_person_coverage": [],
            "transition_width": [], "face_coverage": []}
    group_rows = []
    for photo in candidate_result.get("photos", []):
        stem = photo["photo"]
        mask_info = photo.get("masks", {}).get(mask_name)
        if not mask_info:
            continue
        size = (256, round(256 * photo["height"] / photo["width"])) if photo["width"] >= photo["height"] else (round(256 * photo["width"] / photo["height"]), 256)
        mask = load_mask(RESULTS / device / candidate / mask_info["file"], size)
        truth = GROUND_TRUTH.get(stem, {})
        if truth.get("people"):
            for reference, key in (("person", "iou_vs_vision_person"), ("foreground", "iou_vs_vision_foreground")):
                reference_file = VISION / "masks" / f"{stem}__{reference}.png"
                if reference_file.exists():
                    value = iou(mask, load_mask(reference_file, size))
                    if value is not None:
                        rows[key].append(value)
            if mask_info.get("transition_width_px") is not None:
                rows["transition_width"].append(mask_info["transition_width_px"])
            for face in truth.get("faces", []):
                if face["required"]:
                    coverage = face_box_coverage(mask, face["box"])
                    rows["face_coverage"].append(coverage)
        if truth.get("people") == 0:
            rows["no_person_coverage"].append(mask_info["coverage"])
        if truth.get("category") == "group" or stem == "synthetic_small_faces":
            per_face = [round(face_box_coverage(mask, f["box"]), 2) for f in truth.get("faces", [])]
            group_rows.append({
                "photo": stem, "people": truth.get("people"),
                "components": components(mask >= 0.5),
                "instances": photo.get("output", {}).get("subject_count"),
                "face_box_coverage": per_face,
            })
    median = lambda v: round(statistics.median(v), 3) if v else None
    return {
        "mask": mask_name,
        "iou_vs_vision_person_median": median(rows["iou_vs_vision_person"]),
        "iou_vs_vision_foreground_median": median(rows["iou_vs_vision_foreground"]),
        "people_face_box_coverage_median": median([c for c in rows["face_coverage"] if c is not None]),
        "people_faces_covered": f'{sum(1 for c in rows["face_coverage"] if c and c >= 0.5)}/{len(rows["face_coverage"])}',
        "no_person_coverage_max": round(max(rows["no_person_coverage"]), 4) if rows["no_person_coverage"] else None,
        "no_person_false_masks": sum(1 for c in rows["no_person_coverage"] if c > 0.01),
        "transition_width_px_median": median(rows["transition_width"]),
        "groups": group_rows,
    }


def timing_summary(candidate_result):
    photos = [p for p in candidate_result.get("photos", []) if "warm_median_ms" in p]
    warm = [p["warm_median_ms"] for p in photos]
    return {
        "init_ms": candidate_result.get("init_ms"),
        "cold_first_inference_ms": candidate_result.get("cold_first_inference_ms"),
        "warm_median_ms": round(statistics.median(warm), 1) if warm else None,
        "warm_p90_ms": round(sorted(warm)[int(0.9 * (len(warm) - 1))], 1) if warm else None,
        "peak_rss_mb": round(candidate_result["peak_rss_mb"], 1) if candidate_result.get("peak_rss_mb") else None,
        "peak_rss_over_baseline_mb": round(candidate_result["peak_rss_over_baseline_mb"], 1) if candidate_result.get("peak_rss_over_baseline_mb") else None,
        "errors": sum(1 for p in candidate_result.get("photos", []) if "error" in p) + (1 if "init_error" in candidate_result else 0),
        "init_error": candidate_result.get("init_error"),
        "thermal": f'{candidate_result.get("thermal_start")}->{candidate_result.get("thermal_end")}',
    }


# ----------------------------------------------------------------------------- drawing
def scale_point(point, size):
    return point[0] * size[0], point[1] * size[1]


def draw_faces(image, faces, colour=(0, 255, 120), expected=None):
    draw = ImageDraw.Draw(image)
    size = image.size
    for gt_face in expected or []:
        x, y, w, h = gt_face["box"]
        draw.rectangle([x * size[0], y * size[1], (x + w) * size[0], (y + h) * size[1]], outline=(255, 255, 255) if gt_face["required"] else (160, 160, 160), width=1)
    for face in faces:
        x, y, w, h = face["box"]
        draw.rectangle([x * size[0], y * size[1], (x + w) * size[0], (y + h) * size[1]], outline=colour, width=2)
        for point in face.get("mesh", []):
            px, py = scale_point(point, size)
            draw.point((px, py), fill=(255, 220, 0))
        for name, points in face.get("contours", {}).items():
            if len(points) > 1:
                draw.line([scale_point(p, size) for p in points], fill=(0, 200, 255), width=1)
        for name, point in face.get("landmarks", {}).items():
            px, py = scale_point(point, size)
            draw.ellipse([px - 2, py - 2, px + 2, py + 2], fill=(255, 0, 80))
    return image


def mask_overlay(image, mask):
    """Subject kept, background darkened + tinted, 0.5 contour in yellow."""
    base = np.asarray(image, dtype=np.float32)
    alpha = mask[..., None]
    tint = np.array([40, 0, 90], dtype=np.float32)
    out = base * (0.25 + 0.75 * alpha) + tint * (1 - alpha) * 0.6
    binary = mask >= 0.5
    edge = np.zeros_like(binary)
    edge[:-1, :] |= binary[:-1, :] != binary[1:, :]
    edge[:, :-1] |= binary[:, :-1] != binary[:, 1:]
    out[edge] = [255, 230, 0]
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))


def replacement(image, mask, colour=(30, 200, 90)):
    """Background replacement preview: soft matte composite over flat green."""
    base = np.asarray(image, dtype=np.float32)
    alpha = mask[..., None]
    out = base * alpha + np.array(colour, dtype=np.float32) * (1 - alpha)
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))


def grid(tiles, columns=5, title=None):
    widths = [t[0].width for t in tiles]
    cell_w = max(widths)
    cell_h = max(t[0].height for t in tiles) + 16
    top = 24 if title else 0
    rows = math.ceil(len(tiles) / columns)
    sheet = Image.new("RGB", (cell_w * columns, cell_h * rows + top), (24, 24, 24))
    draw = ImageDraw.Draw(sheet)
    if title:
        draw.text((6, 6), title, fill=(255, 255, 255), font=FONT)
    for index, (tile, label) in enumerate(tiles):
        x = (index % columns) * cell_w
        y = top + (index // columns) * cell_h
        sheet.paste(tile, (x, y))
        draw.text((x + 3, y + tile.height + 2), label, fill=(230, 230, 230), font=FONT)
    return sheet


def face_sheet(title, photos_by_stem, faces_by_stem, labels):
    tiles = []
    for stem in sorted(photos_by_stem):
        image = photos_by_stem[stem].copy()
        draw_faces(image, faces_by_stem.get(stem, []), expected=GROUND_TRUTH.get(stem, {}).get("faces"))
        tiles.append((image, f"{stem}: {labels.get(stem, '')}"))
    return grid(tiles, title=title)


def seg_sheet(title, photos_by_stem, mask_paths, labels):
    tiles = []
    for stem in sorted(photos_by_stem):
        image = photos_by_stem[stem]
        path = mask_paths.get(stem)
        if path and path.exists():
            tiles.append((mask_overlay(image, load_mask(path, image.size)), f"{stem}: {labels.get(stem, '')}"))
        else:
            tiles.append((Image.new("RGB", image.size, (60, 0, 0)), f"{stem}: no mask"))
    return grid(tiles, title=title)


# ----------------------------------------------------------------------------- main
def main():
    devices = load_device_results()
    vision = json.load(open(VISION / "vision.json")) if (VISION / "vision.json").exists() else {}
    thumbs = {p.stem: load_photo(p.stem, THUMB) for p in sorted(PHOTOS.glob("*.jpg"))}
    SHEETS.mkdir(parents=True, exist_ok=True)

    # Apple Vision reference sheets (iOS parity).
    face_sheet("Apple Vision VNDetectFaceLandmarksRequest (macOS 26 reference)", thumbs,
               {k: v["faces"] for k, v in vision.items()}, {k: f'{len(v["faces"])} faces' for k, v in vision.items()}
               ).save(SHEETS / "vision_reference_faces.jpg", quality=88)
    for reference in ("person", "foreground"):
        seg_sheet(f"Apple Vision {reference} mask (macOS 26 reference)", thumbs,
                  {k: VISION / "masks" / f"{k}__{reference}.png" for k in thumbs}, {}
                  ).save(SHEETS / f"vision_reference_{reference}.jpg", quality=88)

    summary = {}
    for device, candidates in devices.items():
        device_sheets = SHEETS / device
        device_sheets.mkdir(parents=True, exist_ok=True)
        summary[device] = {}
        for candidate, result in candidates.items():
            entry = {"kind": result["kind"], "sdk": result["sdk"], "model": result["model"],
                     "device": result.get("device", {}), "init_details": result.get("init_details"),
                     **timing_summary(result)}
            photos = {p["photo"]: p for p in result.get("photos", [])}
            if result["kind"] == "FACE":
                entry.update(face_summary(result, vision))
                faces = {k: p.get("output", {}).get("faces", []) for k, p in photos.items()}
                labels = {k: f'{len(v)} faces' for k, v in faces.items()}
                face_sheet(f"{candidate} on {device}", thumbs, faces, labels).save(device_sheets / f"faces_{candidate}.jpg", quality=88)
            else:
                entry.update(seg_summary(device, candidate, result, vision))
                mask_name = PRIMARY_MASK.get(candidate)
                paths = {k: RESULTS / device / candidate / p["masks"][mask_name]["file"]
                         for k, p in photos.items() if mask_name in p.get("masks", {})}
                labels = {k: f'cov {p["masks"][mask_name]["coverage"]:.2f} tw {p["masks"][mask_name]["transition_width_px"] or 0:.1f}px'
                          for k, p in photos.items() if mask_name in p.get("masks", {})}
                seg_sheet(f"{candidate} [{mask_name}] on {device}", thumbs, paths, labels).save(device_sheets / f"seg_{candidate}.jpg", quality=88)
                # Extra masks (hair / skin / instances) for the photos that matter for Portrait.
                extra = sorted({m for p in photos.values() for m in p.get("masks", {})} - {mask_name})
                if extra:
                    tiles = []
                    for stem in DETAIL_PHOTOS:
                        for mask in extra:
                            info = photos.get(stem, {}).get("masks", {}).get(mask)
                            if info:
                                image = thumbs[stem]
                                tiles.append((mask_overlay(image, load_mask(RESULTS / device / candidate / info["file"], image.size)), f"{stem} {mask}"))
                    if tiles:
                        grid(tiles, columns=min(5, len(tiles)), title=f"{candidate} secondary masks on {device}").save(device_sheets / f"seg_{candidate}_extra.jpg", quality=88)
            summary[device][candidate] = entry
        render_comparisons(device, candidates, thumbs)

    (RESULTS / "summary.json").write_text(json.dumps(summary, indent=1, sort_keys=True))
    (RESULTS / "summary.md").write_text(markdown(summary, vision))
    print((RESULTS / "summary.md").read_text())


def render_comparisons(device, candidates, thumbs):
    """Side-by-side background replacement and per-face landmark crops for the key photos."""
    device_sheets = SHEETS / device
    seg_candidates = [c for c, r in candidates.items() if r["kind"] == "SEGMENTATION" and c != "mp_hair"]
    for stem in DETAIL_PHOTOS:
        image = load_photo(stem, 640)
        tiles = []
        reference = VISION / "masks" / f"{stem}__foreground.png"
        if reference.exists():
            tiles.append((replacement(image, load_mask(reference, image.size)), "Apple Vision foreground (ref)"))
        reference = VISION / "masks" / f"{stem}__person.png"
        if reference.exists():
            tiles.append((replacement(image, load_mask(reference, image.size)), "Apple Vision person (ref)"))
        for candidate in seg_candidates:
            photo = next((p for p in candidates[candidate].get("photos", []) if p["photo"] == stem), None)
            info = photo and photo.get("masks", {}).get(PRIMARY_MASK.get(candidate))
            if info:
                tiles.append((replacement(image, load_mask(RESULTS / device / candidate / info["file"], image.size)), candidate))
        if tiles:
            grid(tiles, columns=4, title=f"background replacement preview: {stem} on {device}").save(device_sheets / f"compare_replace_{stem}.jpg", quality=90)

    face_candidates = [c for c, r in candidates.items() if r["kind"] == "FACE"]
    for stem in ("group_three_01", "synthetic_group4", "synthetic_small_faces", "backlit_01"):
        expected = GROUND_TRUTH.get(stem, {}).get("faces", [])
        full = load_photo(stem)
        tiles = []
        for candidate in face_candidates:
            photo = next((p for p in candidates[candidate].get("photos", []) if p["photo"] == stem), None)
            detections = photo.get("output", {}).get("faces", []) if photo else []
            matches, _ = match_faces(detections, expected)
            for gt_index, gt_face in enumerate(expected):
                x, y, w, h = gt_face["box"]
                box = (int(x * full.width), int(y * full.height), int((x + w) * full.width), int((y + h) * full.height))
                crop = full.crop(box)
                scale = 220 / max(crop.size)
                crop = crop.resize((max(1, int(crop.width * scale)), max(1, int(crop.height * scale))))
                if gt_index in matches:
                    face = detections[matches[gt_index]]
                    shifted = shift_face(face, gt_face["box"])
                    draw_faces(crop, [shifted])
                    label = f"{candidate} f{gt_index} {gt_face['skin']}"
                else:
                    ImageDraw.Draw(crop).rectangle([0, 0, crop.width - 1, crop.height - 1], outline=(255, 0, 0), width=4)
                    label = f"{candidate} f{gt_index} MISSED"
                tiles.append((crop, label))
        if tiles:
            grid(tiles, columns=max(1, len(expected)), title=f"per-face landmarks: {stem} on {device} (rows = candidates)").save(device_sheets / f"compare_faces_{stem}.jpg", quality=90)


def shift_face(face, crop_box):
    """Re-express a face's normalised geometry relative to a crop box."""
    cx, cy, cw, ch = crop_box
    remap = lambda p: [(p[0] - cx) / cw, (p[1] - cy) / ch] + list(p[2:])
    shifted = dict(face)
    shifted["box"] = [(face["box"][0] - cx) / cw, (face["box"][1] - cy) / ch, face["box"][2] / cw, face["box"][3] / ch]
    shifted["mesh"] = [remap(p) for p in face.get("mesh", [])]
    shifted["contours"] = {k: [remap(p) for p in v] for k, v in face.get("contours", {}).items()}
    shifted["landmarks"] = {k: remap(v) for k, v in face.get("landmarks", {}).items()}
    return shifted


def markdown(summary, vision):
    lines = []
    for device, candidates in summary.items():
        lines.append(f"### {device}\n")
        lines.append("Faces | recall (required) | light / medium / deep | FP | edit regions on hits | eye err (IOD) med/max | init ms | cold 1st ms | warm med ms | p90 ms | peak RSS +MB")
        lines.append("---|---|---|---|---|---|---|---|---|---|---")
        for name, e in candidates.items():
            if e["kind"] != "FACE":
                continue
            skin = e.get("recall_by_skin", {})
            lines.append(" | ".join(str(x) for x in [
                name, e.get("required_recall"), " / ".join(skin.get(k, "-") for k in ("light", "medium", "deep")),
                e.get("false_positives"), e.get("matched_with_edit_regions"),
                f'{e.get("eye_error_iod_median")} / {e.get("eye_error_iod_max")}',
                fmt(e.get("init_ms")), fmt(e.get("cold_first_inference_ms")), e.get("warm_median_ms"), e.get("warm_p90_ms"),
                e.get("peak_rss_over_baseline_mb")]))
        lines.append("")
        lines.append("Segmentation | mask | IoU vs Vision person | IoU vs Vision foreground | people faces covered | no-person false masks (max cov) | edge width px | init ms | cold 1st ms | warm med ms | p90 ms | peak RSS +MB")
        lines.append("---|---|---|---|---|---|---|---|---|---|---|---")
        for name, e in candidates.items():
            if e["kind"] != "SEGMENTATION":
                continue
            lines.append(" | ".join(str(x) for x in [
                name, e.get("mask"), e.get("iou_vs_vision_person_median"), e.get("iou_vs_vision_foreground_median"),
                e.get("people_faces_covered"), f'{e.get("no_person_false_masks")} ({e.get("no_person_coverage_max")})',
                e.get("transition_width_px_median"), fmt(e.get("init_ms")), fmt(e.get("cold_first_inference_ms")),
                e.get("warm_median_ms"), e.get("warm_p90_ms"), e.get("peak_rss_over_baseline_mb")]))
        lines.append("")
        lines.append("Groups | photo | people | mask components | instances | per-face coverage")
        lines.append("---|---|---|---|---|---")
        for name, e in candidates.items():
            for g in e.get("groups", []):
                lines.append(f'{name} | {g["photo"]} | {g["people"]} | {g["components"]} | {g["instances"]} | {g["face_box_coverage"]}')
        lines.append("")
        lines.append("Per-face (group photos) | photo | face | skin | detected | edit regions | eye err")
        lines.append("---|---|---|---|---|---|---")
        for name, e in candidates.items():
            for row in e.get("per_face", []):
                if row["photo"] in ("group_three_01", "synthetic_group4", "synthetic_small_faces"):
                    lines.append(f'{name} | {row["photo"]} | {row["face"]} | {row["skin"]} | {row["detected"]} | {row.get("edit_regions", "-")} | {row.get("eye_error_iod", "-")}')
        lines.append("")
    return "\n".join(lines)


def fmt(value):
    return round(value) if isinstance(value, (int, float)) else value


if __name__ == "__main__":
    sys.exit(main())
