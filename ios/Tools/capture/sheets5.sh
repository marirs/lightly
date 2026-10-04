#!/bin/bash
# sheets5.sh CELL ROOT SCREEN...: JPEG review sheets (8 reference|native pairs each; 4 in
# landscape) for SCREEN... of CELL, from $LIGHTLY_ARTIFACTS/<ROOT>/native/<CELL>/. References come
# only from scripts/reference_cache.py (variant auto-unavailable, except the screens drawn as
# registered: loading, developing, develop-failed). The pair JPEGs go to <ROOT>/compare/<CELL>/,
# the sheets to $LIGHTLY_SHEETS_DIR. The PNGs stay the evidence; these are review copies.
set -u
source "$(dirname "$0")/env.sh"
CELL=$1; ROOT=$2; shift 2
IFS=- read -r DEV OR TH TX <<< "$CELL"
compose=$(swift_tool compose) || exit 1; tile=$(swift_tool tile) || exit 1
mkdir -p "$LIGHTLY_SHEETS_DIR" "$LIGHTLY_ARTIFACTS/$ROOT/compare/$CELL"
tag=$(echo "$ROOT" | tr / _)
find "${LIGHTLY_SHEETS_DIR:?}" -maxdepth 1 -name "$tag-$CELL-*" -delete
PER=8; COLS=4; [ "$OR" = landscape ] && { PER=4; COLS=2; }
batch=(); k=0
flush() {
  [ ${#batch[@]} -eq 0 ] && return
  k=$((k+1)); local png="$LIGHTLY_SHEETS_DIR/$tag-$CELL-$k.png"
  "$tile" "$png" $COLS 900 "${batch[@]}"
  sips -Z 2600 "$png" --out "$png" >/dev/null
  sips -s format jpeg -s formatOptions 75 "$png" --out "${png%.png}.jpg" >/dev/null && find "$png" -delete
  echo "${png%.png}.jpg"; batch=()
}
for s in "$@"; do
  v=auto-unavailable; case $s in loading|developing|develop-failed) v="";; esac
  ref=$(cd "$LIGHTLY_REPO" && python3 scripts/reference_cache.py get "$s" "$DEV" "$OR" "$TH" "$TX" $v 2>/dev/null | tail -1)
  native="$LIGHTLY_ARTIFACTS/$ROOT/native/$CELL/$s.png"
  if [ ! -f "$ref" ] || [ ! -f "$native" ]; then echo "MISSING $s (reference '$ref', native '$native')"; continue; fi
  out="$LIGHTLY_ARTIFACTS/$ROOT/compare/$CELL/$s.jpg"
  "$compose" "$ref" "$native" "$out" >/dev/null
  batch+=("$out")
  [ ${#batch[@]} -eq $PER ] && flush
done
flush
