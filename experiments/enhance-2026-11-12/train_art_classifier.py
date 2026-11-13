"""Enhance step 1f: a small photo-or-art classifier (skip paintings, drawings and prints).

A frozen ImageNet backbone (torchvision MobileNetV3-Large or EfficientNet-B0) and one trained linear layer. Each image is
seen in three views so brushwork stays visible at 224 px: the whole image, and centre and upper crops of the image at
448 px on its short side (faces sit high in portraits). The views' probabilities are averaged.

Training: art-train/ (The Met paintings and drawings + Unsplash paintings = art; Met and Unsplash photographs = photo).
5-fold cross-validation picks the backbone; the final layer is then trained on all of art-train and tested once on the
held-out test set (art-test/, real-photos/, experiments/test-photos; none of them in art-train).
Run: .venv/bin/python -I train_art_classifier.py
"""
import csv
import random
import sys
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torchvision import models, transforms

HERE = Path(__file__).resolve().parent
OUT = HERE / "outputs" / "art"
ART, PHOTO = 1.0, 0.0
DEVICE = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
NORMALISE = transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225])


def training_images():
    folders = {"painting": ART, "drawing": ART, "painting-unsplash": ART, "photo": PHOTO, "photo-unsplash": PHOTO}
    return [(path, label) for folder, label in folders.items()
            for path in sorted((HERE / "art-train" / folder).glob("*.jpg"))]


def test_images():
    images = [(path, ART if folder != "photo" else PHOTO)
              for folder in ("painting", "drawing", "photo") for path in sorted((HERE / "art-test" / folder).glob("*.jpg"))]
    images += [(path, ART if path.stem == "SpeUAC9IOng" else PHOTO) for path in sorted((HERE / "real-photos").glob("*.jpg"))]
    images += [(path, PHOTO) for path in sorted((HERE.parent / "test-photos").glob("*.jpg"))]
    return images


def views(image: Image.Image) -> list:
    whole = transforms.functional.resize(image, [224, 224])
    large = transforms.functional.resize(image, 448)
    width, height = large.size
    centre = transforms.functional.center_crop(large, [224, 224])
    upper = large.crop(((width - 224) // 2, max(0, round(height * 0.15)), (width - 224) // 2 + 224,
                        max(0, round(height * 0.15)) + 224))
    return [NORMALISE(transforms.functional.to_tensor(view)) for view in (whole, centre, upper)]


def backbone(name: str):
    if name == "mobilenet_v3_large":
        net = models.mobilenet_v3_large(weights=models.MobileNet_V3_Large_Weights.IMAGENET1K_V2)
        return torch.nn.Sequential(net.features, net.avgpool, torch.nn.Flatten()).eval().to(DEVICE)
    net = models.efficientnet_b0(weights=models.EfficientNet_B0_Weights.IMAGENET1K_V1)
    return torch.nn.Sequential(net.features, net.avgpool, torch.nn.Flatten()).eval().to(DEVICE)


@torch.no_grad()
def features(net, images) -> np.ndarray:
    """[images, 3 views, feature size]"""
    result = []
    for path, _ in images:
        image = Image.open(path).convert("RGB")
        result.append(net(torch.stack(views(image)).to(DEVICE)).cpu().numpy())
    return np.stack(result)


def train_linear(x: np.ndarray, y: np.ndarray, epochs: int = 300) -> tuple:
    """Logistic regression on per-view features (each view is a sample), balanced classes, L2."""
    mean, std = x.reshape(-1, x.shape[-1]).mean(0), x.reshape(-1, x.shape[-1]).std(0) + 1e-6
    samples = torch.tensor(((x - mean) / std).reshape(-1, x.shape[-1]), dtype=torch.float32)
    labels = torch.tensor(np.repeat(y, x.shape[1]), dtype=torch.float32)
    layer = torch.nn.Linear(samples.shape[1], 1)
    optimiser = torch.optim.AdamW(layer.parameters(), lr=1e-2, weight_decay=1e-2)
    art_share = float(labels.mean())
    weights = torch.where(labels > 0.5, 0.5 / art_share, 0.5 / (1 - art_share))
    for _ in range(epochs):
        optimiser.zero_grad()
        loss = (torch.nn.functional.binary_cross_entropy_with_logits(layer(samples)[:, 0], labels, reduction="none")
                * weights).mean()
        loss.backward()
        optimiser.step()
    return layer, mean, std


def predict(model, x: np.ndarray) -> np.ndarray:
    layer, mean, std = model
    with torch.no_grad():
        logits = layer(torch.tensor((x - mean) / std, dtype=torch.float32))[..., 0]
    return torch.sigmoid(logits).mean(dim=1).numpy()  # average over views


def rates(probabilities, labels, threshold):
    art, photo = probabilities[labels == ART], probabilities[labels == PHOTO]
    return int((art >= threshold).sum()), len(art), int((photo >= threshold).sum()), len(photo)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    train, test = training_images(), test_images()
    y_train = np.array([label for _, label in train])
    y_test = np.array([label for _, label in test])
    face_images = {row["image"] for row in csv.DictReader((OUT / "faces.csv").open())}
    has_face = np.array([path.name in face_images for path, _ in test])
    print(f"train: {int(y_train.sum())} art, {int((1 - y_train).sum())} photo; test: {int(y_test.sum())} art, "
          f"{int((1 - y_test).sum())} photo ({int(has_face.sum())} with faces)", flush=True)
    for name in sys.argv[1:] or ["mobilenet_v3_large", "efficientnet_b0"]:
        net = backbone(name)
        x_train, x_test = features(net, train), features(net, test)
        order = list(range(len(train)))
        random.Random(0).shuffle(order)
        folds = [order[i::5] for i in range(5)]
        cross = np.zeros(len(train))
        for fold in folds:
            keep = np.setdiff1d(order, fold)
            cross[fold] = predict(train_linear(x_train[keep], y_train[keep]), x_train[fold])
        model = train_linear(x_train, y_train)
        tested = predict(model, x_test)
        # Threshold from cross-validation only: the lowest that wrongly skips at most 1 % of training photos.
        photo_scores = np.sort(cross[y_train == PHOTO])
        threshold = float(photo_scores[int(np.ceil(0.99 * len(photo_scores))) - 1]) + 1e-6
        a, na, p, np_ = rates(cross, y_train, threshold)
        print(f"{name}: threshold {threshold:.3f}; cross-validation art caught {a}/{na}, photos skipped {p}/{np_}")
        a, na, p, np_ = rates(tested, y_test, threshold)
        print(f"  test, all images: art caught {a}/{na}, photos skipped {p}/{np_}")
        a, na, p, np_ = rates(tested[has_face], y_test[has_face], threshold)
        print(f"  test, images with faces: art caught {a}/{na}, photos skipped {p}/{np_}", flush=True)
        with (OUT / f"test-scores-{name}.csv").open("w", newline="") as handle:
            csv.writer(handle).writerows([[path.relative_to(HERE.parent), label, f"{score:.4f}"]
                                          for (path, label), score in zip(test, tested)])
        torch.save({"backbone": name, "weight": model[0].weight.data, "bias": model[0].bias.data,
                    "mean": torch.tensor(model[1]), "std": torch.tensor(model[2]), "threshold": threshold},
                   OUT / f"classifier-{name}.pt")


if __name__ == "__main__":
    main()
