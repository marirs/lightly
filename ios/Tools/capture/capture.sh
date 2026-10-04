#!/bin/bash
# capture.sh MODE UDID DEVICE ORIENTATION THEME TEXT ONLY OUTDIR
#   MODE  session (runner v5, one launch for the list) or launch (one launch per screen; kept only
#         to validate the runner)
#   ONLY  comma-separated screen ids (EditorCaptureUITests.screens)
# One capture batch from the recorded UI-test build (test-without-building). Counts app launches
# from XCTest's activity log ("Launch <bundle id>") and writes a JSON record per PNG with the
# build's revision and fingerprint, the cell, the tool version and the labels a reviewer needs
# (subjectMatte, faceQuality, removeModel).
# Run inside the lock, one cell per acquisition; keep a launch to about 18 heavy screens or fewer
# (the Simulator render server stalls beyond that; cellall.sh splits a cell into launches).
set -u
source "$(dirname "$0")/env.sh"
MODE=$1; U=$2; DEV=$3; OR=$4; TH=$5; TX=$6; ONLY=$7; OUT=$8
if [ ! -f "$LIGHTLY_DD_UI/BUILD_RECORD" ]; then echo "no BUILD_RECORD in $LIGHTLY_DD_UI: run build.sh ui first" >&2; exit 1; fi
# The capture is of the built products, so it records the build's revision and fingerprint (the
# working folder may have moved on since the build).
read -r REV FP < "$LIGHTLY_DD_UI/BUILD_RECORD"
echo "capture of build $REV $FP (working folder now: $(bash "$CAPTURE_TOOLS_DIR/fingerprint.sh"))"
cd "$LIGHTLY_REPO/ios" || exit 1
mkdir -p "${OUT:?}"
find "${OUT:?}" -maxdepth 1 \( -name '*.png' -o -name '*.json' -o -name '*-timing.log' \) -delete
xcrun simctl boot "$U" 2>/dev/null; xcrun simctl bootstatus "$U" -b >/dev/null
xcrun simctl ui "$U" appearance "$TH"
if [ "$TX" = large ]; then xcrun simctl ui "$U" content_size extra-extra-large; else xcrun simctl ui "$U" content_size large; fi
xcrun simctl status_bar "$U" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
LOG=$OUT/xcodebuild.log
TEST_RUNNER_LIGHTLY_CAPTURE_DIR="$OUT" TEST_RUNNER_LIGHTLY_CAPTURE_ORIENTATION=$OR TEST_RUNNER_LIGHTLY_CAPTURE_ONLY="$ONLY" TEST_RUNNER_LIGHTLY_CAPTURE_MODE=$MODE \
xcodebuild test-without-building -project Lightly.xcodeproj -scheme LightlyUITests -destination "platform=iOS Simulator,id=$U" \
  -derivedDataPath "$LIGHTLY_DD_UI" -only-testing:LightlyUITests/EditorCaptureUITests > "$LOG" 2>&1
grep -E "error:|\*\* TEST" "$LOG" | cut -c1-300 | head -20
echo "LAUNCHES $MODE $(grep -cE 't = .*Launch com\.' "$LOG")"
# Background screens in the Simulator use subject mattes Vision computed on macOS (DEBUG only).
face_quality() {
  case "$1" in pt-*|bg-*) echo "ignored in the Simulator (10317d5); device threshold pending verification";; *) echo "not used";; esac
}
matte_source() {
  case "$1" in bg-*) echo "macOS Vision fixture (DEBUG Simulator only; device verification pending)";; *) echo "not used";; esac
}
remove_model() {
  case "$1" in
    ed-remove) echo "LaMa big-lama Core ML fp16, Simulator (DEBUG build; release gate pending legal sign-off (training data: Places2))";;
    ed-removing|ed-remove-failed) echo "held state (no model output shown)";;
    *) echo "not used";;
  esac
}
for f in "$OUT"/*.png; do
  [ -e "$f" ] || continue
  s=$(basename "$f" .png)
  if [ "$OR" = landscape ]; then
    w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}'); h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/{print $2}')
    [ "$w" -lt "$h" ] && sips -r 270 "$f" >/dev/null
  fi
  printf '{"screen":"%s","revision":"%s","localChanges":"%s","device":"%s","orientation":"%s","theme":"%s","text":"%s","mode":"%s","tool":"%s","subjectMatte":"%s","faceQuality":"%s","removeModel":"%s","png_sha256":"%s"}\n' \
    "$s" "$REV" "$FP" "$DEV" "$OR" "$TH" "$TX" "$MODE" "$LIGHTLY_CAPTURE_TOOL" \
    "$(matte_source "$s")" "$(face_quality "$s")" "$(remove_model "$s")" \
    "$(shasum -a 256 "$f" | cut -c1-64)" > "$OUT/$s.json"
done
xcrun simctl status_bar "$U" clear; xcrun simctl ui "$U" content_size large; xcrun simctl ui "$U" appearance light
echo "CAPTURE DONE $MODE $(find "$OUT" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ') png"
