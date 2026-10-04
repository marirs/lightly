#!/usr/bin/env bash
# Install the VisionEval harness on ONE allow-listed dev phone, run every candidate in its own
# process, pull results, then uninstall the harness.
#
#   scripts/run_device.sh <adb-serial>
#
# Safety rails (deliberate, do not relax):
#  - only the two dev phones below are accepted (personal phones must never be used);
#  - the APK's package is checked to be com.lightlylabs.visioneval before install, so this script
#    can never install over / replace the Lightly app (com.lightlylabs.lightly);
#  - every adb call carries an explicit -s <serial>.
# Env: SKIP_BUILD=1 reuse APK; KEEP_APP=1 skip the final uninstall; ONLY="id1 id2" subset;
#      WARM_RUNS=3; TIMEOUT_S=900 per candidate.
set -euo pipefail

SERIAL="${1:?usage: run_device.sh <adb-serial>}"
ALLOWED_SERIALS=("002843623001047" "ZY22MQNLBJ")
[[ " ${ALLOWED_SERIALS[*]} " == *" $SERIAL "* ]] || { echo "refusing: $SERIAL is not an allow-listed dev phone" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$HERE/VisionEval"
PKG=com.lightlylabs.visioneval
DEVICE_RESULTS="/sdcard/Android/data/$PKG/files/results"
TIMEOUT_S="${TIMEOUT_S:-900}"
WARM_RUNS="${WARM_RUNS:-3}"
ADB=(adb -s "$SERIAL")
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"

APK="$PROJECT/app/build/outputs/apk/all/release/app-all-release.apk"
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  [[ -f "$PROJECT/local.properties" ]] || echo "sdk.dir=$HOME/Library/Android/sdk" > "$PROJECT/local.properties"
  (cd "$PROJECT" && ./gradlew -q assembleAllRelease)
fi
AAPT="$(ls -d "$HOME"/Library/Android/sdk/build-tools/*/ | sort -V | tail -1)aapt2"
APK_PKG="$("$AAPT" dump packagename "$APK" | tr -d '\r')"
[[ "$APK_PKG" == "$PKG" ]] || { echo "refusing: APK package is '$APK_PKG', expected $PKG" >&2; exit 2; }

MODEL_SLUG="$("${ADB[@]}" shell getprop ro.product.model | tr -d '\r' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g')"
OUT="$HERE/results/$MODEL_SLUG"
rm -rf "$OUT" && mkdir -p "$OUT"
echo "device $SERIAL ($MODEL_SLUG) -> $OUT"

{
  echo "date: $(date -u +%FT%TZ)"
  echo "serial: $SERIAL"
  echo "model: $("${ADB[@]}" shell getprop ro.product.model | tr -d '\r')"
  echo "android: $("${ADB[@]}" shell getprop ro.build.version.release | tr -d '\r') (sdk $("${ADB[@]}" shell getprop ro.build.version.sdk | tr -d '\r'))"
  echo "soc: $("${ADB[@]}" shell getprop ro.soc.manufacturer | tr -d '\r') $("${ADB[@]}" shell getprop ro.soc.model | tr -d '\r')"
  echo "gms: $("${ADB[@]}" shell dumpsys package com.google.android.gms | grep -m1 versionName | tr -d '\r ')"
  echo "apk_bytes: $(stat -f %z "$APK")"
} > "$OUT/run_env.txt"

"${ADB[@]}" install -r "$APK"
"${ADB[@]}" shell dumpsys package "$PKG" | grep -E "android.permission\.(INTERNET|ACCESS_NETWORK_STATE)" > "$OUT/granted_network_permissions.txt" || echo "none" > "$OUT/granted_network_permissions.txt"
"${ADB[@]}" shell input keyevent KEYCODE_WAKEUP || true

"${ADB[@]}" shell am force-stop "$PKG"
"${ADB[@]}" shell rm -rf "$DEVICE_RESULTS"
"${ADB[@]}" shell am start -W -n "$PKG/.MainActivity" --ez list true >/dev/null
sleep 2
"${ADB[@]}" pull "$DEVICE_RESULTS/candidates.txt" "$OUT/" >/dev/null
CANDIDATES="${ONLY:-$(tr -d '\r' < "$OUT/candidates.txt")}"

"${ADB[@]}" logcat -c || true
for candidate in $CANDIDATES; do
  "${ADB[@]}" shell am force-stop "$PKG"
  sleep 2 # let the previous process die so the next one is a cold start
  "${ADB[@]}" shell am start -n "$PKG/.MainActivity" --es candidate "$candidate" --ei warm_runs "$WARM_RUNS" >/dev/null
  start=$(date +%s); status=timeout
  while (( $(date +%s) - start < TIMEOUT_S )); do
    sleep 3
    if "${ADB[@]}" shell test -f "$DEVICE_RESULTS/$candidate/done"; then status=done; break; fi
    if [[ -z "$("${ADB[@]}" shell pidof "$PKG" | tr -d '\r')" ]]; then status=process_died; break; fi
  done
  echo "$candidate: $status ($(( $(date +%s) - start ))s)" | tee -a "$OUT/run_env.txt"
done
"${ADB[@]}" shell am force-stop "$PKG"
"${ADB[@]}" pull "$DEVICE_RESULTS/." "$OUT/" >/dev/null
"${ADB[@]}" logcat -d -s VisionEval:V AndroidRuntime:E tflite:V MediaPipe:V native:V > "$OUT/logcat.txt" || true

if [[ "${KEEP_APP:-0}" != "1" ]]; then
  "${ADB[@]}" uninstall "$PKG"
  echo "uninstalled $PKG: $("${ADB[@]}" shell pm list packages "$PKG" | tr -d '\r' | grep -c "$PKG" || true) remaining" | tee -a "$OUT/run_env.txt"
fi
echo "results in $OUT"
