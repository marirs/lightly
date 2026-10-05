#!/bin/bash
# build.sh [unit|ui|both]: build once per source revision (build-for-testing, never a clean build).
#   unit: the app with its unit tests (Debug, -Onone) into $LIGHTLY_DD_UNIT
#   ui:   the app with the UI tests, optimised (-O), into $LIGHTLY_DD_UI (what captures run)
# Each derived-data folder gets BUILD_RECORD = "<revision> <fingerprint>" of the source it was built
# from; capture.sh copies it into every capture's JSON record.
# Run it through the lock: scripts/heavy build-ios-<what> ios/Tools/capture/build.sh ui
set -u
source "$(dirname "$0")/env.sh"
what=${1:-both}
read -r REV FP < <(bash "$CAPTURE_TOOLS_DIR/fingerprint.sh")
# A snapshot has none of the git-ignored models: take them from the main checkout
# (LIGHTLY_MAIN_CHECKOUT) unless their directories are given explicitly.
if [ -f "$LIGHTLY_REPO/.lightly-source" ]; then
  : "${LIGHTLY_MAIN_CHECKOUT:?set LIGHTLY_MAIN_CHECKOUT to build a snapshot (models are git-ignored)}"
  export LIGHTLY_DEPTH_MODEL_DIR="${LIGHTLY_DEPTH_MODEL_DIR:-$LIGHTLY_MAIN_CHECKOUT/experiments/depth/models/apple_coreml_da2_small}"
  export LIGHTLY_REMOVE_MODEL_DIR="${LIGHTLY_REMOVE_MODEL_DIR:-$LIGHTLY_MAIN_CHECKOUT/experiments/inpaint/models/exported}"
  export LIGHTLY_LOOK_PACK_DIR="${LIGHTLY_LOOK_PACK_DIR:-$LIGHTLY_MAIN_CHECKOUT/shared/look-pack/out}"
fi
read -r MARKETING BUILD_NUMBER < <(bash "$LIGHTLY_REPO/scripts/version.sh")
VERSION_SETTINGS=(MARKETING_VERSION="$MARKETING" CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
cd "$LIGHTLY_REPO/ios" || exit 1
xcodegen generate 2>&1 | tail -1
status=0
if [ "$what" = unit ] || [ "$what" = both ]; then
  echo "== unit build $(date +%T) at $REV $FP"
  xcodebuild build-for-testing -project Lightly.xcodeproj -scheme Lightly -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$LIGHTLY_DD_UNIT" "${VERSION_SETTINGS[@]}" > "$LIGHTLY_DD_UNIT.log" 2>&1 || status=1
  grep -E "error:|\*\* " "$LIGHTLY_DD_UNIT.log" | sort -u | head -40
  [ $status -eq 0 ] && echo "$REV $FP" > "$LIGHTLY_DD_UNIT/BUILD_RECORD"
fi
if [ "$what" = ui ] || [ "$what" = both ]; then
  echo "== UI build $(date +%T) at $REV $FP"
  xcodebuild build-for-testing -project Lightly.xcodeproj -scheme LightlyUITests -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$LIGHTLY_DD_UI" SWIFT_OPTIMIZATION_LEVEL=-O "${VERSION_SETTINGS[@]}" > "$LIGHTLY_DD_UI.log" 2>&1 || status=1
  grep -E "error:|\*\* " "$LIGHTLY_DD_UI.log" | sort -u | head -30
  [ $status -eq 0 ] && echo "$REV $FP" > "$LIGHTLY_DD_UI/BUILD_RECORD"
fi
echo "BUILD DONE $(date +%T) status=$status"
exit $status
