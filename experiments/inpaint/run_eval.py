"""Run one removal candidate over every case and record results, time and peak memory.

One candidate per process so ru_maxrss is that candidate's own peak (torch / OpenCV runtime
included). Usage (from experiments/inpaint/):

    OMP_NUM_THREADS=4 <venv>/bin/python run_eval.py lama
    OMP_NUM_THREADS=4 <venv>/bin/python run_eval.py migan
    OMP_NUM_THREADS=4 <venv>/bin/python run_eval.py lama_flex1024
    OMP_NUM_THREADS=4 <contrib-venv>/bin/python run_eval.py telea      # needs opencv-contrib for shiftmap
    OMP_NUM_THREADS=4 <contrib-venv>/bin/python run_eval.py shiftmap

Writes out/<candidate>/<case>.png (full-res result, git-ignored) and results/<candidate>.json.
"""
from __future__ import annotations

import json
import os
import resource
import statistics
import sys
import time

import numpy as np
from PIL import Image

import inpaint_lib as lib

TIMED_REPEATS = 3
THREADS = int(os.environ.get("OMP_NUM_THREADS", "4"))


def peak_rss_mb() -> float:
    # macOS reports ru_maxrss in bytes (Linux: KiB). This experiment only runs on macOS.
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)


def build_candidate(candidate_name: str) -> lib.Inpainter:
    if candidate_name in ("lama", "migan", "lama_flex1024"):
        import torch

        torch.set_num_threads(THREADS)
    if candidate_name == "lama":
        return lib.LamaInpainter(fixed_side=lib.MODEL_INPUT_SIDE)
    if candidate_name == "lama_flex1024":
        return lib.LamaInpainter(fixed_side=None, max_side=1024)
    if candidate_name == "migan":
        return lib.MiganInpainter()
    if candidate_name in ("telea", "shiftmap"):
        import cv2

        cv2.setNumThreads(THREADS)
        inpainter = lib.OpenCvTeleaInpainter() if candidate_name == "telea" else lib.OpenCvExemplarInpainter()
        # Classical fills are resolution independent, but ShiftMap's cost explodes on 2000 px windows;
        # cap at 1024 like the flexible LaMa variant so the comparison stays like-for-like.
        inpainter.max_side = 1024
        return inpainter
    raise SystemExit(f"unknown candidate {candidate_name!r}")


def main() -> None:
    candidate_name = sys.argv[1]
    only_cases = set(sys.argv[2:])
    load_average_at_start = [round(value, 1) for value in os.getloadavg()]
    rss_before_load = peak_rss_mb()
    load_started = time.perf_counter()
    inpainter = build_candidate(candidate_name)
    load_seconds = time.perf_counter() - load_started

    # Warm-up at the model's input size so first-call allocations are not billed to case 1.
    warm_image = np.full((lib.MODEL_INPUT_SIDE, lib.MODEL_INPUT_SIDE, 3), 128, np.uint8)
    warm_mask = np.zeros((lib.MODEL_INPUT_SIDE, lib.MODEL_INPUT_SIDE), np.uint8)
    warm_mask[200:300, 200:300] = 255
    inpainter.inpaint(warm_image, warm_mask)
    rss_after_warmup = peak_rss_mb()

    output_dir = lib.EXPERIMENT_ROOT / "out" / candidate_name
    output_dir.mkdir(parents=True, exist_ok=True)
    case_records = []
    for case in lib.load_cases():
        if only_cases and case.case_id not in only_cases:
            continue
        image = lib.load_rgb(case.photo_path)
        height, width = image.shape[:2]
        hole_mask = lib.rasterise_mask(case, width, height)
        total_seconds, inference_seconds = [], []
        result, info = None, None
        for _ in range(TIMED_REPEATS):
            started = time.perf_counter()
            result, info = lib.remove_strokes(inpainter, image, hole_mask)
            total_seconds.append(time.perf_counter() - started)
            inference_seconds.append(info["inference_s"])
        Image.fromarray(result).save(output_dir / f"{case.case_id}.png", compress_level=1)
        unchanged_outside = bool(np.array_equal(
            result[lib.dilate_disc(hole_mask, 12) == 0], image[lib.dilate_disc(hole_mask, 12) == 0]))
        record = {
            "case": case.case_id,
            "image_wh": [width, height],
            "mask_area_pct": round(100 * float((hole_mask > 0).mean()), 3),
            "jobs": [{key: value for key, value in job.items() if key != "inference_s"} | {
                "inference_s": round(job["inference_s"], 4)} for job in info["jobs"]],
            "total_s_median": round(statistics.median(total_seconds), 4),
            "inference_s_median": round(statistics.median(inference_seconds), 4),
            # min is the least contention-affected estimate on a shared machine.
            "total_s_min": round(min(total_seconds), 4),
            "inference_s_min": round(min(inference_seconds), 4),
            "pixels_outside_brush_unchanged": unchanged_outside,
        }
        case_records.append(record)
        print(f"{candidate_name} {case.case_id}: total {record['total_s_median']:.3f}s "
              f"inference {record['inference_s_median']:.3f}s routes "
              f"{[job['route'] for job in info['jobs']]}", flush=True)

    summary = {
        "candidate": candidate_name,
        "threads": THREADS,
        "machine": "Apple M4 (macOS), CPU only",
        # The host was shared with other agents/emulators during this run; wall-clock times are
        # inflated by contention, so the load average is recorded next to them.
        "load_average_at_start": load_average_at_start,
        "load_average_at_end": [round(value, 1) for value in os.getloadavg()],
        "load_s": round(load_seconds, 3),
        "peak_rss_mb_before_load": round(rss_before_load, 1),
        "peak_rss_mb_after_warmup_512": round(rss_after_warmup, 1),
        "peak_rss_mb_end": round(peak_rss_mb(), 1),
        "cases": case_records,
    }
    results_dir = lib.EXPERIMENT_ROOT / "results"
    results_dir.mkdir(exist_ok=True)
    suffix = "" if not only_cases else "_partial"
    (results_dir / f"{candidate_name}{suffix}.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({key: value for key, value in summary.items() if key != "cases"}))


if __name__ == "__main__":
    main()
