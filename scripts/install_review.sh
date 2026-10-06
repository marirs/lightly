#!/bin/bash
# install_review.sh COMMIT: installs an already packaged checkpoint (scripts/package_review.sh) on the authorised review
# devices, keeping their data (update in place), and prints the installed build on each. Run through the lock:
#   scripts/heavy install-review scripts/install_review.sh <commit>
set -u
C=$1; OUT=$HOME/.codex/artifacts/lightly/v1/review-builds; A=$OUT/android/$C; I=$OUT/ios/$C
[ -f "$A/lightly-debug-$C-with-models.apk" ] && [ -f "$I/lightly-ios-review-$C-sim.zip" ] && [ -f "$I/lightly-ios-review-$C-iphone.zip" ] || { echo "no packages for $C"; exit 2; }
T=$(mktemp -d); (cd "$T" && mkdir sim iphone && unzip -q "$I/lightly-ios-review-$C-sim.zip" -d sim && unzip -q "$I/lightly-ios-review-$C-iphone.zip" -d iphone)
echo "== install $C $(date +%T)"
adb -s emulator-5554 install -r "$A/lightly-debug-$C-with-models.apk" | tail -1
echo "emulator-5554: $(adb -s emulator-5554 shell dumpsys package com.lightlylabs.lightly | grep -m1 versionCode | tr -s ' ')"
xcrun simctl install D75D820D-B43C-4330-8E6F-0FBEB2FA9D02 "$T/sim/Lightly.app" && \
  echo "simulator D75D820D: $(plutil -extract CFBundleVersion raw "$(xcrun simctl get_app_container D75D820D-B43C-4330-8E6F-0FBEB2FA9D02 com.lightlylabs.lightly)/Info.plist")"
D=4C50E425-9BEA-58DB-9D5E-2BF46A9F0A6C
if xcrun devicectl list devices 2>/dev/null | grep -q "$D.*available"; then
  xcrun devicectl device install app --device $D "$T/iphone/Lightly.app" 2>&1 | grep -iE "installed|error" | head -2
  xcrun devicectl device info apps --device $D --bundle-id com.lightlylabs.lightly --json-output "$T/apps.json" >/dev/null 2>&1
  echo "iPhone 11 Pro Max: $(python3 -c "import json,sys; a=json.load(open(sys.argv[1]))['result']['apps']; print(a[0]['bundleVersion'] if a else 'not installed')" "$T/apps.json")"
else echo "iPhone 11 Pro Max not connected: install pending"; fi
echo "== done $(date +%T)"
