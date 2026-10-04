#!/bin/bash
# diff5.sh OLD_DIR NEW_DIR [SKIP_TOP_ROWS]: pixel diff of every PNG in NEW_DIR against the same
# screen in OLD_DIR (status-bar rows skipped; 66 px covers the @2x iPads' date). Identical or
# 1-level icon noise lets a recapture inherit the earlier review; anything else is reviewed again.
source "$(dirname "$0")/env.sh"
pixdiff=$(swift_tool pixdiff) || exit 1
for f in "$2"/*.png; do s=$(basename "$f" .png)
  if [ -f "$1/$s.png" ]; then echo "$s $("$pixdiff" "$1/$s.png" "$f" "${3:-66}")"; else echo "$s MISSING-OLD"; fi
done
