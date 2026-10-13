#!/bin/sh
# Compiles and copies the two Portrait › Sunglasses models into the app bundle (rendering-v2 §7.5):
#   face_landmarks_256_fp16     MediaPipe face landmarker (face_landmarks_detector from face_landmarker.task,
#                               sha256 c7d54204…43d5), 478 points with irises, face-presence logit
#   selfie_multiclass_256_fp16  MediaPipe selfie multiclass segmenter (selfie_multiclass_256x256.tflite,
#                               sha256 c6748b12…, experiments/android-vision/models/MODELS.csv): hair, background,
#                               accessories (glasses)
# Both Apache-2.0 (MediaPipe model cards). Converted by experiments/sunglasses/convert_coreml.py (TFLite rebuilt op for
# op in PyTorch, coremltools 8.3, mlprogram, iOS 17, fp16); checked against LiteRT on the 18 test faces: landmarks
# within 0.37 px of 256, segmentation classes agree on 99.75 % of pixels.
#
# The packages are git-ignored like the Remove model. They are looked up in $LIGHTLY_SUNGLASSES_MODEL_DIR, then this
# checkout's experiments/sunglasses/models/exported. Weights that do not match the recorded SHA-256 fail the build;
# missing packages only warn: Portrait › Sunglasses then shows its "eyes not visible" state for every face.
set -eu

: "${LIGHTLY_REPO_ROOT:?set in ios/project.yml}"
: "${BUILT_PRODUCTS_DIR:?run from Xcode}"
: "${LIGHTLY_APP_WRAPPER_NAME:?set by the LookPack target}"

destination="${BUILT_PRODUCTS_DIR}/${LIGHTLY_APP_WRAPPER_NAME}"

bundle_one() {
    name=$1
    expected=$2
    rm -rf "${destination:?}/${name}.mlmodelc"
    package=""
    for candidate in "${LIGHTLY_SUNGLASSES_MODEL_DIR:-}" "${LIGHTLY_REPO_ROOT}/experiments/sunglasses/models/exported"; do
        if [ -n "$candidate" ] && [ -d "${candidate}/${name}.mlpackage" ]; then
            package="${candidate}/${name}.mlpackage"
            break
        fi
    done
    if [ -z "$package" ]; then
        echo "warning: ${name}.mlpackage not found (set LIGHTLY_SUNGLASSES_MODEL_DIR). Sunglasses will show its unavailable state."
        return 0
    fi
    actual=$(shasum -a 256 "${package}/Data/com.apple.CoreML/weights/weight.bin" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "error: ${package} weights sha256 ${actual} is not the recorded ${expected}."
        exit 1
    fi
    mkdir -p "$destination"
    xcrun coremlcompiler compile "$package" "$destination" >/dev/null
    if [ ! -s "${destination}/${name}.mlmodelc/coremldata.bin" ]; then
        echo "error: the bundled ${name}.mlmodelc is incomplete."
        exit 1
    fi
    echo "Bundled ${name}.mlmodelc (weights ${expected})"
}

bundle_one face_landmarks_256_fp16 6cf3955c2cfac2f8feebe1ed5aec50907c9b5595458a5cfb17d2371afbeb27dc
bundle_one selfie_multiclass_256_fp16 cf1cfc945194f5dcedc8bb4ed49f2917f0b3b8d82d7befd17dd658fabfb32a03
