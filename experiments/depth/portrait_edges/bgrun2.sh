#!/bin/bash
# bgrun2.sh SCENARIO PHOTOFILE OUTDIR: as bgrun.sh, but pulls only a saved JPEG that did not exist before the run.
S=/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/portrait_edges; A=emulator-5554
before=$(adb -s $A shell 'ls /sdcard/Pictures/Lightly/' | tr -d '\r' | sort)
bash "$S/bgcheck.sh" "$1" "$2" "$3" | grep -E "peak|LightlyBgTime" | tail -2
for i in $(seq 1 60); do
  new=$(comm -13 <(echo "$before") <(adb -s $A shell 'ls /sdcard/Pictures/Lightly/' | tr -d '\r' | sort) | head -1)
  [ -n "$new" ] && break; sleep 2
done
[ -n "$new" ] && sleep 2 && adb -s $A pull "/sdcard/Pictures/Lightly/$new" "$3/saved.jpg" >/dev/null && echo "pulled new $new" || echo "no new saved photo"
