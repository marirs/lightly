"""Fetch the commercially usable monocular depth candidates into experiments/depth/models/.

Only models whose WEIGHTS licence permits commercial use are fetched. Every download is pinned to a
Hugging Face commit and its SHA-256 is written to models/MANIFEST.json (git-ignored) and printed so
it can be copied into docs/v1/depth-evaluation.md and MODEL_SOURCES.csv.

Deliberately NOT fetched (licence): Depth Anything V2 Base/Large (CC-BY-NC-4.0), Apple Depth Pro
(Apple ML Research Model licence, research only), Metric3D weights (no weights licence; authors ask
for commercial enquiries), Distill-Any-Depth (MIT, but distilled from a CC-BY-NC teacher).
"""
import hashlib
import json
import pathlib

import urllib.request

from huggingface_hub import hf_hub_download

MODELS_DIR = pathlib.Path(__file__).resolve().parent / "models"

# (local name, repo id, pinned commit, files, licence as declared on the model card)
CANDIDATES = [
    ("da2_small", "depth-anything/Depth-Anything-V2-Small-hf", "5426e4f0f36572d16453bbda7a8389317b1bef99",
     ["config.json", "model.safetensors", "preprocessor_config.json"], "apache-2.0"),
    ("da1_small", "LiheYoung/depth-anything-small-hf", "25216a913fa218ccb7d58cce818d52b728b6c1f6",
     ["config.json", "model.safetensors", "preprocessor_config.json"], "apache-2.0"),
    ("midas31_swin2_tiny", "Intel/dpt-swinv2-tiny-256", "f7f350e1a10a5ea58671b68ab5f49dc18ec00483",
     ["config.json", "model.safetensors", "preprocessor_config.json"], "mit"),
    ("apple_coreml_da2_small", "apple/coreml-depth-anything-v2-small", "cfef6f6f2a70783dedc0bfae40cecbc2052285d3",
     ["DepthAnythingV2SmallF16.mlpackage/Manifest.json",
      "DepthAnythingV2SmallF16.mlpackage/Data/com.apple.CoreML/model.mlmodel",
      "DepthAnythingV2SmallF16.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
      # 8-bit palettised and 8-bit linear-quantised weight variants (smaller app download).
      "DepthAnythingV2SmallF16P8.mlpackage/Manifest.json",
      "DepthAnythingV2SmallF16P8.mlpackage/Data/com.apple.CoreML/model.mlmodel",
      "DepthAnythingV2SmallF16P8.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
      "DepthAnythingV2SmallF16INT8.mlpackage/Manifest.json",
      "DepthAnythingV2SmallF16INT8.mlpackage/Data/com.apple.CoreML/model.mlmodel",
      "DepthAnythingV2SmallF16INT8.mlpackage/Data/com.apple.CoreML/weights/weight.bin"], "apache-2.0"),
]

# Direct release assets (not on the Hub): (local name, url, filename, licence)
RELEASE_ASSETS = [
    ("midas21_small", "https://github.com/isl-org/MiDaS/releases/download/v2_1/model-small.onnx",
     "model-small.onnx", "mit"),
]


def sha256_of(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    manifest = []
    for local_name, repo_id, revision, files, licence in CANDIDATES:
        for filename in files:
            local_path = pathlib.Path(hf_hub_download(repo_id, filename, revision=revision,
                                                      local_dir=MODELS_DIR / local_name))
            entry = {
                "name": local_name, "repo": repo_id, "revision": revision, "file": filename,
                "url": f"https://huggingface.co/{repo_id}/resolve/{revision}/{filename}",
                "licence": licence, "bytes": local_path.stat().st_size, "sha256": sha256_of(local_path),
            }
            manifest.append(entry)
            print(f"{local_name:24s} {filename:70s} {entry['bytes']:>11d} {entry['sha256']}")
    for local_name, url, filename, licence in RELEASE_ASSETS:
        local_path = MODELS_DIR / local_name / filename
        local_path.parent.mkdir(parents=True, exist_ok=True)
        if not local_path.exists():
            urllib.request.urlretrieve(url, local_path)
        entry = {"name": local_name, "repo": url.rsplit("/releases", 1)[0], "revision": "v2_1", "file": filename,
                 "url": url, "licence": licence, "bytes": local_path.stat().st_size, "sha256": sha256_of(local_path)}
        manifest.append(entry)
        print(f"{local_name:24s} {filename:70s} {entry['bytes']:>11d} {entry['sha256']}")
    (MODELS_DIR / "MANIFEST.json").write_text(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
