"""Convert the 256x256 classifier to Core ML (iOS) and ONNX (Android / ONNX Runtime), and export basis LUTs.

Deployment split (both platforms):
  app: decode -> sRGB 8-bit -> antialiased resize to 256x256 -> float [0,1] NCHW  (platform code)
  model: classifier -> 3 weights                                                  (Core ML / ONNX Runtime)
  app: fuse 3 basis LUTs with weights (107,811 x 3 MACs on CPU)                     (platform code)
  app: apply fused 33^3 LUT at preview / full resolution on GPU                     (Core Image / GLES)

Outputs in ../models/ (git-ignored; reproducible from pinned upstream):
  ia3dlut_classifier_fp32.mlpackage, ia3dlut_classifier_fp16.mlpackage, ia3dlut_classifier.onnx,
  ia3dlut_basis_luts_f32.bin  (3 basis x 33^3 x RGBA float32, red fastest), MODEL_CARD.json
"""
import hashlib, json, os, time
import numpy as np
import torch
import coremltools as ct
import ia3dlut as ia

here = os.path.dirname(os.path.abspath(__file__))
out_dir = os.path.join(here, "..", "models")
os.makedirs(out_dir, exist_ok=True)
model = ia.load_reference_model(os.path.join(here, "upstream/pretrained_models/sRGB"))
net = model.classifier_fixed_256.eval()
example = torch.rand(1, 3, 256, 256)

def sha(path):
    h = hashlib.sha256()
    if os.path.isdir(path):
        for root, _, files in sorted(os.walk(path)):
            for f in sorted(files):
                h.update(open(os.path.join(root, f), "rb").read())
    else:
        h.update(open(path, "rb").read())
    return h.hexdigest()

def size(path):
    if os.path.isdir(path):
        return sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(path) for f in fs)
    return os.path.getsize(path)

traced = torch.jit.trace(net, example)
card = {"upstream_commit": "b491f6df64a588864739a157db271e5c848e1805", "variant": "sRGB paired (FiveK expert C)",
        "input": "image: float32 [1,3,256,256], sRGB-encoded RGB in [0,1], no mean/std",
        "output": "weights: float32 [1,3], raw linear (no softmax)", "artifacts": {}}

for precision, tag in ((ct.precision.FLOAT32, "fp32"), (ct.precision.FLOAT16, "fp16")):
    path = os.path.join(out_dir, f"ia3dlut_classifier_{tag}.mlpackage")
    t0 = time.time()
    ml = ct.convert(traced, inputs=[ct.TensorType(name="image", shape=(1, 3, 256, 256))],
                    outputs=[ct.TensorType(name="weights")], convert_to="mlprogram",
                    compute_precision=precision, minimum_deployment_target=ct.target.iOS16)
    ml.short_description = "Image-Adaptive 3D LUT classifier (research weights - see licence notes)"
    ml.save(path)
    card["artifacts"][os.path.basename(path)] = {"bytes": size(path), "sha256": sha(path), "convert_s": round(time.time() - t0, 2)}

onnx_path = os.path.join(out_dir, "ia3dlut_classifier.onnx")
torch.onnx.export(net, example, onnx_path, input_names=["image"], output_names=["weights"], opset_version=17, dynamo=False)
card["artifacts"]["ia3dlut_classifier.onnx"] = {"bytes": size(onnx_path), "sha256": sha(onnx_path)}

lut_path = os.path.join(out_dir, "ia3dlut_basis_luts_f32.bin")
with open(lut_path, "wb") as f:
    for i in range(3):
        f.write(ia.export_lut_rgba_float32(model.basis_luts[i]))
card["artifacts"]["ia3dlut_basis_luts_f32.bin"] = {"bytes": size(lut_path), "sha256": sha(lut_path),
    "layout": "3 consecutive LUTs; each 33*33*33 RGBA float32, index = r + 33*g + 33*33*b"}
card["params"] = sum(p.numel() for p in net.parameters())
json.dump(card, open(os.path.join(out_dir, "MODEL_CARD.json"), "w"), indent=2)
print(json.dumps(card, indent=2))
