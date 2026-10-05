#!/bin/bash
# Installs the debug APK on the review emulator, runs VisionProbe on the boat, swan, lake and bar photos (U²-Netp raw
# saliency + display pixels for the reference comparison), and pulls the results. Run through scripts/heavy.
set -u; A=emulator-5554; P=com.lightlylabs.lightly; HERE=$(cd "$(dirname "$0")/.." && pwd); OUT=$HERE/work/u2netp-emulator
[ "${SKIP_INSTALL:-0}" = 1 ] || adb -s $A install -r "$HERE/../../android/app/build/outputs/apk/debug/app-debug.apk" | tail -1
adb -s $A shell run-as $P mkdir -p files/probe
for n in subject_boat subject_swan landscape_02 night_03; do
  adb -s $A push "$HERE/work/u2netp-eval/photos/$n.jpg" /data/local/tmp/$n.jpg >/dev/null
  adb -s $A shell run-as $P cp /data/local/tmp/$n.jpg files/probe/$n.jpg
  adb -s $A shell run-as $P cp /data/local/tmp/$n.jpg files/$n.jpg
done
adb -s $A shell am force-stop $P; adb -s $A logcat -c
adb -s $A shell am start -f 0x10008000 -n $P/.MainActivity --es lightly.debug.visionProbe /data/user/0/$P/files/probe >/dev/null
for i in $(seq 1 90); do sleep 2; adb -s $A logcat -d | grep "LightlyVisionProbe" | grep -q "done " && break; done
adb -s $A logcat -d | grep "LightlyVisionProbe" | grep -v adbd | tail -6 | cut -c1-200
for f in $(adb -s $A shell run-as $P ls files/probe | tr -d '\r' | grep -E "json|f32|png"); do adb -s $A exec-out run-as $P cat files/probe/$f > "$OUT/$f"; done
ls "$OUT"
