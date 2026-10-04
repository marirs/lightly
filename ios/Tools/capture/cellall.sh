#!/bin/bash
# cellall.sh UDID DEVICE ORIENTATION THEME TEXT GROUP...
#   GROUP = <capture root>=<screen,screen,...>, the root relative to $LIGHTLY_ARTIFACTS
#           (for example slice4/ios/runner5); the PNGs land in <root>/native/<cell>/.
# One configuration cell, one app launch per group (runner v5). Keep each group to about 18 heavy
# screens or fewer: beyond that the Simulator render server stalls the app's commits.
# Run the whole call inside one lock acquisition:
#   scripts/heavy capture-ios-<cell> ios/Tools/capture/cellall.sh <udid> iphone17 portrait light default 'slice4/ios/runner5=ed-crop,...'
set -u
source "$(dirname "$0")/env.sh"
U=$1; DEV=$2; OR=$3; TH=$4; TX=$5; shift 5
CELL=$DEV-$OR-$TH-$TX
for group in "$@"; do
  root=${group%%=*}; screens=${group#*=}
  out="$LIGHTLY_ARTIFACTS/$root/native/$CELL"
  part="$out.part-$$"
  bash "$CAPTURE_TOOLS_DIR/capture.sh" session "$U" "$DEV" "$OR" "$TH" "$TX" "$screens" "$part" 2>&1 | sed "s|^|[$root] |"
  # Several groups may share a root: merge each part's PNGs and records into the cell folder.
  mkdir -p "$out"
  cp "$part"/*.png "$part"/*.json "$out"/ 2>/dev/null
  cp "$part/xcodebuild.log" "$out/xcodebuild-$(echo "$screens" | cut -d, -f1).log" 2>/dev/null
  find "${part:?}" -maxdepth 1 -type f -delete; rmdir "${part:?}" 2>/dev/null
  echo "GROUP DONE $CELL $root $(find "$out" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ') png in folder"
done
