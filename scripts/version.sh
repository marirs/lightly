#!/bin/bash
# Prints "<marketing version> <build number>" for HEAD (see version.properties).
#   scripts/version.sh            -> 1.0.0 261005047   (1.0.0-dev … when ios/, android/ or shared/ has uncommitted changes)
#   scripts/version.sh --build    -> 261005047
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
marketing=$(sed -n 's/^marketingVersion=//p' "$ROOT/version.properties")
day=$(git -C "$ROOT" log -1 --date=format-local:%y%m%d --format=%cd HEAD)
sequence=$(git -C "$ROOT" log --date=format-local:%y%m%d --format=%cd HEAD | grep -c "^$day$")
[ "$sequence" -le 999 ] || { echo "more than 999 commits on $day" >&2; exit 1; }
build=$(printf "%s%03d" "$day" "$sequence")
# A build from a working tree with uncommitted app changes is not that commit: its marketing version says so
# ("1.0.0-dev"), on both platforms, so it is never mistaken for the packaged build of the same number.
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no -- ios android shared version.properties 2>/dev/null)" ]; then
  marketing="$marketing-dev"
fi
if [ "${1:-}" = "--build" ]; then echo "$build"; else echo "$marketing $build"; fi
