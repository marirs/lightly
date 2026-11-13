"""Enhance step 1f, round 2: fine-tuned MobileNetV3-Large photo-or-art classifier.

Round 1 (train_art_classifier.py, frozen features + linear layer) caught 68 of 81 test artworks with faces and skipped
2 of 43 photos, missing smooth oil portraits. Here the whole network is fine-tuned, and both classes are randomly turned
grey or sepia so colour cannot stand in for "painting" (most paintings are colour, most old photos are not). Training
crops come from the image at 256-560 px on its short side, so brushwork, paper and grain stay visible.

Validation: a fixed 20 % of art-train picks the epoch and the threshold (at most 1 % of validation photos skipped).
Test: the same held-out set as round 1, scored once; five views (whole image + four 224 crops at 448 px) averaged.
Run: .venv/bin/python -I finetune_art_classifier.py
"""
import csv
import random
import sys
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageOps
from torchvision import models, transforms

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from train_art_classifier import ART, PHOTO, NORMALISE, test_images, training_images  # noqa: E402

OUT = HERE / "outputs" / "art"
DEVICE = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
EPOCHS = 10


def tone(image: Image.Image, rng: random.Random) -> Image.Image:
    """Grey or sepia for half the samples of either class."""
    choice = rng.random()
    if choice < 0.25:
        return ImageOps.grayscale(image).convert("RGB")
    if choice < 0.5:
        grey = ImageOps.grayscale(image)
        return ImageOps.colorize(grey, black=(30, 20, 10), white=(255, 240, 210))
    return image


class TrainingSet(torch.utils.data.Dataset):
    def __init__(self, items, seed):
        self.items, self.rng = items, random.Random(seed)
        self.jitter = transforms.ColorJitter(0.2, 0.2, 0.1)

    def __len__(self):
        return len(self.items)

    def __getitem__(self, index):
        path, label = self.items[index]
        image = Image.open(path).convert("RGB")
        image = transforms.functional.resize(image, self.rng.randint(256, 560))
        if self.rng.random() < 0.3:  # sometimes the whole picture, not only a detail
            image = transforms.functional.resize(image, [224, 224])
        image = transforms.RandomCrop(224, pad_if_needed=True)(image)
        if self.rng.random() < 0.5:
            image = ImageOps.mirror(image)
        image = tone(self.jitter(image), self.rng)
        return NORMALISE(transforms.functional.to_tensor(image)), torch.tensor(label, dtype=torch.float32)


def five_views(image: Image.Image):
    whole = transforms.functional.resize(image, [224, 224])
    large = transforms.functional.resize(image, 448)
    w, h = large.size
    crops = [large.crop((x, y, x + 224, y + 224)) for x, y in
             (((w - 224) // 2, (h - 224) // 2), ((w - 224) // 2, round(h * 0.15)),
              (max(0, round(w * 0.2)), (h - 224) // 2), (max(0, round(w * 0.8) - 224), (h - 224) // 2))]
    return torch.stack([NORMALISE(transforms.functional.to_tensor(v.resize((224, 224)))) for v in [whole] + crops])


@torch.no_grad()
def score(net, items) -> np.ndarray:
    net.eval()
    return np.array([float(torch.sigmoid(net(five_views(Image.open(p).convert("RGB")).to(DEVICE))[:, 0]).mean())
                     for p, _ in items])


def build():
    net = models.mobilenet_v3_large(weights=models.MobileNet_V3_Large_Weights.IMAGENET1K_V2)
    net.classifier[-1] = torch.nn.Linear(net.classifier[-1].in_features, 1)
    return net.to(DEVICE)


def threshold_for(scores, labels):
    photos = np.sort(scores[labels == PHOTO])
    return float(photos[int(np.ceil(0.99 * len(photos))) - 1]) + 1e-6


def report(title, scores, labels, threshold):
    art, photo = scores[labels == ART], scores[labels == PHOTO]
    print(f"  {title}: art caught {(art >= threshold).sum()}/{len(art)}, photos skipped {(photo >= threshold).sum()}/{len(photo)}",
          flush=True)


def main() -> None:
    items = training_images()
    random.Random(0).shuffle(items)
    validation, train = items[: len(items) // 5], items[len(items) // 5:]
    y_val = np.array([label for _, label in validation])
    net = build()
    loader = torch.utils.data.DataLoader(TrainingSet(train, 1), batch_size=32, shuffle=True, num_workers=0)
    optimiser = torch.optim.AdamW([{"params": net.features.parameters(), "lr": 2e-4},
                                   {"params": net.classifier.parameters(), "lr": 1e-3}], weight_decay=1e-2)
    art_share = float(np.mean([label for _, label in train]))
    best = (-1.0, None, None)
    for epoch in range(EPOCHS):
        net.train()
        for images, labels in loader:
            images, labels = images.to(DEVICE), labels.to(DEVICE)
            weights = torch.where(labels > 0.5, 0.5 / art_share, 0.5 / (1 - art_share))
            loss = (torch.nn.functional.binary_cross_entropy_with_logits(net(images)[:, 0], labels, reduction="none")
                    * weights).mean()
            optimiser.zero_grad()
            loss.backward()
            optimiser.step()
        val_scores = score(net, validation)
        threshold = threshold_for(val_scores, y_val)
        caught = float((val_scores[y_val == ART] >= threshold).mean())
        print(f"epoch {epoch}: validation art caught {caught:.3f} at <=1 % photos skipped", flush=True)
        if caught > best[0]:
            best = (caught, {k: v.detach().clone() for k, v in net.state_dict().items()}, threshold)
    net.load_state_dict(best[1])
    threshold = best[2]
    test = test_images()
    y_test = np.array([label for _, label in test])
    faces = {row["image"] for row in csv.DictReader((OUT / "faces.csv").open())}
    has_face = np.array([p.name in faces for p, _ in test])
    test_scores = score(net, test)
    print(f"best validation art caught {best[0]:.3f}; threshold {threshold:.3f}")
    report("test, all images", test_scores, y_test, threshold)
    report("test, images with faces", test_scores[has_face], y_test[has_face], threshold)
    with (OUT / "test-scores-finetuned.csv").open("w", newline="") as handle:
        csv.writer(handle).writerows([[p.relative_to(HERE.parent), label, f"{s:.4f}"] for (p, label), s in zip(test, test_scores)])
    torch.save({"state_dict": best[1], "threshold": threshold}, OUT / "classifier-finetuned.pt")


if __name__ == "__main__":
    main()
