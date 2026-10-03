#!/bin/bash
# Prints revision=<HEAD> and local_changes=<sha256 or "none">: a hash of the uncommitted changes under
# android/ (tracked diff plus untracked files' contents). Two captures with the same pair were built
# from the same source.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
echo "revision=$(git -C "$REPO" rev-parse HEAD)"
changes=$( { git -C "$REPO" diff HEAD --binary -- android
            git -C "$REPO" ls-files --others --exclude-standard -- android | sort | while read -r f; do echo "$f"; shasum -a 256 < "$REPO/$f"; done; } )
if [ -z "$changes" ]; then echo "local_changes=none"; else echo "local_changes=$(printf '%s' "$changes" | shasum -a 256 | cut -c1-64)"; fi
