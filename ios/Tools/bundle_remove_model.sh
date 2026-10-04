#!/bin/sh
# Compiles and copies the Edit › Remove model into the app bundle: LaMa big-lama (advimman/lama),
# converted to Core ML fp16 at a fixed 512 × 512 input (lama_512_fp16.mlpackage).
#
# Source, licence and integrity (docs/v1/remove-evaluation.md §2, experiments/inpaint/fetch_models.sh):
#   weights  https://huggingface.co/smartywu/big-lama/resolve/05cb2be7f8dbe6ca7c6e78f4fc827a4b2baaa4a9/big-lama.zip
#            (the mirror linked from the official README of https://github.com/advimman/lama @ 786f593)
#            big-lama.zip              sha256 f1b358ca24093b93a106183b98a3dea6e8ed09f3b43ea7251eb2c81e7b4575f6
#            big-lama/models/best.ckpt sha256 fccb7adffd53ec0974ee5503c3731c2c2f1e7e07856fd9228cdcc0b46fd5d423
#   licence  Apache-2.0 (code and weights)
#   convert  experiments/inpaint/convert.py (FFTs replaced by exact DFT matrix products; coremltools
#            8.3, mlprogram, iOS 17, fp16). Package digest, sha256 over its files in sorted path order:
#            787574a416b33050eb9940030f794c5afa41680d3fd0b0486897d48a1b4d6837
#            (Data/com.apple.CoreML/weights/weight.bin alone: 805bc8896aa0f2c9991fc1855226783eba6128e55cedc0c78199d0ff340d9f4b)
# The package is git-ignored (103 MB). It is looked up in $LIGHTLY_REMOVE_MODEL_DIR, then this
# checkout's experiments/inpaint/models/exported. A package whose weights do not match the
# recorded SHA-256 fails the build.
#
# RELEASE GATE — "pending legal sign-off (training data: Places2)". The weights are Apache-2.0,
# but Places2's image terms are non-commercial research only for whoever downloaded the images
# (remove-evaluation §8). Release builds bundle the model only when
# LIGHTLY_REMOVE_MODEL_TRAINING_DATA_SIGNED_OFF=YES; Debug builds always bundle it, for
# development. Without it, Remove stays listed and every stroke shows the approved
# "Couldn't remove that area." state; nothing else fills in.
set -eu

: "${LIGHTLY_REPO_ROOT:?set in ios/project.yml}"
: "${BUILT_PRODUCTS_DIR:?run from Xcode}"
: "${LIGHTLY_APP_WRAPPER_NAME:?set by the LookPack target}"

name=lama_512_fp16
expected=805bc8896aa0f2c9991fc1855226783eba6128e55cedc0c78199d0ff340d9f4b
destination="${BUILT_PRODUCTS_DIR}/${LIGHTLY_APP_WRAPPER_NAME}"
rm -rf "${destination:?}/${name}.mlmodelc"

if [ "${CONFIGURATION:-Debug}" != "Debug" ] && [ "${LIGHTLY_REMOVE_MODEL_TRAINING_DATA_SIGNED_OFF:-NO}" != "YES" ]; then
    echo "warning: Remove model not bundled: release gate 'pending legal sign-off (training data: Places2)' is closed."
    exit 0
fi

package=""
for candidate in "${LIGHTLY_REMOVE_MODEL_DIR:-}" "${LIGHTLY_REPO_ROOT}/experiments/inpaint/models/exported"; do
    if [ -n "$candidate" ] && [ -d "${candidate}/${name}.mlpackage" ]; then
        package="${candidate}/${name}.mlpackage"
        break
    fi
done
if [ -z "$package" ]; then
    echo "warning: ${name}.mlpackage not found (set LIGHTLY_REMOVE_MODEL_DIR). Remove will show its failure state."
    exit 0
fi

actual=$(shasum -a 256 "${package}/Data/com.apple.CoreML/weights/weight.bin" | awk '{print $1}')
if [ "$actual" != "$expected" ]; then
    echo "error: ${package} weights sha256 ${actual} is not the recorded ${expected}."
    exit 1
fi

mkdir -p "$destination"
# Compiling 103 MB takes a while; reuse the compiled copy when the weights have not changed.
cache="${TARGET_TEMP_DIR:-${TMPDIR:-/tmp}}/remove-model-${expected}"
if [ ! -d "${cache}/${name}.mlmodelc" ]; then
    mkdir -p "$cache"
    xcrun coremlcompiler compile "$package" "$cache" >/dev/null
fi
cp -R "${cache}/${name}.mlmodelc" "${destination}/"
echo "Bundled ${name}.mlmodelc (weights ${expected})"
