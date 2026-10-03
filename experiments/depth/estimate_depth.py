"""Run every downloaded monocular depth candidate on the demonstration photos.

Writes cache/depth/<candidate>/<stem>.npy (float32 relative disparity at model resolution, larger =
nearer, normalised to [0,1] by the 1st/99th percentile) and results/desktop_inference.json
(per-candidate median latency on this Mac).

Working resolution follows Apple's Core ML packaging of Depth Anything V2: the photo is resized
(not cropped) to 518x392 for landscape or 392x518 for portrait. Both sides are multiples of the
ViT patch size (14). MiDaS models use their native square inputs.
"""
import json
import os
import platform
import statistics
import time

os.environ.setdefault("OMP_NUM_THREADS", "4")

import numpy as np
import onnxruntime
import torch
from PIL import Image
from transformers import AutoModelForDepthEstimation

import common

torch.set_num_threads(int(os.environ["OMP_NUM_THREADS"]))
IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
IMAGENET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)
TIMING_REPEATS = 5


def model_input_size(image: np.ndarray, candidate: str) -> tuple[int, int]:
    """(width, height) the candidate is run at."""
    if candidate in ("midas31_swin2_tiny", "midas21_small"):
        return 256, 256
    height, width = image.shape[:2]
    return (518, 392) if width >= height else (392, 518)


def to_tensor(image: np.ndarray, size: tuple[int, int], mean, std) -> np.ndarray:
    resized = Image.fromarray((image * 255).round().astype(np.uint8)).resize(size, Image.BICUBIC)
    array = (np.asarray(resized, dtype=np.float32) / 255.0 - mean) / std
    return array.transpose(2, 0, 1)[None].astype(np.float32)


def normalise_disparity(raw: np.ndarray) -> np.ndarray:
    low, high = np.percentile(raw, [1, 99])
    return np.clip((raw - low) / max(high - low, 1e-6), 0, 1).astype(np.float32)


class TorchCandidate:
    def __init__(self, name: str, mean, std):
        self.name, self.mean, self.std = name, mean, std
        self.model = AutoModelForDepthEstimation.from_pretrained(common.MODELS_DIR / name).eval()

    def __call__(self, image: np.ndarray) -> tuple[np.ndarray, float]:
        tensor = torch.from_numpy(to_tensor(image, model_input_size(image, self.name), self.mean, self.std))
        timings = []
        with torch.inference_mode():
            for _ in range(TIMING_REPEATS):
                started = time.perf_counter()
                output = self.model(pixel_values=tensor).predicted_depth
                timings.append((time.perf_counter() - started) * 1000)
        return output[0].numpy(), statistics.median(timings)


class OnnxCandidate:
    def __init__(self, name: str, filename: str):
        self.name = name
        options = onnxruntime.SessionOptions()
        options.intra_op_num_threads = int(os.environ["OMP_NUM_THREADS"])
        self.session = onnxruntime.InferenceSession(str(common.MODELS_DIR / name / filename), options,
                                                    providers=["CPUExecutionProvider"])

    def __call__(self, image: np.ndarray) -> tuple[np.ndarray, float]:
        tensor = to_tensor(image, model_input_size(image, self.name), IMAGENET_MEAN, IMAGENET_STD)
        input_name = self.session.get_inputs()[0].name
        timings = []
        for _ in range(TIMING_REPEATS):
            started = time.perf_counter()
            output = self.session.run(None, {input_name: tensor})[0]
            timings.append((time.perf_counter() - started) * 1000)
        return np.squeeze(output), statistics.median(timings)


class AppleCoreMLCandidate:
    """Apple's own Core ML conversion (fixed 518x392 input). Portrait photos are rotated in and out."""

    def __init__(self):
        import coremltools
        self.name = "apple_coreml_da2_small"
        self.model = coremltools.models.MLModel(
            str(common.MODELS_DIR / self.name / "DepthAnythingV2SmallF16.mlpackage"),
            compute_units=coremltools.ComputeUnit.ALL)

    def __call__(self, image: np.ndarray) -> tuple[np.ndarray, float]:
        portrait = image.shape[0] > image.shape[1]
        pil = Image.fromarray((image * 255).round().astype(np.uint8))
        if portrait:
            pil = pil.transpose(Image.Transpose.ROTATE_90)
        pil = pil.resize((518, 392), Image.BICUBIC)
        self.model.predict({"image": pil})  # warm-up (first call compiles for the Neural Engine)
        timings = []
        for _ in range(TIMING_REPEATS):
            started = time.perf_counter()
            output = self.model.predict({"image": pil})["depth"]
            timings.append((time.perf_counter() - started) * 1000)
        depth = np.asarray(output, dtype=np.float32)
        if portrait:
            depth = np.rot90(depth, k=-1)
        return depth, statistics.median(timings)


def main() -> None:
    candidates = [
        TorchCandidate("da2_small", IMAGENET_MEAN, IMAGENET_STD),
        TorchCandidate("da1_small", IMAGENET_MEAN, IMAGENET_STD),
        TorchCandidate("midas31_swin2_tiny", np.float32(0.5), np.float32(0.5)),
        OnnxCandidate("midas21_small", "model-small.onnx"),
        AppleCoreMLCandidate(),
    ]
    stems = common.DEMO_PHOTOS + common.REPLACEMENT_BACKGROUNDS
    report = {"machine": platform.processor() or platform.machine(), "omp_threads": os.environ["OMP_NUM_THREADS"],
              "candidates": {}}
    for candidate in candidates:
        out_dir = common.CACHE_DIR / "depth" / candidate.name
        out_dir.mkdir(parents=True, exist_ok=True)
        latencies = []
        for stem in stems:
            raw, latency_ms = candidate(common.load_working_image(stem))
            np.save(out_dir / f"{stem}.npy", normalise_disparity(raw))
            latencies.append(latency_ms)
        report["candidates"][candidate.name] = {
            "median_latency_ms": round(statistics.median(latencies), 1),
            "runtime": type(candidate).__name__,
        }
        print(candidate.name, report["candidates"][candidate.name], flush=True)
    common.RESULTS_DIR.mkdir(exist_ok=True)
    (common.RESULTS_DIR / "desktop_inference.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
