#!/bin/bash
# package_review.sh: paired review builds from ONE committed checkpoint (HEAD, tracked tree clean), into
# ~/.codex/artifacts/lightly/v1/review-builds/{android,ios}/<commit>/ with SHA256SUMS, then installs them on the review
# emulator (emulator-5554), the review simulator (D75D820D…) and, if connected, the dev iPhone 11 Pro Max.
# Debug configuration (the vision, depth and Remove models are packaged in debug only; release gates unchanged).
# Run through the lock: scripts/heavy package-review bash scripts/package_review.sh   (INSTALL=0: package only)
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO"
[ -z "$(git status --porcelain --untracked-files=no -- ios android shared)" ] || { echo "refusing: tracked changes in ios/, android/ or shared/"; exit 2; }  # docs and other folders do not go into the builds
C=$(git rev-parse --short=7 HEAD); OUT=$HOME/.codex/artifacts/lightly/v1/review-builds; A=$OUT/android/$C; I=$OUT/ios/$C; mkdir -p "$A" "$I"
echo "== checkpoint $C $(date +%T)"
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
(cd android && ./gradlew -q :app:assembleDebug) || { echo "android build failed"; exit 1; }
cp android/app/build/outputs/apk/debug/app-debug.apk "$A/lightly-debug-$C-with-models.apk"
(cd "$A" && shasum -a 256 *.apk > SHA256SUMS && cat SHA256SUMS)
cd ios && xcodegen generate 2>&1 | tail -1
xcodebuild build -project Lightly.xcodeproj -scheme Lightly -configuration Debug -destination "generic/platform=iOS Simulator" \
  -derivedDataPath /tmp/lightly-dd-review-sim -quiet > /tmp/lightly-dd-review-sim.log 2>&1 || { grep -E "error:" /tmp/lightly-dd-review-sim.log | head; echo "ios sim build failed"; exit 1; }
xcodebuild build -project Lightly.xcodeproj -scheme Lightly -configuration Debug -destination "generic/platform=iOS" \
  -derivedDataPath /tmp/lightly-dd-review-device -allowProvisioningUpdates CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=3UDFB78DLC CODE_SIGN_IDENTITY="Apple Development" -quiet > /tmp/lightly-dd-review-device.log 2>&1 || { grep -E "error:" /tmp/lightly-dd-review-device.log | head; echo "ios device build failed"; exit 1; }
cd "$REPO"
SIM=/tmp/lightly-dd-review-sim/Build/Products/Debug-iphonesimulator; DEV=/tmp/lightly-dd-review-device/Build/Products/Debug-iphoneos
(cd $SIM && rm -f "$I/lightly-ios-review-$C-sim.zip" && zip -qry "$I/lightly-ios-review-$C-sim.zip" Lightly.app)
(cd $DEV && rm -f "$I/lightly-ios-review-$C-iphone.zip" && zip -qry "$I/lightly-ios-review-$C-iphone.zip" Lightly.app)
(cd "$I" && shasum -a 256 *.zip > SHA256SUMS && cat SHA256SUMS)
echo "binary sha256 sim $(shasum -a 256 $SIM/Lightly.app/Lightly | cut -c1-16) iphone $(shasum -a 256 $DEV/Lightly.app/Lightly | cut -c1-16)"
codesign -dvv $DEV/Lightly.app 2>&1 | grep -E "Authority=Apple Dev|TeamIdentifier"
# INSTALL=0 packages only: the review devices keep the build the owner is testing.
if [ "${INSTALL:-1}" = 1 ]; then
echo "== install $(date +%T)"
adb -s emulator-5554 install -r "$A/lightly-debug-$C-with-models.apk" | tail -1
xcrun simctl install D75D820D-B43C-4330-8E6F-0FBEB2FA9D02 $SIM/Lightly.app && echo "review simulator D75D820D installed"
if xcrun devicectl list devices 2>/dev/null | grep -q "4C50E425-9BEA-58DB-9D5E-2BF46A9F0A6C.*available"; then
  xcrun devicectl device install app --device 4C50E425-9BEA-58DB-9D5E-2BF46A9F0A6C $DEV/Lightly.app 2>&1 | grep -iE "installed|error" | head -2
else echo "iPhone 11 Pro Max not connected: install pending"; fi
else echo "== not installed (INSTALL=0): review devices keep their current builds"; fi
echo "== done $(date +%T)"
