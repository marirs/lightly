"""Convert Depth Anything V2 Small (Apache-2.0) for the apps and measure size, parity and desktop speed.

  python convert.py            # 518x392 / 392x518 Core ML (fp16, linear int8), ONNX (fp32, int8), probes
  python convert.py --square   # adds 518x518 Core ML (fp16, 8-bit palettised) + probes Apple's 8-bit packages

Outputs (git-ignored) in models/converted/; results in results/conversion.json. Every Core ML package
is probed in a child process per compute-unit setting, because a Core ML / MPSGraph compile failure
aborts the interpreter. Findings recorded there: our linear-int8 package aborts on the GPU, our
conversions do not fully compile for the Neural Engine, Apple's INT8 package is numerically wrong on
the Neural Engine -> docs/v1/depth-evaluation.md recommends Apple's F16P8 package for iOS.

Input contract of every converted model (the apps implement exactly this pre-processing):
  RGB image resized (not cropped) to the package's fixed size (the recommended contract is 518x392
  for every orientation, see docs/v1/depth-evaluation.md §R2.1), sRGB
  values 0..255 -> /255 -> ImageNet mean/std normalisation inside the model (Core ML ImageType) or
  done by the caller (ONNX/TFLite input "pixel_values", NCHW float32).
  Output "disparity": 1 x H x W relative inverse depth (larger = nearer), arbitrary affine scale;
  the renderer normalises it by its 1st/99th percentiles (§R2.1).
"""
import json
import os
import pathlib
import resource
import statistics
import subprocess
import sys
import time

os.environ.setdefault("OMP_NUM_THREADS", "4")

import numpy as np
import torch

import common

CONVERTED_DIR = common.MODELS_DIR / "converted"
IMAGENET_MEAN = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1)
IMAGENET_STD = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)
SIZES = {"518x392": (392, 518), "392x518": (518, 392)}  # name -> (height, width)


class DepthWithNormalisation(torch.nn.Module):
    """Core ML wrapper: takes 0..1 RGB (ImageType scale 1/255) and normalises inside the graph."""

    def __init__(self, model):
        super().__init__()
        self.model = model
        # Buffers, not globals: torch.export refuses to capture module-level tensors.
        self.register_buffer("mean", IMAGENET_MEAN.clone())
        self.register_buffer("std", IMAGENET_STD.clone())

    def forward(self, image):
        return self.model(pixel_values=(image - self.mean) / self.std)[0]  # torchscript=True -> tuple


class DepthRaw(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, pixel_values):
        return self.model(pixel_values=pixel_values)[0]


def load_torch_model():
    from transformers import AutoModelForDepthEstimation
    return AutoModelForDepthEstimation.from_pretrained(common.MODELS_DIR / "da2_small", torchscript=True).eval()


def directory_bytes(path: pathlib.Path) -> int:
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) if path.is_dir() else path.stat().st_size


def sample_input(height: int, width: int) -> np.ndarray:
    from PIL import Image
    image = common.load_working_image("portrait_deep_02")
    resized = Image.fromarray((image * 255).round().astype(np.uint8)).resize((width, height), Image.BICUBIC)
    return np.asarray(resized, dtype=np.float32) / 255.0


def correlation(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.corrcoef(a.ravel(), b.ravel())[0, 1])


def relative_error(a: np.ndarray, b: np.ndarray) -> float:
    """Mean |a-b| after normalising both to [0,1] by their own 1st/99th percentiles."""
    def norm(x):
        lo, hi = np.percentile(x, [1, 99])
        return np.clip((x - lo) / (hi - lo), 0, 1)
    return float(np.mean(np.abs(norm(a) - norm(b))))


def convert_coreml(model, report: dict) -> None:
    import coremltools as ct
    from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
    wrapper = DepthWithNormalisation(model).eval()
    for name, (height, width) in SIZES.items():
        example = torch.rand(1, 3, height, width)
        # torch.export keeps the fixed input shape static; torch.jit.trace leaves DINOv2's
        # position-embedding interpolation as int() casts on shape tensors, which Core ML rejects.
        traced = torch.export.export(wrapper, (example,)).run_decompositions({})
        mlmodel = ct.convert(
            traced,
            inputs=[ct.ImageType(name="image", shape=(1, 3, height, width), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
            outputs=[ct.TensorType(name="disparity")],
            compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=ct.target.iOS17,
            convert_to="mlprogram",
        )
        mlmodel.short_description = "Depth Anything V2 Small (Apache-2.0), relative disparity, larger = nearer"
        mlmodel.license = "Apache-2.0 (weights: depth-anything/Depth-Anything-V2-Small-hf @ 5426e4f)"
        path = CONVERTED_DIR / f"DepthAnythingV2Small_{name}_fp16.mlpackage"
        mlmodel.save(str(path))
        report["coreml"][f"{name}_fp16"] = {"bytes": directory_bytes(path)}
        if name == "518x392":
            quantised = linear_quantize_weights(mlmodel, OptimizationConfig(
                global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")))
            quantised_path = CONVERTED_DIR / f"DepthAnythingV2Small_{name}_w8.mlpackage"
            quantised.save(str(quantised_path))
            report["coreml"][f"{name}_w8"] = {"bytes": directory_bytes(quantised_path)}


COREML_PACKAGES = {
    "518x392_fp16": CONVERTED_DIR / "DepthAnythingV2Small_518x392_fp16.mlpackage",
    "518x392_w8": CONVERTED_DIR / "DepthAnythingV2Small_518x392_w8.mlpackage",
    "apple_DepthAnythingV2SmallF16": common.MODELS_DIR / "apple_coreml_da2_small" / "DepthAnythingV2SmallF16.mlpackage",
    "apple_DepthAnythingV2SmallF16P8": common.MODELS_DIR / "apple_coreml_da2_small" / "DepthAnythingV2SmallF16P8.mlpackage",
    "apple_DepthAnythingV2SmallF16INT8": common.MODELS_DIR / "apple_coreml_da2_small" / "DepthAnythingV2SmallF16INT8.mlpackage",
}
COMPUTE_UNITS = ("ALL", "CPU_AND_NE", "CPU_AND_GPU", "CPU_ONLY")
PROBE_TIMEOUT_S = 240
SQUARE_PACKAGES = {
    "518x518_fp16": CONVERTED_DIR / "DepthAnythingV2Small_518x518_fp16.mlpackage",
    "518x518_p8": CONVERTED_DIR / "DepthAnythingV2Small_518x518_p8.mlpackage",
}


def reference_path(width: int, height: int) -> pathlib.Path:
    return common.CACHE_DIR / f"coreml_reference_{width}x{height}.npy"


def save_reference(model, width: int, height: int) -> None:
    """PyTorch output on the 8-bit-quantised input the Core ML ImageType sees (fair parity)."""
    quantised = np.round(sample_input(height, width) * 255) / 255
    with torch.inference_mode():
        reference = model(pixel_values=((torch.from_numpy(quantised).permute(2, 0, 1)[None].float() - IMAGENET_MEAN) / IMAGENET_STD))[0][0].numpy()
    np.save(reference_path(width, height), reference)


def coreml_probe(package: str, units_name: str) -> None:
    """Child-process body: load + time one package on one compute-unit setting, print JSON.

    Run out of process because a Core ML/MPSGraph compile failure aborts the whole interpreter
    (observed: 'MLIR pass manager failed' on CPU_AND_GPU), and the parent must record it.
    """
    import coremltools as ct
    from PIL import Image
    spec_input = ct.models.MLModel(package, skip_model_load=True).get_spec().description.input[0].type.imageType
    height, width = spec_input.height, spec_input.width
    pil = Image.fromarray((sample_input(height, width) * 255).round().astype(np.uint8))
    started = time.perf_counter()
    mlmodel = ct.models.MLModel(package, compute_units=getattr(ct.ComputeUnit, units_name))
    load_ms = (time.perf_counter() - started) * 1000
    output_name = mlmodel.get_spec().description.output[0].name
    mlmodel.predict({"image": pil})  # warm-up; first call may compile
    timings = []
    for _ in range(10):
        started = time.perf_counter()
        output = mlmodel.predict({"image": pil})[output_name]
        timings.append((time.perf_counter() - started) * 1000)
    output = np.squeeze(np.asarray(output, dtype=np.float32))
    reference = np.load(reference_path(width, height))
    print(json.dumps({"ms": round(statistics.median(timings), 1), "load_ms": round(load_ms),
                      "vs_pytorch_corr": round(correlation(output, reference), 5),
                      "vs_pytorch_mean_abs_norm": round(relative_error(output, reference), 5),
                      "peak_rss_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1048576, 1)}))


def benchmark_coreml(model, report: dict, packages: dict = COREML_PACKAGES) -> None:
    save_reference(model, 518, 392)
    save_reference(model, 518, 518)
    for variant, package in packages.items():
        entry = report["coreml"].setdefault(variant, {})
        if "bytes" not in entry:
            entry["bytes"] = directory_bytes(package)
        for units_name in COMPUTE_UNITS:
            try:
                completed = subprocess.run([sys.executable, __file__, "--coreml-probe", str(package), units_name],
                                           capture_output=True, text=True, timeout=PROBE_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                # Observed for the square package on the Neural Engine: ANECompilerService never returns.
                entry[f"mac_m4_{units_name}"] = {"failed": f"no result within {PROBE_TIMEOUT_S} s (compile hang)"}
                print(variant, units_name, entry[f"mac_m4_{units_name}"], flush=True)
                continue
            lines = [line for line in completed.stdout.splitlines() if line.startswith("{")]
            if completed.returncode == 0 and lines:
                entry[f"mac_m4_{units_name}"] = json.loads(lines[-1])
            else:
                failure = [line for line in completed.stderr.splitlines() if "rror" in line or "assert" in line]
                entry[f"mac_m4_{units_name}"] = {"failed": (failure[-1] if failure else f"exit {completed.returncode}")[-300:]}
            print(variant, units_name, entry[f"mac_m4_{units_name}"], flush=True)


def convert_square_coreml(model, report: dict) -> None:
    """Single square 518x518 package for both orientations (photo is stretched, not cropped).

    iOS 17 has no multifunction models, so one square shape avoids shipping two packages; on the
    demo set square-vs-native-aspect disparity correlates at 0.982-0.9995, whereas rotating portrait
    photos into a landscape model drops to 0.92 (gravity prior). 8-bit k-means palettisation is
    used instead of linear int8 because our linear-int8 package aborts in MPSGraph on the GPU
    (macOS 26.5, see results/conversion.json).
    """
    import coremltools as ct
    from coremltools.optimize.coreml import OpPalettizerConfig, OptimizationConfig, palettize_weights
    wrapper = DepthWithNormalisation(model).eval()
    example = torch.rand(1, 3, 518, 518)
    exported = torch.export.export(wrapper, (example,)).run_decompositions({})
    mlmodel = ct.convert(exported,
                         inputs=[ct.ImageType(name="image", shape=(1, 3, 518, 518), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
                         outputs=[ct.TensorType(name="disparity")], compute_precision=ct.precision.FLOAT16,
                         minimum_deployment_target=ct.target.iOS17, convert_to="mlprogram")
    mlmodel.short_description = "Depth Anything V2 Small (Apache-2.0), relative disparity, larger = nearer"
    mlmodel.save(str(SQUARE_PACKAGES["518x518_fp16"]))
    palettised = palettize_weights(mlmodel, OptimizationConfig(global_config=OpPalettizerConfig(mode="kmeans", nbits=8)))
    palettised.save(str(SQUARE_PACKAGES["518x518_p8"]))
    for name, path in SQUARE_PACKAGES.items():
        report["coreml"].setdefault(name, {})["bytes"] = directory_bytes(path)


def convert_onnx(model, report: dict) -> None:
    import onnx
    from onnxruntime.quantization import QuantType, quantize_dynamic
    height, width = SIZES["518x392"]
    path = CONVERTED_DIR / "da2_small_518x392.onnx"
    torch.onnx.export(DepthRaw(model).eval(), torch.rand(1, 3, height, width), str(path), opset_version=17,
                      input_names=["pixel_values"], output_names=["disparity"],
                      dynamic_axes={"pixel_values": {2: "height", 3: "width"}, "disparity": {1: "height", 2: "width"}})
    report["onnx"]["fp32"] = {"bytes": directory_bytes(path)}
    try:
        from onnxconverter_common import float16
        fp16 = float16.convert_float_to_float16(onnx.load(str(path)), keep_io_types=True)
        onnx.save(fp16, str(CONVERTED_DIR / "da2_small_518x392_fp16.onnx"))
        report["onnx"]["fp16"] = {"bytes": directory_bytes(CONVERTED_DIR / "da2_small_518x392_fp16.onnx")}
    except Exception as error:  # onnxconverter-common's fp16 pass fails on this graph; record why
        report["onnx"]["fp16"] = {"skipped": repr(error)[:200]}
    quantize_dynamic(str(path), str(CONVERTED_DIR / "da2_small_518x392_int8.onnx"), weight_type=QuantType.QUInt8)
    report["onnx"]["int8_dynamic"] = {"bytes": directory_bytes(CONVERTED_DIR / "da2_small_518x392_int8.onnx")}


def benchmark_onnx(model, report: dict) -> None:
    import onnxruntime
    height, width = SIZES["518x392"]
    image = sample_input(height, width)
    tensor = ((torch.from_numpy(image).permute(2, 0, 1)[None] - IMAGENET_MEAN) / IMAGENET_STD).numpy().astype(np.float32)
    with torch.inference_mode():
        reference = model(pixel_values=torch.from_numpy(tensor))[0][0].numpy()
    for variant, filename in (("fp32", "da2_small_518x392.onnx"), ("fp16", "da2_small_518x392_fp16.onnx"),
                              ("int8_dynamic", "da2_small_518x392_int8.onnx")):
        path = CONVERTED_DIR / filename
        if not path.exists() or "skipped" in report["onnx"].get(variant, {}):
            continue
        options = onnxruntime.SessionOptions()
        options.intra_op_num_threads = 4
        session = onnxruntime.InferenceSession(str(path), options, providers=["CPUExecutionProvider"])
        output = session.run(None, {"pixel_values": tensor})[0]
        timings = []
        for _ in range(5):
            started = time.perf_counter()
            output = session.run(None, {"pixel_values": tensor})[0]
            timings.append((time.perf_counter() - started) * 1000)
        output = np.squeeze(output)
        report["onnx"][variant].update({
            "mac_m4_cpu4_ms": round(statistics.median(timings), 1),
            "vs_pytorch_corr": round(correlation(output, reference), 5),
            "vs_pytorch_mean_abs_norm": round(relative_error(output, reference), 5),
        })


def peak_memory_probe(kind: str, path: str) -> float:
    """Peak RSS (MB) of a fresh process that loads the model and runs one inference."""
    code = f"""
import resource, numpy as np
if {kind!r} == 'coreml':
    import coremltools as ct
    from PIL import Image
    m = ct.models.MLModel({path!r}, compute_units=ct.ComputeUnit.ALL)
    m.predict({{'image': Image.new('RGB', (518, 392))}})
else:
    import onnxruntime as ort
    s = ort.InferenceSession({path!r}, providers=['CPUExecutionProvider'])
    s.run(None, {{'pixel_values': np.zeros((1, 3, 392, 518), np.float32)}})
print(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1048576)
"""
    baseline_code = "import resource, numpy as np\nprint(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1048576)"
    if kind == "coreml":
        baseline_code = "import resource, numpy, coremltools\nprint(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1048576)"
    else:
        baseline_code = "import resource, numpy, onnxruntime\nprint(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1048576)"
    peak = float(subprocess.run([sys.executable, "-c", code], capture_output=True, text=True).stdout.strip().splitlines()[-1])
    base = float(subprocess.run([sys.executable, "-c", baseline_code], capture_output=True, text=True).stdout.strip().splitlines()[-1])
    return round(peak - base, 1)


def main() -> None:
    CONVERTED_DIR.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(4)
    model = load_torch_model()
    report = {"source": "depth-anything/Depth-Anything-V2-Small-hf@5426e4f0f36572d16453bbda7a8389317b1bef99",
              # Timings are only comparable when the machine is otherwise idle; record its load.
              "load_average_at_start": [round(x, 1) for x in os.getloadavg()],
              "params_million": round(sum(p.numel() for p in model.parameters()) / 1e6, 2), "coreml": {}, "onnx": {}}
    if "--reconvert" in sys.argv or not COREML_PACKAGES["518x392_w8"].exists():
        convert_coreml(model, report)
    benchmark_coreml(model, report)
    convert_onnx(model, report)
    benchmark_onnx(model, report)
    report["peak_rss_delta_mb"] = {
        "onnx_fp32_cpu": peak_memory_probe("onnx", str(CONVERTED_DIR / "da2_small_518x392.onnx")),
        "onnx_int8_cpu": peak_memory_probe("onnx", str(CONVERTED_DIR / "da2_small_518x392_int8.onnx")),
    }
    (common.RESULTS_DIR / "conversion.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


def main_square() -> None:
    """--square: add the square single-model variants (and Apple's 8-bit packages) to conversion.json."""
    torch.set_num_threads(4)
    model = load_torch_model()
    results_path = common.RESULTS_DIR / "conversion.json"
    report = json.loads(results_path.read_text())
    report["load_average_at_square_run"] = [round(x, 1) for x in os.getloadavg()]
    if "--reconvert" in sys.argv or not SQUARE_PACKAGES["518x518_p8"].exists():
        convert_square_coreml(model, report)
    apple = {k: v for k, v in COREML_PACKAGES.items() if k.startswith("apple_DepthAnythingV2SmallF16") and k != "apple_DepthAnythingV2SmallF16"}
    benchmark_coreml(model, report, {**SQUARE_PACKAGES, **apple})
    results_path.write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--coreml-probe":
        coreml_probe(sys.argv[2], sys.argv[3])
    elif "--square" in sys.argv:
        main_square()
    else:
        main()
