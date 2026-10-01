#!/usr/bin/env bash
# Build, install and run the LUTBench feasibility harness, then pull results.
#
#   ./run_ios.sh "iPhone 17 Pro"                          # simulator by name (or simulator UDID)
#   ./run_ios.sh 3ADF213D-8A51-5A08-94E2-1C23796030DB     # paired physical device (CoreDevice identifier)
#
# Models are bundled (small; the app times compileModel itself). Golden fixtures (~600 MB) and the
# original JPEGs are copied into the app's data container (Documents/BenchInput), not the bundle.
# Results land in experiments/lut3d/results/ios/<device-slug>/.
#
# Env: LUTBENCH_TEAM (default 3UDFB78DLC, Xcode's last-selected provisioning team on this Mac),
#      LUTBENCH_TIMEOUT_S (default 5400).
set -euo pipefail

TARGET="${1:?usage: run_ios.sh <simulator-name|simulator-udid|device-udid>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LUT_ROOT="$(cd "$HERE/.." && pwd)"
PROJECT_DIR="$HERE/LUTBench"
BUILD_DIR="$HERE/build"
BUNDLE_ID="com.lightlylabs.lutbench"
TEAM="${LUTBENCH_TEAM:-3UDFB78DLC}"
TIMEOUT_S="${LUTBENCH_TIMEOUT_S:-5400}"
RUN_ID="run-$(date +%Y%m%d-%H%M%S)-$$"
RESULTS_ROOT="$LUT_ROOT/results/ios"

log() { printf '[run_ios %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# ---------------------------------------------------------------- target resolution
SIM_UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
target = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
matches = []
for runtime, entries in devices.items():
    if "iOS" not in runtime:
        continue
    for entry in entries:
        if entry["udid"] == target or entry["name"] == target:
            matches.append((runtime, entry["udid"]))
# Prefer the newest iOS runtime when several simulators share a name.
print(sorted(matches)[-1][1] if matches else "")
' "$TARGET")"

if [[ -n "$SIM_UDID" ]]; then MODE=simulator; else MODE=device; fi
log "target '$TARGET' -> $MODE ${SIM_UDID:-$TARGET}"

# ---------------------------------------------------------------- stage bundle data + generate project
log "staging models into LUTBench/BenchData"
rm -rf "$PROJECT_DIR/BenchData"
mkdir -p "$PROJECT_DIR/BenchData/models"
cp -R "$LUT_ROOT/models/ia3dlut_classifier_fp32.mlpackage" "$LUT_ROOT/models/ia3dlut_classifier_fp16.mlpackage" \
      "$LUT_ROOT/models/ia3dlut_basis_luts_f32.bin" "$PROJECT_DIR/BenchData/models/"

log "xcodegen"
(cd "$PROJECT_DIR" && xcodegen generate --spec project.yml --quiet)

# ---------------------------------------------------------------- build
if [[ "$MODE" == simulator ]]; then
  DESTINATION="id=$SIM_UDID"
  PRODUCTS_SUBDIR="Release-iphonesimulator"
  EXTRA_BUILD_ARGS=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-)
else
  # xcodebuild wants the hardware UDID; devicectl uses the CoreDevice identifier. Map one to the other.
  DEVICE_JSON="$(mktemp)"
  xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null
  HARDWARE_UDID="$(python3 -c '
import json, sys
target = sys.argv[2]
for device in json.load(open(sys.argv[1]))["result"]["devices"]:
    if target in (device.get("identifier"), device["hardwareProperties"].get("udid"), device["deviceProperties"].get("name")):
        print(device["hardwareProperties"]["udid"]); break
' "$DEVICE_JSON" "$TARGET")"
  rm -f "$DEVICE_JSON"
  [[ -n "$HARDWARE_UDID" ]] || { log "device $TARGET not found by devicectl"; exit 2; }
  DESTINATION="id=$HARDWARE_UDID"
  PRODUCTS_SUBDIR="Release-iphoneos"
  EXTRA_BUILD_ARGS=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic)
fi

if [[ "$MODE" == simulator ]]; then
  xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null
fi

log "xcodebuild ($DESTINATION)"
BUILD_LOG="$BUILD_DIR/xcodebuild-$MODE.log"
mkdir -p "$BUILD_DIR"
if ! xcodebuild -project "$PROJECT_DIR/LUTBench.xcodeproj" -scheme LUTBench -configuration Release \
      -destination "$DESTINATION" -derivedDataPath "$BUILD_DIR/DerivedData" \
      "${EXTRA_BUILD_ARGS[@]}" build >"$BUILD_LOG" 2>&1; then
  log "BUILD FAILED; errors from $BUILD_LOG:"
  grep -E "error:|Error |failed" "$BUILD_LOG" | sort -u | head -30 >&2
  exit 3
fi
APP_PATH="$BUILD_DIR/DerivedData/Build/Products/$PRODUCTS_SUBDIR/LUTBench.app"
log "built $APP_PATH ($(du -sh "$APP_PATH" | cut -f1))"

PULL_DIR="$(mktemp -d)"

# ---------------------------------------------------------------- simulator run
run_simulator() {
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$SIM_UDID" "$APP_PATH"
  local data_dir
  data_dir="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data)"
  mkdir -p "$data_dir/Documents/BenchInput"
  log "syncing golden + photos into $data_dir/Documents/BenchInput"
  rsync -a --delete --exclude .gitignore "$LUT_ROOT/golden/" "$data_dir/Documents/BenchInput/golden/"
  rsync -a --delete --exclude .gitignore --exclude MANIFEST.csv "$LUT_ROOT/photos/" "$data_dir/Documents/BenchInput/photos/"
  rm -rf "$data_dir/Documents/results"

  log "launching --run-bench --run-id $RUN_ID"
  xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" --run-bench --run-id "$RUN_ID" >/dev/null

  local done_file="$data_dir/Documents/results/done" waited=0
  until [[ -f "$done_file" ]] && head -1 "$done_file" | grep -qx "$RUN_ID"; do
    (( waited >= TIMEOUT_S )) && { log "timeout after ${waited}s; last log lines:"; tail -5 "$data_dir/Documents/results/log.txt" >&2 || true; exit 4; }
    sleep 10; waited=$((waited + 10))
    (( waited % 60 == 0 )) && log "waiting (${waited}s): $(tail -1 "$data_dir/Documents/results/log.txt" 2>/dev/null || echo '-')"
  done
  cp -R "$data_dir/Documents/results/." "$PULL_DIR/"
}

# ---------------------------------------------------------------- device run
devicectl_container() {  # devicectl_container <subcommand...>  (adds device + app-container domain)
  local subcommand=("$@")
  xcrun devicectl device "${subcommand[@]}" --device "$TARGET" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID"
}

run_device() {
  log "installing on $TARGET"
  xcrun devicectl device install app --device "$TARGET" "$APP_PATH" >/dev/null

  # devicectl copy skips unmodified files, so repeat runs only send what changed.
  log "copying golden + photos into the app container (first time ~640 MB)"
  devicectl_container copy to --source "$LUT_ROOT/golden" --destination Documents/BenchInput/golden --timeout 3600 >/dev/null
  devicectl_container copy to --source "$LUT_ROOT/photos" --destination Documents/BenchInput/photos --timeout 3600 >/dev/null

  log "launching --run-bench --run-id $RUN_ID"
  xcrun devicectl device process launch --device "$TARGET" --terminate-existing "$BUNDLE_ID" --run-bench --run-id "$RUN_ID" >/dev/null

  local waited=0 probe_dir
  probe_dir="$(mktemp -d)"
  while true; do
    sleep 15; waited=$((waited + 15))
    rm -f "$probe_dir/done"
    if devicectl_container copy from --source Documents/results/done --destination "$probe_dir/done" >/dev/null 2>&1 \
       && head -1 "$probe_dir/done" | grep -qx "$RUN_ID"; then
      break
    fi
    if (( waited % 60 == 0 )); then
      devicectl_container copy from --source Documents/results/log.txt --destination "$probe_dir/log.txt" >/dev/null 2>&1 || true
      log "waiting (${waited}s): $(tail -1 "$probe_dir/log.txt" 2>/dev/null || echo '-')"
    fi
    (( waited >= TIMEOUT_S )) && { log "timeout after ${waited}s"; exit 4; }
  done
  log "pulling Documents/results"
  devicectl_container copy from --source Documents/results --destination "$PULL_DIR" --timeout 1800 >/dev/null
}

if [[ "$MODE" == simulator ]]; then run_simulator; else run_device; fi

# devicectl may nest the copied directory; locate results.json wherever it landed.
RESULTS_JSON="$(find "$PULL_DIR" -name results.json -maxdepth 3 | head -1)"
[[ -n "$RESULTS_JSON" ]] || { log "results.json missing in pulled data"; exit 5; }
SLUG="$(python3 -c '
import json, re, sys
device = json.load(open(sys.argv[1]))["device"]
slug = re.sub(r"[^a-z0-9]+", "-", device["marketing_name"].lower()).strip("-")
print(("sim-" if device.get("is_simulator") else "") + re.sub(r"-?simulator-?", "", slug))
' "$RESULTS_JSON")"
DEST="$RESULTS_ROOT/$SLUG"
rm -rf "$DEST"; mkdir -p "$DEST"
cp -R "$(dirname "$RESULTS_JSON")/." "$DEST/"
rm -rf "$PULL_DIR"
log "results -> $DEST"
python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
print("device:", r["device"]["marketing_name"], r["device"]["os"], "errors:", r.get("errors"))
' "$DEST/results.json"
