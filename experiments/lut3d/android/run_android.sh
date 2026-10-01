#!/usr/bin/env bash
# Build, install and run the LUTBench feasibility harness on one device, then pull results.
#
#   ./run_android.sh <adb-serial>
#
# Env knobs:
#   SKIP_BUILD=1     reuse the existing APK
#   SKIP_PUSH=1      skip pushing models/golden/photos (adb push --sync already skips unchanged files)
#   SKIP_DIAG=1      skip the second launch that captures ORT verbose (NNAPI partitioning) logcat
#   TIMEOUT_S=3600   max seconds to wait for the run to finish
#
# Build: release variant (non-debuggable, so ART runs AOT/JIT-optimised code without debug
# hooks) signed with the debug key so no release keystore is needed.
set -euo pipefail

SERIAL="${1:?usage: run_android.sh <adb-serial>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LUT_ROOT="$(cd "$HERE/.." && pwd)"
PROJECT="$HERE/LUTBench"
PKG=com.lightlylabs.lutbench
DEVICE_FILES="/sdcard/Android/data/$PKG/files"
TIMEOUT_S="${TIMEOUT_S:-3600}"
ADB=(adb -s "$SERIAL")

if [[ -z "${JAVA_HOME:-}" && -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]]; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi

APK="$PROJECT/app/build/outputs/apk/release/app-release.apk"
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  [[ -f "$PROJECT/local.properties" ]] || echo "sdk.dir=$HOME/Library/Android/sdk" > "$PROJECT/local.properties"
  (cd "$PROJECT" && ./gradlew assembleRelease -q)
fi
[[ -f "$APK" ]] || { echo "APK missing: $APK" >&2; exit 1; }

MODEL_SLUG="$("${ADB[@]}" shell getprop ro.product.model | tr -d '\r' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g')"
OUT="$LUT_ROOT/results/android/$MODEL_SLUG"
mkdir -p "$OUT"
echo "device $SERIAL -> $OUT"

# Install (uninstall only our own package if the signature changed).
if ! "${ADB[@]}" install -r "$APK"; then
  "${ADB[@]}" uninstall "$PKG" || true
  "${ADB[@]}" install "$APK"
fi
"${ADB[@]}" shell am force-stop "$PKG"

# Wake the display (a key event, not a settings change) and record lock state.
"${ADB[@]}" shell input keyevent KEYCODE_WAKEUP || true
{
  echo "date: $(date -u +%FT%TZ)"
  echo "serial: $SERIAL"
  "${ADB[@]}" shell dumpsys window 2>/dev/null | grep -E "mDreamingLockscreen|isKeyguardShowing|mShowingLockscreen|KeyguardShowing" | head -5 || true
  "${ADB[@]}" shell dumpsys power 2>/dev/null | grep -E "mWakefulness=|Display Power: state" | head -3 || true
} > "$OUT/run_env.txt"

# Launch once without run_bench so Android creates the app-owned external files dir.
"${ADB[@]}" shell am start -W -n "$PKG/.MainActivity" >/dev/null
sleep 2
"${ADB[@]}" shell am force-stop "$PKG"
"${ADB[@]}" shell mkdir -p "$DEVICE_FILES/models" "$DEVICE_FILES/golden" "$DEVICE_FILES/photos"

if [[ "${SKIP_PUSH:-0}" != "1" ]]; then
  "${ADB[@]}" push --sync "$LUT_ROOT/models/ia3dlut_classifier.onnx" "$LUT_ROOT/models/ia3dlut_basis_luts_f32.bin" "$DEVICE_FILES/models/"
  for dir in "$LUT_ROOT"/golden/*/; do
    stem="$(basename "$dir")"
    "${ADB[@]}" shell mkdir -p "$DEVICE_FILES/golden/$stem"
    "${ADB[@]}" push --sync "$dir"source.png "$dir"input256.f32 "$dir"fused_lut.f32 "$dir"reference.png "$dir"meta.json "$DEVICE_FILES/golden/$stem/" >/dev/null
  done
  shopt -s nullglob
  photos=("$LUT_ROOT"/photos/*.jpg "$LUT_ROOT"/photos/*.jpeg)
  if (( ${#photos[@]} )); then "${ADB[@]}" push --sync "${photos[@]}" "$DEVICE_FILES/photos/" >/dev/null; fi
  shopt -u nullglob
fi

"${ADB[@]}" shell rm -rf "$DEVICE_FILES/results"
"${ADB[@]}" logcat -c || true
"${ADB[@]}" shell am start -n "$PKG/.MainActivity" --ez run_bench true

start=$(date +%s)
status="timeout"
while (( $(date +%s) - start < TIMEOUT_S )); do
  sleep 10
  if "${ADB[@]}" shell test -f "$DEVICE_FILES/results/done"; then status="done"; break; fi
  if [[ -z "$("${ADB[@]}" shell pidof "$PKG" | tr -d '\r')" ]]; then status="process_died"; break; fi
  last="$("${ADB[@]}" shell tail -n 1 "$DEVICE_FILES/results/log.txt" 2>/dev/null | tr -d '\r' || true)"
  echo "[$(( $(date +%s) - start ))s] $last"
done
echo "run status: $status (elapsed $(( $(date +%s) - start ))s)" | tee -a "$OUT/run_env.txt"

rm -rf "$OUT/results"
"${ADB[@]}" pull "$DEVICE_FILES/results" "$OUT/" >/dev/null || echo "pull failed" | tee -a "$OUT/run_env.txt"
"${ADB[@]}" logcat -d -s LUTBench:V onnxruntime:V AndroidRuntime:E DEBUG:V libc:V > "$OUT/logcat_bench.txt" || true
"${ADB[@]}" shell am force-stop "$PKG"

if [[ "${SKIP_DIAG:-0}" != "1" ]]; then
  # Second process with ORT VERBOSE logging so NNAPI/XNNPACK node partitioning shows in logcat.
  "${ADB[@]}" logcat -c || true
  "${ADB[@]}" shell am start -n "$PKG/.MainActivity" --ez nnapi_diag true >/dev/null
  for _ in $(seq 1 60); do
    sleep 2
    "${ADB[@]}" shell test -f "$DEVICE_FILES/results/done_diag" && break
  done
  "${ADB[@]}" logcat -d > "$OUT/logcat_ort_verbose.txt" || true
  "${ADB[@]}" pull "$DEVICE_FILES/results/nnapi_diag.txt" "$OUT/" >/dev/null 2>&1 || true
  "${ADB[@]}" shell am force-stop "$PKG"
fi

echo "results in $OUT"
ls -la "$OUT" "$OUT/results" 2>/dev/null | head -60
