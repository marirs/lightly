#!/bin/bash
# bgcheck.sh SCENARIO PHOTOFILE OUTDIR — runs one debug Save-copy scenario on the review emulator,
# samples the app's memory once a second (bounded), pulls the newest saved JPEG.
A=emulator-5554; P=com.lightlylabs.lightly; SC=$1; PH=$2; OUT=$3; mkdir -p $OUT
adb -s $A shell am force-stop $P; adb -s $A logcat -c
before=$(adb -s $A shell "ls -t /sdcard/Pictures/*/ /sdcard/Pictures/ 2>/dev/null | head -1")
adb -s $A shell am start -f 0x10008000 -n $P/.MainActivity --es lightly.debug.photo /data/user/0/$P/files/$PH --es lightly.debug.editor $SC >/dev/null
peak=0; pss=0
for i in $(seq 1 60); do
  sleep 1
  pid=$(adb -s $A shell pidof $P | tr -d '\r'); [ -z "$pid" ] && { echo "app not running at ${i}s"; continue; }
  m=$(adb -s $A shell dumpsys meminfo $pid | tr -d '\r')
  heap=$(echo "$m" | awk '/Java Heap:/{print $3}'); tot=$(echo "$m" | awk '/TOTAL PSS:/{print $3}')
  [ -n "$heap" ] && [ "$heap" -gt "$peak" ] && peak=$heap
  [ -n "$tot" ] && [ "$tot" -gt "$pss" ] && pss=$tot
  if adb -s $A logcat -d | grep -qiE "OutOfMemory|Saved as a new photo"; then break; fi
done
echo "peak Java heap KB=$peak peak total PSS KB=$pss after ${i}s"
adb -s $A logcat -d | grep -iE "OutOfMemory|Lightly.*(save|render|fail|Background)" | tail -8 | cut -c1-220
