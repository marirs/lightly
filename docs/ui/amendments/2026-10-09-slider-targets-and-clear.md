# Slider targets and clear actions — 9 October 2026

Owner requests: remove the Border signature option; fix dragging one slider changing the next; add quick signature and preset clearing and a way to replace/delete a saved drawing.

## Implementation

- Removed “Signature on the margin” from the Polaroid Border panel on both platforms. Watermark placement remains free on the canvas. Existing recipes remain readable.
- iOS PanelSlider and ApprovedSlider use a bounded 44-point track gesture area. Removed the negative 20-point content-shape inset that overlapped adjacent rows. Android already bounds each track to its 44-dp row.
- A compact × beside the preset Amount action clears only the applied Look, preserving Auto, other tools, favourites and the browsed category. One Undo restores it.
- Signature Clear removes the applied signature while keeping the saved drawing. One Undo restores it.
- The drawn signature has a ⋯ menu for Draw replacement and Delete saved signature. Deletion requires confirmation in the app, removes the saved drawing, and clears it from the current photo if applied. Draw replacement opens the existing pad; Cancel preserves the saved drawing.
- Clearing the drawing pad also resets its in-progress stroke flag.

## Evidence

Before the iOS hit-target fix, a drag inside the Intensity row (10 pt below its centre) changed Rotation from 0 to 71. The same adjacent-row test passes after the fix, including a drag that verifies the intended slider actually moves.

Android editor tests cover both sliders independently, the missing Border switch, clear preset/Undo with other tools unchanged, clear signature/Undo with saved drawing retained, and deletion of the drawing.

Focused iOS UI screenshots of the preset and signature controls were visually inspected. No approved references were modified. Full device/theme matrices were not repeated.

Evidence: ~/.codex/artifacts/lightly/v1/slider-clear-2026-10-09/.
