#!/bin/bash
# run.sh PHOTO MATTE SCENARIO OUTPREFIX: on the spare iPhone 17, open PHOTO with its macOS Vision matte fixture and a
# debug scenario that also saves a copy; screenshot the preview; copy the newest saved photo.
D=FA7C8278-D0EA-455D-9FAD-5C59014C662F
DCIM=~/Library/Developer/CoreSimulator/Devices/$D/data/Media/DCIM/100APPLE
xcrun simctl boot $D 2>/dev/null; xcrun simctl bootstatus $D -b >/dev/null
xcrun simctl privacy $D grant photos-add com.lightlylabs.lightly 2>/dev/null
xcrun simctl terminate $D com.lightlylabs.lightly 2>/dev/null
before=$(ls -t $DCIM 2>/dev/null | head -1)
xcrun simctl launch $D com.lightlylabs.lightly --open-photo "$1" --subject-matte-fixture "$2" --scenario "$3" --save-copy >/dev/null
sleep 15
xcrun simctl io $D screenshot "$4-preview.png" >/dev/null 2>&1 && echo "preview $4-preview.png"
for i in $(seq 1 60); do
  newest=$(ls -t $DCIM 2>/dev/null | grep -iv "\.plist$" | head -1)
  [ -n "$newest" ] && [ "$newest" != "$before" ] && break
  sleep 2
done
[ -n "$newest" ] && [ "$newest" != "$before" ] && cp "$DCIM/$newest" "$4-saved.${newest##*.}" && echo "saved $4-saved.${newest##*.} after $((15 + i * 2))s" || echo "no saved photo for $3"
