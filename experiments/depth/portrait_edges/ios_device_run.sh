#!/bin/bash
# Live-Vision edge check on the iPhone 11 Pro Max (dev device): install, copy both photos to Documents, run the
# four replacement cases (save to Documents, dump the live matte), copy the results back.
D=4C50E425-9BEA-58DB-9D5E-2BF46A9F0A6C; S=/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/out/portrait-edges-2026-10-05; OUT=$S/device; B=com.lightlylabs.lightly
dc() { xcrun devicectl "$@" --device $D 2>&1 | tail -2; }
xcrun devicectl device install app --device $D /tmp/lightly-dd-device/Build/Products/Debug-iphoneos/Lightly.app 2>&1 | grep -iE "installed|error" | head -3
for f in pm02_12mp.jpg pd03_full.jpg; do
  xcrun devicectl device copy to --device $D --domain-type appDataContainer --domain-identifier $B --source $S/iosbg/$f --destination Documents/$f 2>&1 | grep -iE "error|copied" | head -2
done
for p in pm02_12mp:pm02 pd03_full:pd03; do for sc in dark light; do
  photo=${p%%:*}; tag=${p##*:}
  xcrun devicectl device process launch --device $D --terminate-existing $B --open-photo $photo.jpg --scenario bg-colour-$sc --save-copy \
    --save-to-documents live-$tag-$sc.jpg --dump-subject-matte live-$tag-matte.png 2>&1 | grep -iE "error|launched" | head -2
  sleep 45
  for f in live-$tag-$sc.jpg live-$tag-matte.png; do
    xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $B --source Documents/$f --destination $OUT/$f 2>&1 | grep -iE "error" | head -2
  done
  ls -la $OUT/live-$tag-$sc.jpg 2>/dev/null || echo "missing live-$tag-$sc.jpg"
done; done
