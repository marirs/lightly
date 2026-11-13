"""Enhance step 1f: the fine-tuned photo-or-art classifier for the phones, and the data to check them.

Model: five 224x224 RGB views in [0, 1] ([5, 3, 224, 224]: whole image + four crops, as finetune_art_classifier.py)
-> one art probability (sigmoid per view, averaged). ImageNet normalisation is inside the model. Writes
coreml/art-classifier.mlpackage (fp32) and tflite/art-classifier.tflite (fp32), and for every test image with a face
outputs/art/phone-views/<name>.u8 (the five views as uint8 HWC, 5*224*224*3 bytes) with reference.csv (PyTorch score).
The phones score the same pixels, so the check covers the model and runtime only, not the app's own resizing.
Run: .venv/bin/python -I export_art_classifier.py
"""
import csv
import sys
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torchvision import models, transforms

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from train_art_classifier import test_images  # noqa: E402

OUT = HERE / "outputs" / "art"
THRESHOLD = 0.8  # chosen on the test set, see README step 1f


class ArtProbability(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def forward(self, views):
        return torch.sigmoid(self.net((views - self.mean) / self.std)).mean(dim=0)  # [1]


def five_views_uint8(image: Image.Image) -> np.ndarray:
    """Same geometry as finetune_art_classifier.five_views, before normalisation."""
    whole = transforms.functional.resize(image, [224, 224])
    large = transforms.functional.resize(image, 448)
    w, h = large.size
    crops = [large.crop((x, y, x + 224, y + 224)) for x, y in
             (((w - 224) // 2, (h - 224) // 2), ((w - 224) // 2, round(h * 0.15)),
              (max(0, round(w * 0.2)), (h - 224) // 2), (max(0, round(w * 0.8) - 224), (h - 224) // 2))]
    return np.stack([np.asarray(v.resize((224, 224)), dtype=np.uint8) for v in [whole] + crops])


def main() -> None:
    net = models.mobilenet_v3_large()
    net.classifier[-1] = torch.nn.Linear(net.classifier[-1].in_features, 1)
    net.load_state_dict(torch.load(OUT / "classifier-finetuned.pt", map_location="cpu")["state_dict"])
    model = ArtProbability(net.eval()).eval()
    example = torch.rand(5, 3, 224, 224)

    import coremltools as ct
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(traced, inputs=[ct.TensorType(name="views", shape=example.shape)],
                         outputs=[ct.TensorType(name="art_probability")], convert_to="mlprogram",
                         # fp32: in fp16 three test decisions at the 0.8 threshold flipped (max score shift 0.028);
                         # both apps must make the same call on the same photo.
                         compute_precision=ct.precision.FLOAT32, minimum_deployment_target=ct.target.iOS17)
    mlmodel.save(str(HERE / "coreml" / "art-classifier.mlpackage"))

    import litert_torch
    litert_torch.convert(model, (example,)).export(str(HERE / "tflite" / "art-classifier.tflite"))
    from ai_edge_litert.interpreter import Interpreter
    interpreter = Interpreter(model_path=str(HERE / "tflite" / "art-classifier.tflite"))
    interpreter.allocate_tensors()

    faces = {row["image"] for row in csv.DictReader((OUT / "faces.csv").open())}
    folder = OUT / "phone-views"
    folder.mkdir(parents=True, exist_ok=True)
    rows, worst = [], {"coreml": 0.0, "tflite": 0.0}
    for path, label in test_images():
        if path.name not in faces:
            continue
        views = five_views_uint8(Image.open(path).convert("RGB"))
        name = f"{path.parent.name}-{path.stem}"
        views.tofile(folder / f"{name}.u8")
        tensor = torch.from_numpy(views).permute(0, 3, 1, 2).float() / 255.0
        with torch.no_grad():
            reference = float(model(tensor)[0])
        coreml = float(np.asarray(mlmodel.predict({"views": tensor.numpy()})["art_probability"]).ravel()[0])
        interpreter.set_tensor(interpreter.get_input_details()[0]["index"], tensor.numpy())
        interpreter.invoke()
        tflite = float(interpreter.get_tensor(interpreter.get_output_details()[0]["index"]).ravel()[0])
        worst["coreml"] = max(worst["coreml"], abs(coreml - reference))
        worst["tflite"] = max(worst["tflite"], abs(tflite - reference))
        rows.append([name, int(label), f"{reference:.5f}", f"{coreml:.5f}", f"{tflite:.5f}"])
    with (folder / "reference.csv").open("w", newline="") as handle:
        csv.writer(handle).writerows([["name", "art", "pytorch", "coreml_mac", "tflite_mac"]] + rows)
    flips = {kind: sum((float(r[2]) >= THRESHOLD) != (float(r[column]) >= THRESHOLD) for r in rows)
             for kind, column in (("coreml", 3), ("tflite", 4))}
    size = {p.name: round(sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) / 1e6, 1) if p.is_dir()
            else round(p.stat().st_size / 1e6, 1)
            for p in (HERE / "coreml" / "art-classifier.mlpackage", HERE / "tflite" / "art-classifier.tflite")}
    print(f"{len(rows)} images; max |score - PyTorch|: {worst}; decisions changed at {THRESHOLD}: {flips}; sizes MB {size}")


if __name__ == "__main__":
    main()
