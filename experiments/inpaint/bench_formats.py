"""Latency / memory of the exported on-device graphs on this Mac (proxy for phones).

Each configuration runs in its own subprocess so ru_maxrss is that configuration's peak.

    <venv>/bin/python bench_formats.py                 # Core ML (4 compute-unit modes) + ONNX Runtime
    <venv_tflite>/bin/python bench_formats.py tflite   # LiteRT CPU (XNNPACK) interpreter

Appends to results/bench_formats.json. Physical phones are intentionally NOT used here (policy:
no installs on phones for this evaluation); docs/v1/remove-evaluation.md derives phone estimates
from these numbers plus published per-chip ratios.
"""
from __future__ import annotations

import json
import os
import resource
import statistics
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
EXPORT_DIR = HERE / "models" / "exported"
RESULTS_PATH = HERE / "results" / "bench_formats.json"
RUNS = 8


def peak_rss_mb() -> float:
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)


def sample_feed() -> dict:
    rng = np.random.default_rng(0)
    image = rng.random((1, 3, 512, 512), dtype=np.float32)
    mask = np.zeros((1, 1, 512, 512), np.float32)
    mask[..., 180:330, 200:300] = 1
    return {"image": image, "mask": mask}


def time_runs(predict) -> dict:
    predict()  # first call: lazy allocations / ANE plan
    durations = []
    for _ in range(RUNS):
        started = time.perf_counter()
        predict()
        durations.append(time.perf_counter() - started)
    return {"median_ms": round(1000 * statistics.median(durations), 1), "min_ms": round(1000 * min(durations), 1)}


def run_single(config: str) -> dict:
    model_name, runtime, variant = config.split(":")
    feed = sample_feed()
    rss_start = peak_rss_mb()
    load_started = time.perf_counter()
    if runtime == "coreml":
        import coremltools as ct

        units = {"cpu": ct.ComputeUnit.CPU_ONLY, "gpu": ct.ComputeUnit.CPU_AND_GPU,
                 "ane": ct.ComputeUnit.CPU_AND_NE, "all": ct.ComputeUnit.ALL}[variant]
        model = ct.models.MLModel(str(EXPORT_DIR / f"{model_name}_512_fp16.mlpackage"), compute_units=units)
        predict = lambda: model.predict(feed)
    elif runtime == "onnx":
        import onnxruntime as ort

        options = ort.SessionOptions()
        options.intra_op_num_threads = 4
        session = ort.InferenceSession(str(EXPORT_DIR / f"{model_name}_512.onnx"), options,
                                       providers=["CPUExecutionProvider"])
        predict = lambda: session.run(None, feed)
    elif runtime == "tflite":
        from ai_edge_litert.interpreter import Interpreter

        interpreter = Interpreter(model_path=str(EXPORT_DIR / f"{model_name}_512_fp32.tflite"), num_threads=4)
        interpreter.allocate_tensors()
        inputs = interpreter.get_input_details()

        def predict():
            for detail in inputs:
                key = "image" if tuple(detail["shape"]) == (1, 3, 512, 512) else "mask"
                interpreter.set_tensor(detail["index"], feed[key])
            interpreter.invoke()
    else:
        raise SystemExit(f"unknown runtime {runtime}")
    load_ms = round(1000 * (time.perf_counter() - load_started), 1)
    timings = time_runs(predict)
    return {"config": config, "load_ms": load_ms, **timings,
            "peak_rss_mb": round(peak_rss_mb(), 1), "rss_before_load_mb": round(rss_start, 1),
            "load_average": [round(v, 1) for v in os.getloadavg()]}


def main() -> None:
    if len(sys.argv) > 2 and sys.argv[1] == "--single":
        print(json.dumps(run_single(sys.argv[2])))
        return
    mode = sys.argv[1] if len(sys.argv) > 1 else "default"
    if mode == "tflite":
        configs = [f"{m}:tflite:cpu4" for m in ("migan", "lama")]
    else:
        configs = [f"{m}:coreml:{u}" for m in ("migan", "lama") for u in ("cpu", "gpu", "ane", "all")]
        configs += [f"{m}:onnx:cpu4" for m in ("migan", "lama")]
    RESULTS_PATH.parent.mkdir(exist_ok=True)
    existing = json.loads(RESULTS_PATH.read_text()) if RESULTS_PATH.exists() else {}
    for config in configs:
        completed = subprocess.run([sys.executable, __file__, "--single", config], capture_output=True, text=True)
        lines = [line for line in completed.stdout.splitlines() if line.startswith("{")]
        if completed.returncode != 0 or not lines:
            existing[config] = {"error": completed.stderr.strip().splitlines()[-1:]}
        else:
            existing[config] = json.loads(lines[-1])
        print(config, existing[config], flush=True)
        RESULTS_PATH.write_text(json.dumps(existing, indent=2) + "\n")


if __name__ == "__main__":
    main()
