#!/bin/bash
# capture-batch.sh: one emulator boot for ONE device/orientation/theme/text-size combination, all its
# screens, then the emulator is shut down. Run it through scripts/heavy (one lock hold per batch):
#
#   scripts/heavy android-capture-runner-p9-light-default \
#     android/tools/capture/capture-batch.sh --avd Pixel_9_Pro --port 5580 --device pixel9pro \
#       --orientation portrait --posture as-is --theme light --text default --mode runner \
#       --out ~/.codex/artifacts/lightly/v1/captures/android [screens...]
#
# --mode runner  persistent session: one app process; the debug-only capture runner
#                (app/src/debug/.../CaptureRunnerHook.kt) resets all per-screen state, applies the screen
#                and logs "ready" once the render is complete; no sleeps between screens.
# --mode runner  the Android capture path (adopted): persistent session, see above.
# --mode launch  a fresh NEW_TASK|CLEAR_TASK launch per screen, waiting for the same ready signal
#                (--ei lightly.capture.signal). Only for lifecycle and launch checks.
# The earlier fixed-wait per-launch path is retired: it captured previews before they had rendered
# (docs/v1/slice2-android.md, "Comparison matrix").
# --posture      as-is | fold | unfold | rot0 | rot1 (user rotation with auto-rotate off)
# --display      screencap display id (two-display AVDs: the Fold)
#
# Every PNG gets a sidecar <png>.json: screen, device, orientation, theme, text size, mode, source
# revision and local-change fingerprint (from the APK's build-info.json), APK hash, capture-tool version,
# AVD and time. The PNG is the evidence; contact sheets are generated from it on demand.
set -uo pipefail
TOOL_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TOOL_DIR/../../.." && pwd)
SDK=$HOME/Library/Android/sdk
PKG=com.lightlylabs.lightly
# CAPTURE_APK pins a recorded APK (BUILD_RECORD) so later builds cannot change a running matrix.
APK=${CAPTURE_APK:-$REPO/android/app/build/outputs/apk/debug/app-debug.apk}
DEFAULT_SCREENS="loading developing developed model-unavailable develop-failed dev-preset dev-original dev-dragging dev-browse dev-large dev-long-name dev-amount dev-starred dev-favourites dev-fav-full dev-fav-replace dev-bw dev-landscape-photo dev-portrait-photo compare saving saved leave-unsaved more"

AVD= PORT= DEV= ORIENT= POSTURE=as-is THEME= TEXT= MODE= OUT= DISP=
while [ $# -gt 0 ]; do
  case $1 in
    --avd) AVD=$2; shift 2;; --port) PORT=$2; shift 2;; --device) DEV=$2; shift 2;;
    --orientation) ORIENT=$2; shift 2;; --posture) POSTURE=$2; shift 2;; --theme) THEME=$2; shift 2;;
    --text) TEXT=$2; shift 2;; --mode) MODE=$2; shift 2;; --out) OUT=$2; shift 2;; --display) DISP=$2; shift 2;;
    --) shift; break;; -*) echo "unknown option $1" >&2; exit 64;; *) break;;
  esac
done
SCREENS=${*:-$DEFAULT_SCREENS}
for v in AVD PORT DEV ORIENT THEME TEXT MODE OUT; do [ -n "${!v}" ] || { echo "missing --$(echo $v | tr A-Z a-z)" >&2; exit 64; }; done
case $MODE in runner|launch) ;; *) echo "--mode must be runner or launch (the fixed-wait path is retired)" >&2; exit 64;; esac
[ -f "$APK.build-info.json" ] || { echo "no build-info.json next to the APK: build with build-apk.sh" >&2; exit 65; }
SERIAL=emulator-$PORT
ADB="$SDK/platform-tools/adb -s $SERIAL"
TOOL_VERSION=$(cat "$TOOL_DIR"/capture-batch.sh "$REPO"/android/app/src/debug/kotlin/com/lightlylabs/lightly/capture/CaptureRunnerHook.kt | shasum -a 256 | cut -c1-16)
mkdir -p "$OUT"

# Bounded wait for a command (macOS has no `timeout`): a hung device fails the batch, never blocks forever.
bounded() { local seconds=$1; shift; perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"; }

# --- per-screen inputs (same mapping as the per-launch captures) ---------------------------------
FAVS=look-d8704f3622765f1c77c4,look-617ee7c8edcb1bad9c35,look-5c41fdbeb28f5f83f0d0,look-5b83aa782a1e85276462,look-a2ea17e735e9957ee464
HIKING=look-617ee7c8edcb1bad9c35
FILES=/data/user/0/$PKG/files
photo_for() { case $1 in bg-no-subject) echo landscape_02;; bg-*) echo portrait_medium_02;;
  # Slice 3 Portrait (screens.js): man = portrait_deep_03, smile = portrait_deep_02, bar = night_03, field = landscape_03;
  # pt-multi uses the licensed group photo, as iOS (deviation P2: the prototype could show only one face).
  pt-teeth|pt-landscape-photo) echo portrait_deep_02;; pt-multi) echo group_three_01;; pt-no-usable-face) echo night_03;; pt-hidden) echo landscape_03;; pt-*) echo portrait_deep_03;; dev-long-name) echo landscape_03;;
  # Slice 4 (screens.js): field = landscape_03, street = wellexposed_03, sunset = sunset_02, lake = landscape_02.
  ed-rotate|ed-straighten|ed-remove|ed-removing|ed-remove-failed|s4-export) echo landscape_03;; ed-perspective) echo wellexposed_03;; fx-leak|fx-combined|bd-frame|wm-none|wm-signature|wm-sig-draw|wm-sig-import|wm-text) echo sunset_02;; bd-polaroid) echo portrait_deep_03;; dev-favourites|dev-bw|dev-portrait-photo) echo portrait_deep_03;; dev-landscape-photo) echo sunset_02;; *) echo landscape_02;; esac; }
people_for() { case $(photo_for $1) in portrait_deep_03|portrait_medium_02) echo present;; *) echo absent;; esac; }
# Slice-1 screens (no photo): file id → debug navigation route (DebugLaunchOptions screen names).
SLICE1_SCREENS="welcome welcome-more camera-denied load-failed preferences pref-favourites pref-signature pref-border legal privacy terms about support"
route_for() { case $1 in welcome-more) echo more;; pref-favourites) echo favourites;; pref-signature) echo signature;; pref-border) echo preferred_border;; *) echo $1;; esac; }
is_slice1() { case " $SLICE1_SCREENS " in *" $1 "*) return 0;; *) return 1;; esac; }
# Slice-1 favourites preference shows these five; other slice-1 screens do not show favourites.
favs_for() { is_slice1 $1 && { echo $FAVS; return; }; case $1 in dev-favourites|dev-fav-full|dev-fav-replace) echo $FAVS;; dev-starred) echo $HIKING;; *) echo "";; esac; }

# --- boot (one per batch) ---------------------------------------------------------------------
boot_started=$(date +%s)
nohup "$SDK/emulator/emulator" -avd "$AVD" -port "$PORT" -read-only -no-snapshot -no-audio -no-boot-anim -no-window -memory 4096 -feature -Vulkan > "${TMPDIR:-/tmp}/lightly-emu-$AVD.log" 2>&1 &
bounded 600 bash -c "until [ \"\$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')\" = 1 ]; do sleep 2; done" || { echo "boot timed out" >&2; exit 70; }
$ADB shell settings put global hide_error_dialogs 1
$ADB shell settings put system screen_off_timeout 2147483647
$ADB shell svc power stayon true
$ADB shell locksettings set-disabled true
$ADB shell wm dismiss-keyguard
bounded 300 $ADB install -r "$APK" >/dev/null || { echo "install failed" >&2; $ADB emu kill; exit 71; }
case $POSTURE in
  fold) $ADB shell settings put system user_rotation 0; $ADB emu fold;;
  unfold) $ADB emu unfold;;
  rot0|rot1) $ADB shell settings put system accelerometer_rotation 0; $ADB shell settings put system user_rotation ${POSTURE#rot};;
esac
$ADB shell input keyevent KEYCODE_WAKEUP; $ADB shell wm dismiss-keyguard
# System UI demo mode: a fixed status bar (9:41, full battery, no notifications), so two captures of the
# same state differ only where the app differs. Same in both modes.
$ADB shell settings put global sysui_demo_allowed 1
demo() { $ADB shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null; }
demo enter; demo clock -e hhmm 0941; demo battery -e level 100 -e plugged false
# One broadcast per icon: extras with the same key ("level") would collapse into one.
demo network -e wifi show -e level 4 -e fully true; demo network -e mobile show -e level 4 -e datatype none -e fully true
demo notifications -e visible false
# Text size is a system setting read when the process starts: set before the app launches.
if [ "$TEXT" = large ]; then $ADB shell settings put system font_scale 1.24; else $ADB shell settings put system font_scale 1.0; fi
for p in landscape_02 landscape_03 sunset_02 portrait_deep_03 portrait_medium_02 wellexposed_03 portrait_deep_02 night_03 group_three_01; do
  src="$REPO/docs/ui/assets/photos/$p.jpg"; [ -f "$src" ] || src="$REPO/experiments/test-photos/$p.jpg"
  $ADB push -q "$src" /data/local/tmp/$p.jpg >/dev/null
  $ADB shell run-as $PKG sh -c "'mkdir -p files && cp /data/local/tmp/$p.jpg files/$p.jpg'"
done
echo "boot+setup $(( $(date +%s) - boot_started ))s"

# Two-display AVDs (the Fold): screencap without -d may read the display that is off (an all-black PNG).
# Unless --display is given, capture every physical display once and keep the one that shows content:
# a black frame compresses to a few KB, the app's frame to hundreds.
pick_display() {
  [ -n "$DISP" ] && return
  local ids best="" best_size=0
  ids=$($ADB shell dumpsys SurfaceFlinger --display-id 2>/dev/null | tr -d '\r' | sed -n 's/^Display \([0-9]*\).*/\1/p')
  [ $(echo "$ids" | wc -w) -le 1 ] && return
  for id in $ids; do
    size=$($ADB exec-out screencap -p -d $id | perl -0777 -pe 's/\A.*?(?=\x89PNG)//s' | wc -c | tr -d ' ')
    if [ "$size" -gt "$best_size" ]; then best=$id; best_size=$size; fi
  done
  DISP=$best
  echo "display $DISP (of: $(echo $ids))"
}
screencap() {  # <file>: two-display AVDs prefix a warning to stdout; keep only the PNG.
  $ADB exec-out screencap -p ${DISP:+-d $DISP} | perl -0777 -pe 's/\A.*?(?=\x89PNG)//s' > "$1"
}
sidecar() {  # <png> <screen> <ready line>
  python3 - "$1" "$2" "$3" "$APK.build-info.json" <<PY
import json, sys, time, hashlib
png, screen, ready, info = sys.argv[1:5]
meta = json.load(open(info))
meta.update(screen=screen, device="$DEV", orientation="$ORIENT", theme="$THEME", text="$TEXT", mode="$MODE",
            avd="$AVD", posture="$POSTURE", display="${DISP:-default}", capture_tool_version="$TOOL_VERSION", ready=ready,
            png_sha256=hashlib.sha256(open(png, "rb").read()).hexdigest(),
            captured_at=time.strftime("%Y-%m-%dT%H:%M:%S%z"))
json.dump(meta, open(png + ".json", "w"), indent=2)
PY
}

screens_started=$(date +%s)
failures=0
if [ "$MODE" = runner ]; then
  $ADB shell am force-stop $PKG
  $ADB logcat -c
  $ADB shell am start -n $PKG/.MainActivity --ez lightly.capture.runner true --es lightly.debug.appearance $THEME >/dev/null
  bounded 120 $ADB logcat -s LightlyCapture:I -m 1 -e "attached" >/dev/null || { echo "runner did not attach" >&2; failures=1; }
  pick_display
  seq=0
  for S in $SCREENS; do
    seq=$((seq + 1))
    F="$OUT/${S}__${DEV}__${ORIENT}__${THEME}__${TEXT}.png"
    $ADB logcat -c
    if is_slice1 $S; then
      target="--es lightly.debug.screen $(route_for $S)"
    else
      target="--es lightly.debug.photo $FILES/$(photo_for $S).jpg --es lightly.debug.editor $S --es lightly.debug.people $(people_for $S)"
    fi
    $ADB shell am broadcast -p $PKG -a com.lightlylabs.lightly.debug.CAPTURE --ei seq $seq \
      --es lightly.debug.appearance $THEME --es lightly.debug.favourites "'$(favs_for $S)'" $target >/dev/null
    line=$(bounded 150 $ADB logcat -s LightlyCapture:I -m 1 -e "(ready|failed) seq=$seq " | tr -d '\r' | tail -1)
    case $line in
      *"ready seq=$seq "*) screencap "$F"; sidecar "$F" "$S" "$line"; echo "$F ${line##*screen=}"
         # App diagnostics for this screen (small: depth and develop timing tags only).
         $ADB logcat -d -s LightlyDepth:I LightlyDevelop:I > "${F%.png}.app.log" 2>&1;;
      *) echo "FAILED $S: ${line:-no signal}" >&2; failures=$((failures + 1))
         # Keep the evidence: this screen's log (cleared at its start) and the crash buffer.
         $ADB logcat -d > "$OUT/${S}__${DEV}__${ORIENT}__${THEME}__${TEXT}.failure.log" 2>&1
         $ADB logcat -d -b crash >> "$OUT/${S}__${DEV}__${ORIENT}__${THEME}__${TEXT}.failure.log" 2>&1
         # A dead runner process cannot answer later screens: stop instead of timing out on each.
         if [ -z "$($ADB shell pidof $PKG | tr -d '\r')" ]; then echo "runner process died; batch stopped" >&2; break; fi;;
    esac
  done
elif [ "$MODE" = launch ]; then
  picked=
  seq=0
  for S in $SCREENS; do
    seq=$((seq + 1))
    F="$OUT/${S}__${DEV}__${ORIENT}__${THEME}__${TEXT}.png"
    $ADB logcat -c
    $ADB shell am start -f 0x10008000 -n $PKG/.MainActivity --ei lightly.capture.signal $seq --es lightly.debug.appearance $THEME --es lightly.debug.favourites "'$(favs_for $S)'" \
      --es lightly.debug.photo $FILES/$(photo_for $S).jpg --es lightly.debug.editor $S --es lightly.debug.people $(people_for $S) >/dev/null 2>&1
    line=$(bounded 150 $ADB logcat -s LightlyCapture:I -m 1 -e "(ready|failed) seq=$seq " | tr -d '\r' | tail -1)
    [ -z "$picked" ] && { pick_display; picked=1; }
    case $line in
      *"ready seq=$seq "*) screencap "$F"; sidecar "$F" "$S" "$line"; echo "$F ${line##*screen=}";;
      *) echo "FAILED $S: ${line:-no signal}" >&2; failures=$((failures + 1));;
    esac
  done
else
  echo "unknown --mode $MODE (runner | launch)" >&2; exit 64
fi
echo "screens $(( $(date +%s) - screens_started ))s for $(echo $SCREENS | wc -w | tr -d ' ') screens, failures=$failures"
$ADB shell settings put system font_scale 1.0
$ADB emu kill >/dev/null 2>&1
[ $failures = 0 ]
