#!/bin/bash
# One submission only. Busy/timeout is pending, never a reason to wait/retry.
source "$(dirname "$0")/env.sh"
[ "$#" -ge 2 ] || exit 64
cd "$LIGHTLY_REPO" || exit 1
exec rtk proxy scripts/heavy "$@"
