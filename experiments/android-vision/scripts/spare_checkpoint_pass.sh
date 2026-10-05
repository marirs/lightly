#!/bin/bash
# Checkpoint pass on the SPARE emulator (Pixel_9_Pro AVD, port 5556; never the review emulator), real touches only:
# Develop ruler while browsing (cancel, commit, Undo, Redo), Edit > free crop (corner, edge, move) and Save copy,
# then Background Cancel -> leave -> reopen -> retry. Each step writes a screenshot and the visible texts.
set -u; APK=$1; A=emulator-5556; P=com.lightlylabs.lightly; HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$HERE/work/checkpoint-pass}; mkdir -p "$OUT"; rm -f "$OUT"/*
~/Library/Android/sdk/emulator/emulator -avd Pixel_9_Pro -port 5556 -no-window -no-snapshot-save -no-boot-anim -gpu swiftshader_indirect > "$OUT/emulator.log" 2>&1 &
for i in $(seq 1 150); do [ "$(adb -s $A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; sleep 2; done
adb -s $A shell settings put global window_animation_scale 0; adb -s $A shell settings put global hide_error_dialogs 1; adb -s $A shell input keyevent 82
adb -s $A install -r "$APK" | tail -1
adb -s $A shell run-as $P mkdir -p files
adb -s $A push "$HERE/../../docs/ui/assets/photos/landscape_02.jpg" /data/local/tmp/l.jpg >/dev/null
adb -s $A shell run-as $P cp /data/local/tmp/l.jpg files/landscape_02.jpg

dump() { adb -s $A shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb -s $A pull /sdcard/ui.xml "$OUT/ui.xml" >/dev/null; }
# step <name>: screenshot + the visible texts (text and content-desc, top to bottom)
step() {
  adb -s $A exec-out screencap -p > "$OUT/$1.png"; dump
  python3 - "$OUT/ui.xml" > "$OUT/$1.txt" <<'PY'
import re,sys
x=open(sys.argv[1]).read()
for m in re.finditer(r'<node [^>]*?text="([^"]*)"[^>]*?resource-id="([^"]*)"[^>]*?content-desc="([^"]*)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', x):
    t,r,d,a,b,c,e=m.groups()
    if t or d or r: print(f'{b:>5} {a:>5} | {t} | {d} | {r} | [{a},{b}][{c},{e}]')
PY
  echo "== $1"; grep -E "Applied from|/ [0-9]+ |Finding|Couldn't|Cancelled|measure depth" "$OUT/$1.txt" | cut -d'|' -f1-3
}
# bounds <regex on text|content-desc|resource-id> -> "l t r b" of the first match in the last dump
bounds() { python3 - "$OUT/ui.xml" "$1" <<'PY'
import re,sys
x=open(sys.argv[1]).read()
for m in re.finditer(r'<node [^>]*?text="([^"]*)"[^>]*?resource-id="([^"]*)"[^>]*?content-desc="([^"]*)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', x):
    if any(re.fullmatch(sys.argv[2], v) for v in m.groups()[:3]): print(*m.groups()[3:]); break
PY
}
tap() { dump; read l t r b < <(bounds "$1"); [ -n "${l:-}" ] && adb -s $A shell input tap $(((l+r)/2)) $(((t+b)/2)) || echo "not found: $1"; }

adb -s $A shell am start -f 0x10008000 -n $P/.MainActivity --es lightly.debug.photo /data/user/0/$P/files/landscape_02.jpg --es lightly.debug.editor dev-preset >/dev/null; sleep 25
step 01-landscape-applied

# --- Develop ruler
tap "Portrait"; sleep 3; step 02-browsing-portrait
dump; read l t r b < <(bounds "develop-ruler"); cx=$(((l+r)/2)); cy=$(((t+b)/2))
adb -s $A shell input swipe $cx $cy $((cx+300)) $cy 700; sleep 3; step 03-drag-back-to-start-cancel
adb -s $A shell input swipe $cx $cy $((cx-90)) $cy 900; sleep 4; step 04-portrait-committed
tap "editor-undo"; sleep 4; step 05-undo
tap "editor-redo"; sleep 4; step 06-redo

# --- Edit > free crop, then Save copy
tap "Edit"; sleep 6; step 10-crop-whole-frame
dump; read sl st sr sb < <(bounds "editor-stage")
# The photo fits the stage (landscape_02 is 2:3 portrait); the crop editor shows it uncropped.
read pl pt pr pb < <(python3 -c "
sl,st,sr,sb=$sl,$st,$sr,$sb; w,h=sr-sl,sb-st; a=2/3
pw,ph=(w,w/a) if w/h<a else (h*a,h); x=sl+(w-pw)/2; y=st+(h-ph)/2; print(int(x),int(y),int(x+pw),int(y+ph))")
echo "photo on stage: $pl $pt $pr $pb" | tee "$OUT/photo-rect.txt"
pw=$((pr-pl)); ph=$((pb-pt))
adb -s $A shell input swipe $((pl+6)) $((pt+6)) $((pl+pw*20/100)) $((pt+ph*12/100)) 900; sleep 4; step 11-top-left-corner
adb -s $A shell input swipe $((pr-3)) $((pt+ph/2)) $((pr-pw*15/100)) $((pt+ph/2)) 900; sleep 4; step 12-right-edge
adb -s $A shell input swipe $((pl+pw/2)) $((pt+ph/2)) $((pl+pw/2-pw*5/100)) $((pt+ph/2+ph*6/100)) 900; sleep 4; step 13-moved
tap "Rotate"; sleep 5; step 14-cropped-preview
before=$(adb -s $A shell 'ls /sdcard/Pictures/Lightly/ 2>/dev/null' | tr -d '\r' | sort)
tap "Save copy"; for i in $(seq 1 60); do sleep 2; new=$(comm -13 <(echo "$before") <(adb -s $A shell 'ls /sdcard/Pictures/Lightly/ 2>/dev/null' | tr -d '\r' | sort) | head -1); [ -n "$new" ] && break; done
sleep 3; step 15-saved
[ -n "${new:-}" ] && adb -s $A pull "/sdcard/Pictures/Lightly/$new" "$OUT/saved.jpg" >/dev/null && sips -g pixelWidth -g pixelHeight "$OUT/saved.jpg" | tail -2
dump; echo "stage after save: $(bounds editor-stage)" | tee -a "$OUT/photo-rect.txt"
adb -s $A shell input keyevent 4; sleep 2

# --- Background: Cancel -> leave -> reopen -> retry, on a photo with a subject; "bg-slow" delays separation 8 s
adb -s $A push "$HERE/../../docs/ui/assets/photos/portrait_medium_02.jpg" /data/local/tmp/p.jpg >/dev/null
adb -s $A shell run-as $P cp /data/local/tmp/p.jpg files/portrait_medium_02.jpg
adb -s $A shell am force-stop $P
adb -s $A shell am start -f 0x10008000 -n $P/.MainActivity --es lightly.debug.photo /data/user/0/$P/files/portrait_medium_02.jpg --es lightly.debug.editor bg-slow >/dev/null; sleep 20
step 20-portrait-photo
tap "tool-background"; sleep 1; step 21-finding
tap "Cancel"; sleep 2; step 22-after-cancel
tap "tool-develop"; sleep 2; tap "tool-background"; sleep 10; step 23-reopened-no-restart
# Retry: the next Background edit (Blur slider released at its middle) starts the analysis again.
tap "background-slider-blur"; sleep 2; step 24-retry-started
sleep 45; step 25-retry-finished
tap "segment-Change background"; sleep 3; step 26-change-background
adb -s $A logcat -d -s LightlyDepth LightlyFlow AndroidRuntime > "$OUT/logcat.txt" 2>&1
adb -s $A emu kill >/dev/null 2>&1; sleep 3; echo done
