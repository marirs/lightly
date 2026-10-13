#!/bin/bash
# Re-render the 10 kept models on the six test faces (arms splayed, eye-band rim removal).
S=/private/tmp/claude-501/-Users-sg-Documents-Dev-Projects-lightly/e0d1632f-3b15-4845-9a6e-2d74eec5ec54/scratchpad
T=/Users/sg/Documents/Dev/Projects/lightly/experiments/test-photos; P=/Users/sg/Documents/Dev/Projects/lightly/experiments/lut3d/photos
FACES="$P:portrait_deep_02 $P:portrait_medium_01 $P:portrait_medium_02 $T:glasses_side_angle_01 $T:profile_colour_woman_01 $T:profile_bw_woman_01"
cd /Users/sg/Documents/Dev/Projects/lightly
i=0; for d in "$S"/models/*/; do i=$((i+1)); WEAR_TAG=".m$i" $S/venv311/bin/python $S/wear.py $S "${d%/}" x $S/m$i.sheet.png $FACES 2>&1 | grep -v INFO | tail -1; echo "$i $(basename "$d")"; done
