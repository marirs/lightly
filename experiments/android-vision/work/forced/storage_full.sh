#!/bin/bash
# storage_full.sh OUT APK PHOTO: spare emulator; opens a photo, then fills shared storage to ~20 MB free with a
# temporary file before the Develop-only Save copy (dev-stress-drag-save), dumps the screen's text, then deletes the temporary file.
set -u; O=$1; APK=$2; PHOTO=$3; A=emulator-5556; P=com.lightlylabs.lightly
~/Library/Android/sdk/emulator/emulator -avd Pixel_9_Pro -port 5556 -no-window -no-snapshot-save -no-boot-anim -gpu swiftshader_indirect > "$O/emulator.log" 2>&1 &
for i in $(seq 1 120); do [ "$(adb -s $A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; sleep 2; done
adb -s $A shell settings put global hide_error_dialogs 1; adb -s $A shell input keyevent 82; adb -s $A shell wm size reset
adb -s $A install -r "$APK" | tail -1
adb -s $A shell run-as $P mkdir -p files; adb -s $A push "$PHOTO" /data/local/tmp/big.jpg >/dev/null; adb -s $A shell run-as $P cp /data/local/tmp/big.jpg files/big.jpg
adb -s $A shell am force-stop $P; adb -s $A logcat -c
adb -s $A shell am start -f 0x10008000 -n $P/.MainActivity --es lightly.debug.photo /data/user/0/$P/files/big.jpg --es lightly.debug.editor dev-stress-drag-save >/dev/null
# Storage runs out after the photo is open and before Save copy (the scenario saves ~25 s after launch).
sleep 10
free_kb=$(adb -s $A shell df -k /data | tail -1 | awk '{print $4}' | tr -d '\r'); fill_kb=$((free_kb - ${LEAVE_KB:-20480}))
echo "free before: ${free_kb} KB; filling ${fill_kb} KB"
adb -s $A shell fallocate -l ${fill_kb}k /sdcard/Download/lightly-fill.bin
adb -s $A shell df -k /data | tail -1
sleep 10
for i in $(seq 1 30); do
  adb -s $A shell uiautomator dump /sdcard/Download/ui.xml >/dev/null 2>&1; adb -s $A pull /sdcard/Download/ui.xml "$O/ui.xml" >/dev/null 2>&1
  t=$(grep -o 'text="[^"]*"' "$O/ui.xml" | tr '\n' ' '); echo "$((40 + i * 10))s: $t" >> "$O/timeline.txt"
  if echo "$t" | grep -q "Saving a copy"; then seen=1; elif [ "${seen:-0}" = 1 ]; then break; fi
  sleep 10
done
adb -s $A logcat -d -v threadtime > "$O/logcat.txt"
adb -s $A shell rm -f /sdcard/Download/lightly-fill.bin /sdcard/Download/ui.xml
adb -s $A shell df -k /data | tail -1
adb -s $A emu kill >/dev/null 2>&1; sleep 2
