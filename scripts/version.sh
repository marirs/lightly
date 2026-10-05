#!/bin/bash
# Prints "<marketing version> <build number>" for HEAD (see version.properties).
#   scripts/version.sh            -> 1.0.0 261005047
#   scripts/version.sh --build    -> 261005047
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
marketing=$(sed -n 's/^marketingVersion=//p' "$ROOT/version.properties")
day=$(git -C "$ROOT" log -1 --date=format-local:%y%m%d --format=%cd HEAD)
sequence=$(git -C "$ROOT" log --date=format-local:%y%m%d --format=%cd HEAD | grep -c "^$day$")
[ "$sequence" -le 999 ] || { echo "more than 999 commits on $day" >&2; exit 1; }
build=$(printf "%s%03d" "$day" "$sequence")
if [ "${1:-}" = "--build" ]; then echo "$build"; else echo "$marketing $build"; fi
