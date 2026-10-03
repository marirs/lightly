"""Export a trained run's classifier to LiteRT (TFLite) fp32 and check parity against torch.

Runs in a SEPARATE venv (litert-torch / ai-edge-torch need a newer torch than coremltools supports; same
arrangement as experiments/depth/convert_tflite.py):
  <venv_tflite>/bin/python export_tflite.py runs/<run-id> [--inputs <npy of [N,3,256,256] float32>]

Writes runs/<run-id>/export/auto_classifier_fp32.tflite and adds a "tflite" block to export_card.json (written
by export.py, which must run first). Input "image" [1,3,256,256] sRGB [0,1] -> weights [1,3]; the basis LUT bin
from export.py is shared by every runtime. fp32 only (fp16 was rejected in M1).
Parity inputs: the same pinned-resize tensors export.py used (export/parity_inputs.npy).
"""
from __future__ import annotations

import hashlib
import json
import os
import sys

import numpy as np
import torch

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                                "experiments", "lut3d", "reference"))
import ia3dlut as ia  # noqa: E402


def main(run_dir: str) -> dict:
    torch.set_num_threads(4)
    export_dir = os.path.join(run_dir, "export")
    card_path = os.path.join(export_dir, "export_card.json")
    card = json.load(open(card_path))
    classifier = ia.ReferenceClassifier(include_internal_resize=False)
    classifier.load_state_dict(torch.load(os.path.join(run_dir, "classifier.pt"), map_location="cpu", weights_only=True), strict=True)
    classifier.eval()
    inputs = np.load(os.path.join(export_dir, "parity_inputs.npy")).astype(np.float32)
    with torch.no_grad():
        reference = classifier(torch.from_numpy(inputs)).numpy()
    try:
        import litert_torch as converter
    except ImportError:
        import ai_edge_torch as converter
    tflite_path = os.path.join(export_dir, "auto_classifier_fp32.tflite")
    converter.convert(classifier, (torch.from_numpy(inputs[:1]),)).export(tflite_path)
    from ai_edge_litert.interpreter import Interpreter
    interpreter = Interpreter(model_path=tflite_path, num_threads=4)
    interpreter.allocate_tensors()
    input_index = interpreter.get_input_details()[0]["index"]
    output_index = interpreter.get_output_details()[0]["index"]
    outputs = []
    for x in inputs:
        interpreter.set_tensor(input_index, x[None])
        interpreter.invoke()
        outputs.append(interpreter.get_tensor(output_index).reshape(3))
    outputs = np.stack(outputs)
    basis = np.load(os.path.join(run_dir, "basis_luts.npy")).astype(np.float32)
    worst_lut = max(float(np.abs(ia.fuse_luts(basis, a) - ia.fuse_luts(basis, b)).max()) * 255 for a, b in zip(outputs, reference))
    card["artifacts"]["auto_classifier_fp32.tflite"] = {"bytes": os.path.getsize(tflite_path),
                                                        "sha256": hashlib.sha256(open(tflite_path, "rb").read()).hexdigest()}
    card["parity"]["tflite_vs_torch_weights_max_abs"] = float(np.abs(outputs - reference).max())
    card["parity"]["tflite_fused_lut_max_delta_8bit"] = worst_lut
    card["parity"]["passes"] = bool(card["parity"]["passes"] and card["parity"]["tflite_vs_torch_weights_max_abs"] <= 1e-3)
    card.setdefault("toolchain", {})["tflite"] = f"{converter.__name__} {getattr(converter, '__version__', '?')}, torch {torch.__version__}"
    json.dump(card, open(card_path, "w"), indent=2)
    print(json.dumps({k: card["parity"][k] for k in ("tflite_vs_torch_weights_max_abs", "tflite_fused_lut_max_delta_8bit", "passes")}))
    return card


if __name__ == "__main__":
    main(sys.argv[1])
