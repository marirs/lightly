"""Export LaMa / MI-GAN to LiteRT (.tflite) with litert-torch, for the Android path.

Runs in its own venv (litert-torch pins a newer torch than the Core ML venv):
    python3.11 -m venv venv_tflite && venv_tflite/bin/pip install litert-torch omegaconf pillow
    venv_tflite/bin/python convert_tflite.py [lama] [migan]

Uses the same app-facing wrappers and the same exact DFT-matmul FourierUnit as convert.py, so
the three exports (Core ML, ONNX, LiteRT) are one graph. Parity is checked with the LiteRT
interpreter against the PyTorch reference and appended to models/exported/conversion_report.json.
"""
from __future__ import annotations

import json
import sys
import time

import numpy as np
import torch

import convert
import inpaint_lib as lib


def export(name: str, wrapper: torch.nn.Module, image: torch.Tensor, mask: torch.Tensor, reference: np.ndarray,
           report: dict) -> None:
    import litert_torch

    started = time.perf_counter()
    edge_model = litert_torch.convert(wrapper.eval(), (image, mask))
    out_path = convert.EXPORT_DIR / f"{name}_{convert.SIDE}_fp32.tflite"
    edge_model.export(str(out_path))
    prediction = edge_model(image, mask)
    prediction = np.asarray(prediction[0] if isinstance(prediction, (list, tuple)) else prediction)
    entry = {
        "path": str(out_path.relative_to(lib.EXPERIMENT_ROOT)),
        "size_mb": convert.size_mb(out_path),
        "convert_s": round(time.perf_counter() - started, 1),
        "psnr_vs_pytorch_db": round(convert.psnr_vs(reference, prediction), 2),
        "max_abs_diff": round(float(np.abs(reference - prediction).max()), 4),
        "sha256": convert.sha256_of(out_path),
        "converter": f"litert-torch {getattr(litert_torch, '__version__', '?')}, torch {torch.__version__}",
    }
    report.setdefault(name, {})["tflite_fp32"] = entry
    print(name, "tflite", entry, flush=True)


def main() -> None:
    torch.set_num_threads(4)
    targets = set(sys.argv[1:]) or {"lama", "migan"}
    report_path = convert.EXPORT_DIR / "conversion_report.json"
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    image, mask = convert.sample_inputs()
    if "migan" in targets:
        wrapper = convert.MiganExportWrapper(lib.build_migan_generator(convert.SIDE)).eval()
        with torch.no_grad():
            reference = wrapper(image, mask).numpy()
        export("migan", wrapper, image, mask, reference, report)
    if "lama" in targets:
        wrapper = convert.LamaExportWrapper(lib.build_lama_generator()).eval()
        with torch.no_grad():
            reference = wrapper(image, mask).numpy()  # true torch.fft reference
        convert.patch_lama_for_export()
        replaced = convert.replace_output_padded_transposed_convs(wrapper)
        with torch.no_grad():
            wrapper(image, mask)  # eager call fills the DFT-matrix caches before tracing
        print("lama: rewrote", replaced, "output-padded transposed convs", flush=True)
        export("lama", wrapper, image, mask, reference, report)
    # Re-read before writing: convert.py may have updated the report concurrently.
    latest = json.loads(report_path.read_text()) if report_path.exists() else {}
    for model_name, entries in report.items():
        if "tflite_fp32" in entries:
            latest.setdefault(model_name, {})["tflite_fp32"] = entries["tflite_fp32"]
    report_path.write_text(json.dumps(latest, indent=2) + "\n")


if __name__ == "__main__":
    main()
