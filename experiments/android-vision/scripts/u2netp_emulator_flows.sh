#!/bin/bash
# App flows with the real models on the review emulator (debug build): each case launches the editor on a photo with a
# debug scenario, waits, takes one screenshot, and pulls a new saved copy when the case saves. Run through scripts/heavy.
set -u; A=emulator-5554; P=com.lightlylabs.lightly; HERE=$(cd "$(dirname "$0")/.." && pwd); OUT=$HERE/work/u2netp-emulator/flows; mkdir -p "$OUT"
run() { # photo scenario tag wait_seconds
  before=$(adb -s $A shell 'ls /sdcard/Pictures/Lightly/ 2>/dev/null' | tr -d '\r' | sort)
  adb -s $A shell am force-stop $P; adb -s $A logcat -c
  adb -s $A shell am start -f 0x10008000 -n $P/.MainActivity --es lightly.debug.photo /data/user/0/$P/files/$1 --es lightly.debug.editor $2 >/dev/null
  for i in $(seq 1 $4); do sleep 1; adb -s $A logcat -d | grep -q "Saved as a new photo" && break; done
  sleep 3
  echo "== $3 ($1, $2)"; adb -s $A logcat -d | grep -E "LightlyFlow|LightlyBgTime|FATAL|AndroidRuntime" | grep -v adbd | cut -c33-330
  adb -s $A exec-out screencap -p > "$OUT/$3.png"
  new=$(comm -13 <(echo "$before") <(adb -s $A shell 'ls /sdcard/Pictures/Lightly/ 2>/dev/null' | tr -d '\r' | sort) | head -1)
  [ -n "$new" ] && adb -s $A pull "/sdcard/Pictures/Lightly/$new" "$OUT/$3-saved.jpg" >/dev/null && echo "saved copy: $new"
}
run subject_boat.jpg bg-object-flow boat-flow 60
run subject_swan.jpg bg-object-flow swan-flow 60
run landscape_02.jpg bg-no-subject lake-no-subject 25
run subject_boat.jpg bg-cancel-flow boat-cancel 30
run night_03.jpg pt-no-usable-face bar-portrait 20
