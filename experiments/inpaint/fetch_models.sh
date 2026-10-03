#!/usr/bin/env bash
# Fetch the commercially usable inpainting candidates + the upstream inference code they need.
# Everything lands in git-ignored folders (models/, upstream/). Re-running verifies sha256s.
#
# Deliberately NOT fetched (licence/terms block commercial use; see docs/v1/remove-evaluation.md):
#   MAT (CC BY-NC 4.0), LaMa CelebA-HQ / Qualcomm "LaMa-Dilated" (CelebA-HQ checkpoint, CelebA is
#   non-commercial research only), MI-GAN FFHQ weights (FFHQ images are BY-NC-SA), anything
#   distilled from NVIDIA-licensed StyleGAN code with non-commercial terms.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MODELS="$HERE/models"
UPSTREAM="$HERE/upstream"
mkdir -p "$MODELS/migan_gdrive" "$UPSTREAM"

verify() {  # verify <file> <sha256>
  local actual
  actual="$(shasum -a 256 "$1" | cut -d' ' -f1)"
  if [[ "$actual" != "$2" ]]; then echo "sha256 mismatch for $1: $actual" >&2; exit 1; fi
  echo "ok  $1"
}

fetch() {  # fetch <url> <dest> <sha256>
  [[ -f "$2" ]] || curl -fL --retry 3 -o "$2" "$1"
  verify "$2" "$3"
}

# LaMa big-lama (Places2/Places-Challenge), Apache-2.0, HF mirror referenced by the official README.
fetch "https://huggingface.co/smartywu/big-lama/resolve/05cb2be7f8dbe6ca7c6e78f4fc827a4b2baaa4a9/big-lama.zip" \
      "$MODELS/big-lama.zip" f1b358ca24093b93a106183b98a3dea6e8ed09f3b43ea7251eb2c81e7b4575f6
[[ -f "$MODELS/big-lama/models/best.ckpt" ]] || (cd "$MODELS" && unzip -q -o big-lama.zip)
verify "$MODELS/big-lama/models/best.ckpt" fccb7adffd53ec0974ee5503c3731c2c2f1e7e07856fd9228cdcc0b46fd5d423

# MI-GAN 512 Places2, MIT (LICENSE-WEIGHTS, added upstream 2026-09-14). Official HF ONNX exports:
fetch "https://huggingface.co/andraniksargsyan/migan/resolve/406830d0fa60666da0071c342ad2fbc8f30c5c64/migan_pipeline_v2.onnx" \
      "$MODELS/migan_pipeline_v2.onnx" 6f1f3530a1a2324b19752018ce756088b07973cda8d7d890034ace5c8a48c40b
fetch "https://huggingface.co/andraniksargsyan/migan/resolve/406830d0fa60666da0071c342ad2fbc8f30c5c64/migan.onnx" \
      "$MODELS/migan.onnx" 593eba0b7e04730f1b61c0a3cbca68d97d8d6a7ff5c6a44a7b9d7fcd880fc5ae
# PyTorch state dicts (Google Drive folder linked from the README; needs `pip install gdown`).
# Only the Places2 files are kept; the FFHQ one is deleted because FFHQ is non-commercial.
if [[ ! -f "$MODELS/migan_gdrive/migan_512_places2.pt" ]]; then
  gdown --folder "https://drive.google.com/drive/folders/1xNtvN2lto0p5yFKOEEg9RioMjGrYM74w" -O "$MODELS/migan_gdrive"
  rm -rf "$MODELS/migan_gdrive/migan_256_ffhq.pt" "$MODELS/migan_gdrive/uncompressed_pkl_checkpoints"
fi
verify "$MODELS/migan_gdrive/migan_512_places2.pt" 1d6087eee0aac8923ad2606be5d8caeb4824d3e4de331995e420c74e124a466a
verify "$MODELS/migan_gdrive/migan_256_places2.pt" 8b82b2e82fc8e5a2e1f06827594aac1a5d66a9ca41e24199ddd969847788097f

# Inference code (pinned commits).
clone_at() {  # clone_at <url> <dir> <commit>
  [[ -d "$2/.git" ]] || git clone -q "$1" "$2"
  git -C "$2" fetch -q --depth 1 origin "$3" 2>/dev/null || true
  git -C "$2" checkout -q "$3"
  echo "ok  $2 @ $3"
}
clone_at https://github.com/advimman/lama.git "$UPSTREAM/lama" 786f5936b27fb3dacd2b1ad799e4de968ea697e7
clone_at https://github.com/Picsart-AI-Research/MI-GAN.git "$UPSTREAM/MI-GAN" 2b793c5ece43f4253e32d4afc257120a5deed6f5
