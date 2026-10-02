"""Export a trained run to the app contract and check parity: Core ML fp32, ONNX opset 17, basis LUT bin.

  python export.py runs/<run-id>

Writes runs/<run-id>/export/ (git-ignored):
  auto_classifier_fp32.mlpackage   Core ML mlprogram, input "image" [1,3,256,256] -> "weights" [1,3]
  auto_classifier.onnx             same graph for ONNX Runtime (Android)
  auto_basis_luts_f32.bin          3 x 33^3 RGBA float32, red fastest (same layout as lut3d/models)
  export_card.json                 sha256s, modelVersion, parity numbers
Parity inputs are the run's own procedural validation scenes, preprocessed with the pinned resize. fp16 is
deliberately not exported (rejected in M1: CPU drift 7/255).
"""
from __future__ import annotations

import hashlib
import json
import os
import sys

import numpy as np
import torch

from lightly_auto.paths import ia3dlut as ia
from lightly_auto import synthetic

PARITY_IMAGES = 8


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    if os.path.isdir(path):
        for root, _, files in sorted(os.walk(path)):
            for name in sorted(files):
                with open(os.path.join(root, name), "rb") as handle:
                    digest.update(handle.read())
    else:
        with open(path, "rb") as handle:
            digest.update(handle.read())
    return digest.hexdigest()


def main(run_dir: str) -> dict:
    torch.set_num_threads(4)
    card = json.load(open(os.path.join(run_dir, "run_card.json")))
    out_dir = os.path.join(run_dir, "export")
    os.makedirs(out_dir, exist_ok=True)
    classifier = ia.ReferenceClassifier(include_internal_resize=False)
    classifier.load_state_dict(torch.load(os.path.join(run_dir, "classifier.pt"), map_location="cpu", weights_only=True), strict=True)
    classifier.eval()
    basis = np.load(os.path.join(run_dir, "basis_luts.npy")).astype(np.float32)
    assert basis.shape == (3, 3, ia.LUT_DIM, ia.LUT_DIM, ia.LUT_DIM), basis.shape

    rng = np.random.default_rng(card["data"]["val_seed"])
    inputs = np.stack([ia.prepare_256_antialiased(synthetic.procedural_scene(rng)) for _ in range(PARITY_IMAGES)]).astype(np.float32)
    with torch.no_grad():
        reference = classifier(torch.from_numpy(inputs)).numpy()

    onnx_path = os.path.join(out_dir, "auto_classifier.onnx")
    torch.onnx.export(classifier, torch.from_numpy(inputs[:1]), onnx_path, input_names=["image"], output_names=["weights"],
                      opset_version=17, dynamo=False)
    import onnxruntime as ort
    session = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    onnx_out = np.concatenate([session.run(None, {"image": x[None]})[0] for x in inputs])

    import coremltools as ct
    traced = torch.jit.trace(classifier, torch.from_numpy(inputs[:1]))
    mlmodel = ct.convert(traced, inputs=[ct.TensorType(name="image", shape=(1, 3, 256, 256))],
                         outputs=[ct.TensorType(name="weights")], convert_to="mlprogram",
                         compute_precision=ct.precision.FLOAT32, minimum_deployment_target=ct.target.iOS16)
    mlmodel.short_description = f"Lightly Auto {card['kind']} run {card['run_id']} - {card['arm_label']}"
    coreml_path = os.path.join(out_dir, "auto_classifier_fp32.mlpackage")
    mlmodel.save(coreml_path)
    coreml_cpu = ct.models.MLModel(coreml_path, compute_units=ct.ComputeUnit.CPU_ONLY)
    coreml_out = np.concatenate([coreml_cpu.predict({"image": x[None]})["weights"] for x in inputs])

    lut_path = os.path.join(out_dir, "auto_basis_luts_f32.bin")
    with open(lut_path, "wb") as handle:
        for index in range(3):
            handle.write(ia.export_lut_rgba_float32(basis[index]))
    round_trip = np.frombuffer(open(lut_path, "rb").read(), np.float32).reshape(3, ia.LUT_DIM, ia.LUT_DIM, ia.LUT_DIM, 4)
    lut_exact = bool(np.array_equal(np.moveaxis(round_trip[..., :3], -1, 1), basis))

    def fused_pixel_delta(weights_a, weights_b):
        """Worst 8-bit output difference caused by a weight difference, over the identity grid."""
        worst = 0.0
        for a, b in zip(weights_a, weights_b):
            worst = max(worst, float(np.abs(ia.fuse_luts(basis, a) - ia.fuse_luts(basis, b)).max()) * 255)
        return worst

    artifacts = {os.path.basename(p): {"bytes": (sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(p) for f in fs)
                                                 if os.path.isdir(p) else os.path.getsize(p)), "sha256": sha256_of(p)}
                 for p in (coreml_path, onnx_path, lut_path)}
    model_version = hashlib.sha256("".join(a["sha256"] for _, a in sorted(artifacts.items())).encode()).hexdigest()[:16]
    export_card = {
        "run_id": card["run_id"], "kind": card["kind"], "arm_label": card["arm_label"],
        "is_ai_auto_candidate": card["is_ai_auto_candidate"], "research_only": card["research_only"], "shippable": card["shippable"],
        "modelVersion": f"{card['kind']}-{model_version}",
        "contract": card["contract"], "artifacts": artifacts,
        "parity": {
            "inputs": f"{PARITY_IMAGES} procedural validation scenes, pinned 256 resize",
            "onnx_vs_torch_weights_max_abs": float(np.abs(onnx_out - reference).max()),
            "coreml_fp32_cpu_vs_torch_weights_max_abs": float(np.abs(coreml_out - reference).max()),
            "onnx_fused_lut_max_delta_8bit": fused_pixel_delta(onnx_out, reference),
            "coreml_fused_lut_max_delta_8bit": fused_pixel_delta(coreml_out, reference),
            "basis_lut_bin_round_trip_exact": lut_exact,
            "contract_weight_tolerance": 1e-3,
        },
        "toolchain": {"torch": torch.__version__, "coremltools": ct.__version__, "onnxruntime": ort.__version__},
    }
    export_card["parity"]["passes"] = (export_card["parity"]["onnx_vs_torch_weights_max_abs"] <= 1e-3
                                       and export_card["parity"]["coreml_fp32_cpu_vs_torch_weights_max_abs"] <= 1e-3 and lut_exact)
    with open(os.path.join(out_dir, "export_card.json"), "w") as handle:
        json.dump(export_card, handle, indent=2)
    print(json.dumps(export_card, indent=2))
    return export_card


if __name__ == "__main__":
    main(sys.argv[1])
