#!/bin/bash
# Live-Vision saved copies on the iPhone 11 Pro Max (dev device): both portraits × light/dark, each saved to Documents
# (--save-to-documents), polled up to 150 s, then copied back. Photos must already be in Documents.
D=4C50E425-9BEA-58DB-9D5E-2BF46A9F0A6C; B=com.lightlylabs.lightly; OUT=/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/out/portrait-edges-2026-10-05/device
for p in pm02_12mp:pm02 pd03_full:pd03; do for sc in dark light; do
  photo=${p%%:*}; tag=${p##*:}; f=live-$tag-$sc.jpg
  xcrun devicectl device process launch --device $D --terminate-existing $B --open-photo $photo.jpg --scenario bg-colour-$sc --save-copy --save-to-documents $f 2>&1 | grep -iE "error" | head -2
  ok=0; for i in $(seq 1 15); do sleep 10
    xcrun devicectl device info files --device $D --domain-type appDataContainer --domain-identifier $B --subdirectory Documents 2>&1 | grep -q "$f" && { ok=1; break; }; done
  if [ $ok = 1 ]; then sleep 3; xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $B --source Documents/$f --destination $OUT/$f 2>&1 | grep -i error; echo "$f after ~$((i*10)) s"; else echo "$f: no saved file within 150 s"; fi
done; done
