#!/bin/bash
# One controlled reproduction of the device Save copy with the system log attached (iPhone 11 Pro Max, dev device).
# MODE=documents: the DEBUG --save-to-documents writer; MODE=photos: the ordinary PhotoKit writer (needs the add-only
# permission on the phone). Writes the filtered log and, for documents, the saved file. Run through scripts/heavy.
D=4C50E425-9BEA-58DB-9D5E-2BF46A9F0A6C; U=00008030-001C71D03E78802E; B=com.lightlylabs.lightly
OUT=$(cd "$(dirname "$0")/../out" && pwd)/device-save-diagnosis; MODE=${MODE:-documents}; LOG=$OUT/$MODE.log
[ "${BUILD:-1}" = 1 ] && { (cd "$(dirname "$0")/../../../ios" && xcodegen generate >/dev/null && xcodebuild build -project Lightly.xcodeproj -scheme Lightly -configuration Debug -destination "generic/platform=iOS" \
  -derivedDataPath /tmp/lightly-dd-review-device -allowProvisioningUpdates $(bash "$(dirname "$0")/../../../scripts/version.sh" | awk '{print "MARKETING_VERSION="$1" CURRENT_PROJECT_VERSION="$2}') CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=3UDFB78DLC CODE_SIGN_IDENTITY="Apple Development" -quiet 2>&1 | grep -E "error:" | head) ;
  xcrun devicectl device install app --device $D /tmp/lightly-dd-review-device/Build/Products/Debug-iphoneos/Lightly.app 2>&1 | grep -iE "installed|error" | head -2; }
# The trace file (DEBUG SaveTrace) starts empty; the system log is attempted over the network as well.
: > $OUT/empty.log
xcrun devicectl device copy to --device $D --domain-type appDataContainer --domain-identifier $B --source $OUT/empty.log --destination Documents/save-trace.log 2>&1 | grep -i error
idevicesyslog -n -u $U -p Lightly > $LOG.raw 2>&1 & SYS=$!
sleep 3
args="--open-photo pm02_12mp.jpg --scenario bg-colour-dark --save-copy"
[ "$MODE" = documents ] && args="$args --save-to-documents diag-pm02-dark.jpg"
xcrun devicectl device process launch --device $D --terminate-existing $B $args 2>&1 | grep -iE "error|launched"
for i in $(seq 1 18); do sleep 10
  xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $B --source Documents/save-trace.log --destination $OUT/$MODE-trace.log >/dev/null 2>&1
  grep -qE "save written|save failed|save ignored" $OUT/$MODE-trace.log 2>/dev/null && break; done
echo "--- trace ($MODE)"; cat $OUT/$MODE-trace.log
sleep 5; kill $SYS 2>/dev/null
grep -E "DebugScenario|SaveCopy|Jetsam|jetsam|crash|Terminat|EXC_|memory|watchdog" $LOG.raw | grep -iv "assertion" | cut -c1-260 > $LOG; tail -25 $LOG
[ "$MODE" = documents ] && xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $B --source Documents/diag-pm02-dark.jpg --destination $OUT/diag-pm02-dark.jpg 2>&1 | grep -i error
ls -la $OUT
