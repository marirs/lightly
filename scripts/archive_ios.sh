#!/bin/bash
# archive_ios.sh: the iOS Release archive of the committed checkpoint (HEAD, tracked tree clean), with the real version
# and build number (scripts/version.sh) and automatic signing for team 3UDFB78DLC, into
# ~/.codex/artifacts/lightly/v1/archives/<commit>/Lightly.xcarchive; then lists what the app contains (models, gates).
# Distribution signing and the App Store export (exportArchive) are a separate, explicitly approved step: Xcode may
# create a distribution certificate or profile in the developer account.
# GATES=open: the same Release archive with both model sign-off gates set to YES, into archives/<commit>-gates-open/, for
# the device check of Focus & Blur and Remove in the shipping configuration. Internal only: never submitted while the
# training-data sign-off (owner decision D-3) is open.
# Run through the lock: scripts/heavy ios-archive bash scripts/archive_ios.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO"
[ -z "$(git status --porcelain --untracked-files=no -- ios shared version.properties)" ] || { echo "refusing: tracked changes in ios/ or shared/"; exit 2; }
C=$(git rev-parse --short=7 HEAD); read -r MARKETING BUILD_NUMBER < <(bash scripts/version.sh)
GATE_SETTINGS=""; SUFFIX=""
if [ "${GATES:-closed}" = open ]; then
  GATE_SETTINGS="LIGHTLY_DEPTH_MODEL_TRAINING_DATA_SIGNED_OFF=YES LIGHTLY_REMOVE_MODEL_TRAINING_DATA_SIGNED_OFF=YES"; SUFFIX=-gates-open
fi
OUT=$HOME/.codex/artifacts/lightly/v1/archives/$C$SUFFIX; A=$OUT/Lightly.xcarchive; rm -rf "$A"; mkdir -p "$OUT"
echo "== archive $C$SUFFIX $MARKETING ($BUILD_NUMBER) $(date +%T)"
(cd ios && xcodegen generate >/dev/null) || exit 1
xcodebuild archive -project ios/Lightly.xcodeproj -scheme Lightly -configuration Release -destination "generic/platform=iOS" \
  -archivePath "$A" -allowProvisioningUpdates MARKETING_VERSION="$MARKETING" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=3UDFB78DLC $GATE_SETTINGS -quiet > "$OUT/archive.log" 2>&1 \
  || { grep -E "error:" "$OUT/archive.log" | head; echo "archive failed"; exit 1; }
grep -E "warning: .*(model|gate)" "$OUT/archive.log" | sort -u
APP=$A/Products/Applications/Lightly.app
echo "version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")), $(du -sh "$APP" | cut -f1)"
codesign -dvv "$APP" 2>&1 | grep -E "^Authority=|^TeamIdentifier" | head -2
plutil -p "$APP/Info.plist" | grep -E "SignedOff"
echo "models in the app: $(find "$APP" \( -iname '*.mlmodelc' -o -iname '*.mlpackage' -o -iname '*.tflite' \) | sed "s#$APP/##" | tr '\n' ' ')"
echo "bundled background photos: $(ls "$APP" | grep -E '^(backlit|landscape|sunset|wellexposed)_[0-9]+\.jpg$' | tr '\n' ' ')"
echo "== done $(date +%T)"
