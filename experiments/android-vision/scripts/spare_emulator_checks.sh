#!/bin/bash
# Checks on the SPARE emulator (Pixel_9_Pro AVD, port 5556; the review emulator runs Pixel_10_Pro), never the review emulator: boots it headless, installs
# the given APK, runs bg-switch-flow (Choose another photo during separation) and the bar photo's Portrait panel,
# then shuts it down. Run through scripts/heavy.
set -u; APK=$1; A=emulator-5556; P=com.lightlylabs.lightly; HERE=$(cd "$(dirname "$0")/.." && pwd); OUT=$HERE/work/spare-checks; mkdir -p "$OUT"
EMU=~/Library/Android/sdk/emulator/emulator
$EMU -avd Pixel_9_Pro -port 5556 -no-window -no-snapshot-save -no-boot-anim -gpu swiftshader_indirect > "$OUT/emulator.log" 2>&1 &
for i in $(seq 1 150); do [ "$(adb -s $A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; sleep 2; done
echo "booted after ~$((i*2)) s"; adb -s $A shell settings put global window_animation_scale 0; adb -s $A shell settings put global hide_error_dialogs 1; adb -s $A shell input keyevent 82
adb -s $A install -r "$APK" | tail -1
adb -s $A shell run-as $P mkdir -p files
for n in subject_boat subject_swan night_03; do adb -s $A push "$HERE/work/u2netp-eval/photos/$n.jpg" /data/local/tmp/$n.jpg >/dev/null; adb -s $A shell run-as $P cp /data/local/tmp/$n.jpg files/$n.jpg; done
run() { adb -s $A shell am force-stop $P; adb -s $A logcat -c
  adb -s $A shell am start -f 0x10008000 -n $P/.MainActivity --es lightly.debug.photo /data/user/0/$P/files/$1 --es lightly.debug.editor $2 >/dev/null
  sleep $3; echo "== $2 ($1)"; adb -s $A logcat -d | grep -E "LightlyFlow|FATAL|AndroidRuntime" | grep -v adbd | cut -c33-360; adb -s $A exec-out screencap -p > "$OUT/$2.png"; }
if [ "${MODE:-flows}" = objects ]; then
  # Object cut-out Save copy (bg-object-flow), pulling the saved JPEG of each run.
  for n in subject_boat subject_swan; do
    before=$(adb -s $A shell 'ls /sdcard/Pictures/Lightly/ 2>/dev/null' | tr -d '\r' | sort)
    run $n.jpg bg-object-flow 120
    new=$(comm -13 <(echo "$before") <(adb -s $A shell 'ls /sdcard/Pictures/Lightly/ 2>/dev/null' | tr -d '\r' | sort) | head -1)
    [ -n "$new" ] && adb -s $A pull "/sdcard/Pictures/Lightly/$new" "$OUT/$n-saved.jpg" >/dev/null && echo "saved $n: $new"
  done
else
  run subject_boat.jpg bg-switch-flow 180
  run night_03.jpg pt-no-usable-face 40
fi
adb -s $A emu kill >/dev/null 2>&1; sleep 3; echo "spare emulator stopped"
