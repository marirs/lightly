#!/bin/bash
# One live case on the iPhone 11 Pro Max, waiting up to 150 s for the saved copy; then lists recent Lightly crash logs.
D=4C50E425-9BEA-58DB-9D5E-2BF46A9F0A6C; B=com.lightlylabs.lightly; OUT=/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/out/portrait-edges-2026-10-05/device
xcrun devicectl device process launch --device $D --terminate-existing $B --open-photo pm02_12mp.jpg --scenario bg-colour-dark --save-copy --save-to-documents live-pm02-dark.jpg 2>&1 | grep -iE "error|launched"
for i in $(seq 1 15); do
  sleep 10
  xcrun devicectl device info files --device $D --domain-type appDataContainer --domain-identifier $B --subdirectory Documents 2>&1 | grep -q live-pm02-dark.jpg && { echo "saved after ~$((i*10))s"; break; }
done
xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $B --source Documents/live-pm02-dark.jpg --destination $OUT/live-pm02-dark.jpg 2>&1 | grep -i error
xcrun devicectl device info processes --device $D 2>&1 | grep -i lightly | head -2
