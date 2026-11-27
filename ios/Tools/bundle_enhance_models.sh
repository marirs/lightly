#!/bin/sh
# Compiles and copies the five Enhance models (1.3) into the app bundle, each named enhance-<name>.mlmodelc:
#   art-classifier         paintings keep their faces (experiments/enhance-2026-11-12 step 1f, export_art_classifier.py)
#   face-detector-640/960  RetinaFace MobileNet-0.25 on 1024 / 1536 canvases (step 2b, export_face_detector.py);
#                          one network, two input shapes, so the weights are the same
#   general-x4v3-384       realesr-general-x4v3 on 384 px tiles (step 2e, convert_coreml.py general 384)
#   codeformer-w0.8-512    CodeFormer, fidelity 0.8 (step 1c, convert_coreml.py)
# Face Mesh and the selfie multiclass model are Sunglasses' own (bundle_sunglasses_models.sh); Enhance reuses them.
#
# The packages are git-ignored (about 200 MB). They are looked up in $LIGHTLY_ENHANCE_MODEL_DIR, then this checkout's
# experiments/enhance-2026-11-12/coreml. Weights that do not match the recorded SHA-256 fail the build; missing
# packages only warn (EnhanceEngine then throws .modelUnavailable).
#
# Release gate: Release builds bundle the models only with LIGHTLY_ENHANCE_MODELS_IN_RELEASE=YES (YES since 1.3.0,
# owner 2026-11-27); Debug builds always bundle them for development and the unit tests. A Release build with the gate
# on fails when a package is missing: without its models the app hides Enhance, which must never ship by accident.
set -eu

: "${LIGHTLY_REPO_ROOT:?set in ios/project.yml}"
: "${BUILT_PRODUCTS_DIR:?run from Xcode}"
: "${LIGHTLY_APP_WRAPPER_NAME:?set by the LookPack target}"

destination="${BUILT_PRODUCTS_DIR}/${LIGHTLY_APP_WRAPPER_NAME}"

bundle_one() {
    name=$1
    expected=$2
    bundled="enhance-${name}"
    rm -rf "${destination:?}/${bundled}.mlmodelc"
    if [ "${CONFIGURATION:-Debug}" != "Debug" ] && [ "${LIGHTLY_ENHANCE_MODELS_IN_RELEASE:-NO}" != "YES" ]; then
        return 0
    fi
    package=""
    for candidate in "${LIGHTLY_ENHANCE_MODEL_DIR:-}" "${LIGHTLY_REPO_ROOT}/experiments/enhance-2026-11-12/coreml"; do
        if [ -n "$candidate" ] && [ -d "${candidate}/${name}.mlpackage" ]; then
            package="${candidate}/${name}.mlpackage"
            break
        fi
    done
    if [ -z "$package" ]; then
        # A store build must carry Enhance: only Debug may go on without the models (the app then hides Enhance).
        if [ "${CONFIGURATION:-Debug}" != "Debug" ]; then
            echo "error: ${name}.mlpackage not found (set LIGHTLY_ENHANCE_MODEL_DIR): a ${CONFIGURATION} build must carry Enhance."
            exit 1
        fi
        echo "warning: ${name}.mlpackage not found (set LIGHTLY_ENHANCE_MODEL_DIR). Enhance will be unavailable."
        return 0
    fi
    actual=$(shasum -a 256 "${package}/Data/com.apple.CoreML/weights/weight.bin" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "error: ${package} weights sha256 ${actual} is not the recorded ${expected}."
        exit 1
    fi
    # CodeFormer takes a while to compile; reuse a compiled copy keyed by the weights and the name. The cache must hold
    # a whole compiled model (macOS's /tmp cleanup can leave empty folders behind; see bundle_remove_model.sh).
    cache="${TARGET_TEMP_DIR:-${TMPDIR:-/tmp}}/enhance-model-${name}-${expected}"
    compiled="${cache}/${name}.mlmodelc"
    if [ ! -s "${compiled}/coremldata.bin" ] || [ -z "$(find "${compiled}" -name 'weight.bin' -size +100k 2>/dev/null)" ]; then
        rm -rf "${cache:?}"
        mkdir -p "$cache"
        xcrun coremlcompiler compile "$package" "$cache" >/dev/null
    fi
    mkdir -p "$destination"
    cp -R "$compiled" "${destination}/${bundled}.mlmodelc"
    if [ ! -s "${destination}/${bundled}.mlmodelc/coremldata.bin" ]; then
        echo "error: the bundled ${bundled}.mlmodelc is incomplete."
        exit 1
    fi
    echo "Bundled ${bundled}.mlmodelc (weights ${expected})"
}

if [ "${CONFIGURATION:-Debug}" != "Debug" ] && [ "${LIGHTLY_ENHANCE_MODELS_IN_RELEASE:-NO}" != "YES" ]; then
    echo "note: Enhance models not bundled in ${CONFIGURATION} (LIGHTLY_ENHANCE_MODELS_IN_RELEASE is not YES)."
fi
bundle_one art-classifier a1e53672f4d8ea9aef2891927ce081454c6d92f6ba8cd5345fa1d72c2d33701f
bundle_one face-detector-640 bcf21202a4943e4a9f52d20564912eeb677213a927ebe946dc89c14d779b553c
bundle_one face-detector-960 bcf21202a4943e4a9f52d20564912eeb677213a927ebe946dc89c14d779b553c
bundle_one general-x4v3-384 7a6088b2ee537938f380b9049fae2b85dad57b251d047ab8f5afd256417838ec
bundle_one codeformer-w0.8-512 f78f9ad40fc25d58399b6c4d88249a203af04ced77347ea7106e92e5d99acb23
