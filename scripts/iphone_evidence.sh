#!/bin/bash
# Pull the DEBUG trace and evidence files from the dev iPhone and check the build identity.
#   scripts/iphone_evidence.sh [expected-build]   (default: the build of HEAD, scripts/version.sh)
# Writes ~/.codex/artifacts/lightly/v1/iphone-evidence/<timestamp>/ and prints the launch lines, the Background and
# Save copy stages, and the evidence files. Dev device 4C50E425 (iPhone 11 Pro Max) only.
set -u
D=4C50E425-9BEA-58DB-9D5E-2BF46A9F0A6C; APP=com.lightlylabs.lightly
EXPECTED=${1:-$(scripts/version.sh | awk '{print $2}')}
OUT=~/.codex/artifacts/lightly/v1/iphone-evidence/$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"
installed=$(xcrun devicectl device info apps --device $D --bundle-id $APP 2>/dev/null | awk '/com.lightlylabs.lightly/ {print $NF}')
echo "installed build: ${installed:-unknown} (expected $EXPECTED)"
xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $APP --source Documents/save-trace.log --destination "$OUT/save-trace.log" >/dev/null 2>&1 \
  || { echo "trace: could not copy Documents/save-trace.log (device not reachable, or the app has never written it)"; exit 1; }
lines=$(wc -l < "$OUT/save-trace.log" | tr -d ' ')
echo "trace: $lines lines"
launch=$(grep "launch: Lightly" "$OUT/save-trace.log" | tail -1)
if [ -z "$launch" ]; then
  echo "NO LAUNCH LINE: the installed build did not write its launch marker. Diagnose logging/retrieval before anything else."
elif ! echo "$launch" | grep -q "($EXPECTED)"; then
  echo "LAUNCH LINE FROM ANOTHER BUILD: $launch"
else
  echo "ok: $launch"
fi
echo "--- since the last launch:"
awk '/launch: Lightly/ {buf=""} {buf=buf $0 "\n"} END {printf "%s", buf}' "$OUT/save-trace.log" | grep -E "launch|source:|background:|subject:|auto:|ruler:|save|evidence|restore" | tail -60
files=$(xcrun devicectl device info files --device $D --domain-type appDataContainer --domain-identifier $APP --subdirectory Documents/evidence 2>/dev/null | awk 'NR>3 && $1 !~ /^-/ {print $1}')
for f in $files; do
  xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $APP --source "Documents/evidence/$f" --destination "$OUT/$f" >/dev/null 2>&1 && echo "evidence: $f"
done
echo "saved to $OUT"
