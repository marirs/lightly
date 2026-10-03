#!/bin/sh
# Compiles and copies the depth model for Background › Focus & Blur into the app bundle:
# Apple's Core ML packaging of Depth Anything V2 Small, 8-bit palettised
# (DepthAnythingV2SmallF16P8.mlpackage, Apache-2.0).
#
# Source and integrity (docs/v1/depth-evaluation.md, experiments/depth/MODEL_SOURCES.csv):
#   https://huggingface.co/apple/coreml-depth-anything-v2-small @ cfef6f6f2a70783dedc0bfae40cecbc2052285d3
#   Data/com.apple.CoreML/weights/weight.bin sha256 660a57cf7becfeac080a9bb02a263be59fd57b5c4d17ff8912833bc8b6edae04
# The package is git-ignored (24 MB); it is looked up in $LIGHTLY_DEPTH_MODEL_DIR, then this
# checkout's experiments/depth/models/apple_coreml_da2_small. A package whose weights do not match
# the recorded SHA-256 fails the build.
#
# RELEASE GATE — pending legal sign-off (training data). The weights are Apache-2.0, but the model
# was trained on pseudo-labels of datasets with research-only terms (depth-evaluation.md, T1).
# Release builds bundle it only when LIGHTLY_DEPTH_MODEL_TRAINING_DATA_SIGNED_OFF=YES. Debug builds
# always bundle it, for development. Without it, Focus & Blur on photos without embedded depth shows
# the approved "Couldn't separate the subject" state.
set -eu

: "${LIGHTLY_REPO_ROOT:?set in ios/project.yml}"
: "${BUILT_PRODUCTS_DIR:?run from Xcode}"
: "${LIGHTLY_APP_WRAPPER_NAME:?set by the LookPack target}"

name=DepthAnythingV2SmallF16P8
expected=660a57cf7becfeac080a9bb02a263be59fd57b5c4d17ff8912833bc8b6edae04
destination="${BUILT_PRODUCTS_DIR}/${LIGHTLY_APP_WRAPPER_NAME}"
rm -rf "${destination}/${name}.mlmodelc"

if [ "${CONFIGURATION:-Debug}" != "Debug" ] && [ "${LIGHTLY_DEPTH_MODEL_TRAINING_DATA_SIGNED_OFF:-NO}" != "YES" ]; then
    echo "warning: Depth model not bundled: release gate 'pending legal sign-off (training data)' is closed."
    exit 0
fi

package=""
for candidate in "${LIGHTLY_DEPTH_MODEL_DIR:-}" "${LIGHTLY_REPO_ROOT}/experiments/depth/models/apple_coreml_da2_small"; do
    if [ -n "$candidate" ] && [ -d "${candidate}/${name}.mlpackage" ]; then
        package="${candidate}/${name}.mlpackage"
        break
    fi
done
if [ -z "$package" ]; then
    echo "warning: ${name}.mlpackage not found (set LIGHTLY_DEPTH_MODEL_DIR). Focus & Blur will have no estimated depth."
    exit 0
fi

actual=$(shasum -a 256 "${package}/Data/com.apple.CoreML/weights/weight.bin" | awk '{print $1}')
if [ "$actual" != "$expected" ]; then
    echo "error: ${package} weights sha256 ${actual} is not the recorded ${expected}."
    exit 1
fi

mkdir -p "$destination"
xcrun coremlcompiler compile "$package" "$destination" >/dev/null
echo "Bundled ${name}.mlmodelc (weights ${expected})"
