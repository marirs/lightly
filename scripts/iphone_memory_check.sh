#!/bin/bash
# iphone_memory_check.sh: 48 MP memory and time on the dev iPhone 11 Pro Max (4C50E425 only), without touching the
# owner's stored edit. Every launch passes the DEBUG `--keep-stored-session`, so the editor neither writes nor clears
# Application Support/EditSession or RemovePatches; the session files' SHA-256 are compared before and after.
#   scripts/iphone_memory_check.sh [fixture.jpg]   (default: the CC0 8000x6000 PD12M fixture)
# Checks, one fresh process each (the peak footprint is per process):
#   develop: ed-adjust-light, Save copy to Documents   → "save timing … peakFootprint=…"
#   remove:  ed-remove, one LaMa stroke                → "scenario ed-remove: removed, peakFootprint=…"
#   background: bg-colour-dark, Save copy to Documents → "save timing … peakFootprint=…"
# A check that does not log its line within its time limit is reported as not finished; nothing is retried.
set -u
D=4C50E425-9BEA-58DB-9D5E-2BF46A9F0A6C; APP=com.lightlylabs.lightly
REPO=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE=${1:-$REPO/experiments/auto/data/pd12m/eval_originals/c8954609f02a4f76ddfa575d71823e59.jpg}
OUT=~/.codex/artifacts/lightly/v1/iphone-memory/$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"
SESSION="Library/Application Support/EditSession"
xcrun devicectl list devices 2>/dev/null | grep -q "$D.*available" || { echo "iPhone 11 Pro Max not available (locked or disconnected)"; exit 75; }
get() { xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $APP --source "$1" --destination "$2" >/dev/null 2>&1; }
session_sums() {
  mkdir -p "$OUT/$1"
  for f in history.jsonl original.bin analysis.json; do get "$SESSION/$f" "$OUT/$1/$f" || echo "missing" > "$OUT/$1/$f"; done
  (cd "$OUT/$1" && shasum -a 256 history.jsonl original.bin analysis.json)
}
session_sums before > "$OUT/session-before.sha"; cat "$OUT/session-before.sha" | cut -c1-16,66-
xcrun devicectl device copy to --device $D --domain-type appDataContainer --domain-identifier $APP --source "$FIXTURE" \
  --destination Documents/fixture48.jpg >/dev/null 2>&1 || { echo "could not copy the fixture to Documents"; exit 1; }

run_check() { # name, seconds, wait-pattern, scenario arguments...
  local name=$1 limit=$2 pattern=$3; shift 3
  get Documents/save-trace.log "$OUT/trace-$name-before.log" || : > "$OUT/trace-$name-before.log"
  local start; start=$(wc -l < "$OUT/trace-$name-before.log")
  xcrun devicectl device process launch --device $D --terminate-existing $APP --keep-stored-session \
    --open-photo fixture48.jpg "$@" 2>&1 | grep -qi "launched" || { echo "$name: launch failed"; return; }
  local waited=0
  while [ $waited -lt "$limit" ]; do
    sleep 10; waited=$((waited + 10))
    get Documents/save-trace.log "$OUT/trace-$name.log" || continue
    if tail -n +$((start + 1)) "$OUT/trace-$name.log" | grep -q "$pattern"; then
      echo "$name (${waited}s):"; tail -n +$((start + 1)) "$OUT/trace-$name.log" | grep -E "launch:|source:|$pattern" | cut -c1-240 | sed 's/^/  /'
      return
    fi
  done
  echo "$name: not finished within ${limit}s"; tail -n +$((start + 1)) "$OUT/trace-$name.log" 2>/dev/null | tail -5 | sed 's/^/  /'
}
run_check develop 240 "save timing" --scenario ed-adjust-light --save-copy --save-to-documents m48-develop.jpg
run_check remove 240 "removed, peakFootprint" --scenario ed-remove
run_check background 300 "save timing" --scenario bg-colour-dark --save-copy --save-to-documents m48-background.jpg
xcrun devicectl device process launch --device $D --terminate-existing $APP --keep-stored-session >/dev/null 2>&1 || :
session_sums after > "$OUT/session-after.sha"
if diff -q "$OUT/session-before.sha" "$OUT/session-after.sha" >/dev/null; then echo "stored session unchanged (SHA-256 of all three files)"
else echo "STORED SESSION CHANGED:"; diff "$OUT/session-before.sha" "$OUT/session-after.sha"; fi
echo "saved to $OUT"
