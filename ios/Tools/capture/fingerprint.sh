#!/bin/bash
# fingerprint.sh: prints "<revision> <local-change fingerprint>" for ios/: the short HEAD revision
# and a SHA-256 over the tracked diff and the untracked files' contents under ios/ ("clean" when
# there are no local changes). Captures record it so a stale image is never taken for current.
source "$(dirname "$0")/env.sh"
R=$LIGHTLY_REPO
# A preflight snapshot (scripts/verify_preflight.py snapshot) is not a git checkout: it holds
# exactly one commit, recorded in .lightly-source, and no local changes by construction.
if [ -f "$R/.lightly-source" ]; then echo "$(cut -c1-7 "$R/.lightly-source") snapshot"; exit 0; fi
rev=$(git -C "$R" rev-parse --short HEAD)
changes=$( { git -C "$R" diff HEAD -- ios; git -C "$R" ls-files --others --exclude-standard -- ios | sort | while read -r f; do echo "== $f"; cat "$R/$f"; done; } )
if [ -z "$changes" ]; then echo "$rev clean"; else echo "$rev $(printf '%s' "$changes" | shasum -a 256 | cut -c1-16)"; fi
