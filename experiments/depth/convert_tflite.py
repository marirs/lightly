"""Convert Depth Anything V2 Small to LiteRT (TFLite) for Android and check parity/speed.

Runs in a SEPARATE venv because ai-edge-torch needs a newer torch than coremltools supports:
  python3.11 -m venv .venv_tflite && .venv_tflite/bin/pip install ai-edge-torch transformers==4.46.3 pillow
  .venv_tflite/bin/python convert_tflite.py            # convert + benchmark
  .venv_tflite/bin/python convert_tflite.py --bench    # benchmark only

Output: models/converted/da2_small_<W>x<H>_fp32.tflite and _wi8.tflite (int8 weights, fp32 activations) when the
converter supports it); results/conversion_tflite.json. Same input contract as convert.py
(NCHW float32 'pixel_values', ImageNet-normalised; output 1 x 392 x 518 relative disparity).
"""
import json
import os
import pathlib
import statistics
import sys
import time

import numpy as np
import torch

HERE = pathlib.Path(__file__).resolve().parent
CONVERTED = HERE / "models" / "converted"
RESULTS = HERE / "results" / "conversion_tflite.json"
# --square converts the single 518x518 model recommended for both orientations (see convert.py).
SQUARE = "--square" in sys.argv
HEIGHT, WIDTH = (518, 518) if SQUARE else (392, 518)
TAG = f"{WIDTH}x{HEIGHT}"


class DepthRaw(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, pixel_values):
        return self.model(pixel_values=pixel_values).predicted_depth


def load_model():
    from transformers import AutoModelForDepthEstimation
    return DepthRaw(AutoModelForDepthEstimation.from_pretrained(HERE / "models" / "da2_small").eval()).eval()


def sample_tensor() -> np.ndarray:
    from PIL import Image
    image = Image.open(HERE / "cache" / "src" / "portrait_deep_02.png").convert("RGB").resize((WIDTH, HEIGHT), Image.BICUBIC)
    array = np.asarray(image, np.float32) / 255.0
    array = (array - np.array([0.485, 0.456, 0.406], np.float32)) / np.array([0.229, 0.224, 0.225], np.float32)
    return array.transpose(2, 0, 1)[None].astype(np.float32)


def convert(model) -> dict:
    try:
        import litert_torch as converter_module
    except ImportError:
        import ai_edge_torch as converter_module
    CONVERTED.mkdir(parents=True, exist_ok=True)
    report = {"converter": f"{converter_module.__name__} {getattr(converter_module, '__version__', '?')}", "torch": torch.__version__}
    example = (torch.from_numpy(sample_tensor()),)
    started = time.perf_counter()
    edge_model = converter_module.convert(model, example)
    edge_model.export(str(CONVERTED / f"da2_small_{TAG}_fp32.tflite"))
    report["fp32"] = {"bytes": (CONVERTED / f"da2_small_{TAG}_fp32.tflite").stat().st_size,
                      "convert_s": round(time.perf_counter() - started, 1)}
    try:
        from ai_edge_quantizer import quantizer, recipe
        quantiser = quantizer.Quantizer(str(CONVERTED / f"da2_small_{TAG}_fp32.tflite"))
        quantiser.load_quantization_recipe(recipe.dynamic_wi8_afp32())
        quantiser.quantize().export_model(str(CONVERTED / f"da2_small_{TAG}_wi8.tflite"))
        report["wi8_afp32"] = {"bytes": (CONVERTED / f"da2_small_{TAG}_wi8.tflite").stat().st_size}
    except Exception as error:  # quantiser API drifts between releases; record and carry on
        report["wi8_afp32"] = {"skipped": repr(error)[:300]}
    return report


def benchmark(model, report: dict) -> None:
    from ai_edge_litert.interpreter import Interpreter
    tensor = sample_tensor()
    with torch.inference_mode():
        reference = model(torch.from_numpy(tensor))[0].numpy()
    for variant in ("fp32", "wi8_afp32"):
        path = CONVERTED / (f"da2_small_{TAG}_fp32.tflite" if variant == "fp32" else f"da2_small_{TAG}_wi8.tflite")
        if not path.exists():
            continue
        interpreter = Interpreter(model_path=str(path), num_threads=4)
        interpreter.allocate_tensors()
        input_index = interpreter.get_input_details()[0]["index"]
        output_index = interpreter.get_output_details()[0]["index"]
        interpreter.set_tensor(input_index, tensor)
        interpreter.invoke()
        timings = []
        for _ in range(5):
            started = time.perf_counter()
            interpreter.set_tensor(input_index, tensor)
            interpreter.invoke()
            timings.append((time.perf_counter() - started) * 1000)
        output = np.squeeze(interpreter.get_tensor(output_index))
        report.setdefault(variant, {}).update({
            "mac_m4_xnnpack_4threads_ms": round(statistics.median(timings), 1),
            "vs_pytorch_corr": round(float(np.corrcoef(output.ravel(), reference.ravel())[0, 1]), 5),
        })


def main() -> None:
    torch.set_num_threads(4)
    model = load_model()
    everything = json.loads(RESULTS.read_text()) if RESULTS.exists() else {}
    if "fp32" in everything:  # first run stored a flat 518x392 report
        everything = {"518x392": everything}
    report = everything.get(TAG, {}) if "--bench" in sys.argv else convert(model)
    report["load_average"] = [round(x, 1) for x in os.getloadavg()]
    benchmark(model, report)
    everything[TAG] = report
    RESULTS.write_text(json.dumps(everything, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
