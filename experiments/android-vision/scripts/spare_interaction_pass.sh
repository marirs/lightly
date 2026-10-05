#!/bin/bash
# Android interaction pass on the SPARE emulator (Pixel_9_Pro AVD, port 5556; never the review emulator): Develop browsing,
# Edit > Crop corner drag, Save copy; screenshots and the saved JPEG. Taps use the UI-automation dump's bounds.
set -u; APK=$1; A=emulator-5556; P=com.lightlylabs.lightly; HERE=$(cd "$(dirname "$0")/.." && pwd); OUT=$HERE/work/spare-pass; mkdir -p "$OUT"; rm -f "$OUT"/*
~/Library/Android/sdk/emulator/emulator -avd Pixel_9_Pro -port 5556 -no-window -no-snapshot-save -no-boot-anim -gpu swiftshader_indirect > "$OUT/emulator.log" 2>&1 &
for i in $(seq 1 150); do [ "$(adb -s $A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; sleep 2; done
adb -s $A shell settings put global window_animation_scale 0; adb -s $A shell settings put global hide_error_dialogs 1; adb -s $A shell input keyevent 82
adb -s $A install -r "$APK" | tail -1
adb -s $A shell run-as $P mkdir -p files; adb -s $A push "$HERE/../../docs/ui/assets/photos/landscape_02.jpg" /data/local/tmp/l.jpg >/dev/null; adb -s $A shell run-as $P cp /data/local/tmp/l.jpg files/landscape_02.jpg
shot() { adb -s $A exec-out screencap -p > "$OUT/$1.png"; }
tap_text() { # tap the centre of the first node whose text or content-desc matches $1
  adb -s $A shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb -s $A pull /sdcard/ui.xml "$OUT/ui.xml" >/dev/null
  python3 - "$OUT/ui.xml" "$1" <<'PY' | xargs -r adb -s emulator-5556 shell input tap
import re,sys
x=open(sys.argv[1]).read()
for m in re.finditer(r'<node [^>]*?(?:text|content-desc)="%s"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"' % re.escape(sys.argv[2]), x):
    a,b,c,d=map(int,m.groups()); print((a+c)//2,(b+d)//2); break
PY
}
bounds_of() { python3 - "$OUT/ui.xml" "$1" <<'PY'
import re,sys
x=open(sys.argv[1]).read()
m=re.search(r'<node [^>]*?(?:text|content-desc)="%s"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"' % re.escape(sys.argv[2]), x)
print(*m.groups()) if m else print("")
PY
}
adb -s $A shell am start -f 0x10008000 -n $P/.MainActivity --es lightly.debug.photo /data/user/0/$P/files/landscape_02.jpg --es lightly.debug.editor dev-preset >/dev/null; sleep 25
shot 1-landscape-applied
if [ "${STRIP_ONLY:-0}" = 1 ]; then adb -s $A emu kill >/dev/null 2>&1; sleep 3; exit 0; fi
tap_text "Portrait"; sleep 4; shot 2-browsing-portrait
tap_text "Edit"; sleep 6; shot 3-crop-whole-frame
adb -s $A shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb -s $A pull /sdcard/ui.xml "$OUT/ui.xml" >/dev/null
read l t r b < <(bounds_of "Drag a corner or an edge to crop. Drag inside to move.")
if [ -n "${l:-}" ]; then adb -s $A shell input swipe $((r-4)) $((b-4)) $(( l + (r-l)*70/100 )) $(( t + (b-t)*75/100 )) 800; sleep 5; shot 4-corner-dragged; else echo "crop frame not found"; fi
before=$(adb -s $A shell 'ls /sdcard/Pictures/Lightly/ 2>/dev/null' | tr -d '\r' | sort)
tap_text "Save copy"; for i in $(seq 1 60); do sleep 2; new=$(comm -13 <(echo "$before") <(adb -s $A shell 'ls /sdcard/Pictures/Lightly/ 2>/dev/null' | tr -d '\r' | sort) | head -1); [ -n "$new" ] && break; done
sleep 3; shot 5-saved
[ -n "${new:-}" ] && adb -s $A pull "/sdcard/Pictures/Lightly/$new" "$OUT/saved.jpg" >/dev/null && sips -g pixelWidth -g pixelHeight "$OUT/saved.jpg" | tail -2
sips -g pixelWidth -g pixelHeight "$HERE/../../docs/ui/assets/photos/landscape_02.jpg" | tail -2
adb -s $A emu kill >/dev/null 2>&1; sleep 3; echo done
