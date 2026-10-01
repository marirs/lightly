#!/usr/bin/env bash
# Fetch the pinned upstream revision and verify the pretrained weights by SHA-256.
# Output: experiments/lut3d/reference/upstream/ (git-ignored).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$here/upstream"
rev="b491f6df64a588864739a157db271e5c848e1805"

if [ ! -d "$dest/.git" ]; then
  git clone --quiet https://github.com/HuiZeng/Image-Adaptive-3DLUT.git "$dest"
fi
git -C "$dest" checkout --quiet "$rev"

cd "$dest/pretrained_models"
shasum -a 256 -c - <<'SUMS'
bae9865395625ecae58cfe86147e521093bb1e29e7b2544e02adb238b8035021  sRGB/classifier.pth
c1bb2bc4b7239c1a7e96159f5923123ba796b1fceb0b8c3132b423ea825b821a  sRGB/LUTs.pth
c2b9b2a73ef63af9c14928e08c16baef75e2a5f644db976ae21f597874716525  sRGB/classifier_unpaired.pth
3bd87756b32b660672272a49244affc68b4985f7b24ff7c49186d50889665d5f  sRGB/LUTs_unpaired.pth
SUMS
echo "upstream @ $rev verified"
