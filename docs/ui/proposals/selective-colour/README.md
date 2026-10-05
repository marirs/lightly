# Proposal: Effects › Selective Colour (not approved)

Requested by the owner on 2026-10-04 as an addition to the approved UX. Nothing here is approved. The approved prototype in `../../app/` is unchanged: this page loads it as it is and adds one Effects tab and its states (`proposal.js`).

Open it from the repository root server (`python3 -m http.server 8765`) at http://127.0.0.1:8765/docs/ui/proposals/selective-colour/index.html. The proposed screens are under **Effects** in the Screen index, named `PROPOSAL · Selective Colour · …`.

## Panel (Effects › Selective Colour), one panel

```
Light Leaks   Grain   Vignette   Selective Colour •
[eyedropper] [brush] [eraser] │ ●  ●  ●          Clear
Range       ───────●──────────  40
Strength    ─────────────────●  100
Brush size  ──────●───────────  40     (only with the brush or eraser)
```

- The three tools set what a touch on the photo does: the eyedropper picks a colour to keep; the brush paints the area where kept colours stay; the eraser removes from that area. No separate page.
- No On switch: picking a colour applies the effect; tapping a dot removes that colour; Clear removes colours and painted area.
- Colour matching is the default: the picked colours stay wherever they appear in the photo. It does not know what an object is: picking a red dress also keeps red lips. Painting an area is manual refinement: once painted, only the picked colours inside it stay in colour. The app does not find the dress or the balloon.
- The blue overlay (Background › Refine's tint) shows for a moment after a pick, while Range is dragged and while painting; otherwise the result is shown.

Screens under **Effects** in the Screen index: `fx-selective-empty`, `fx-selective-picked`, `fx-selective-overlay`, `fx-selective-multi`, `fx-selective-area-painting`, `fx-selective-area`, `fx-selective-area-remove`, `fx-selective-leak`.

## Proposal 2: no On/Off switch on Light Leaks, Grain and Vignette

Owner, 2026-10-05. Changes approved screens, so it needs explicit approval before the apps change. Each effect is on while its main slider (Light Leaks Intensity, Grain Amount, Vignette Amount) is above 0; dragging it to 0 turns it off; choosing a style while it is at 0 starts it at the approved default. Screens: `fx-noswitch-leak-off`, `fx-noswitch-leak-on`; every approved Effects screen on this page also shows the panels without the switch.

## Behaviour (both platforms)

- Picks and painted dabs are stored in photo coordinates (fractions of the photo), so resizing or rotating the editor does not move them.
- Range: how far neighbouring shades are included (a colour distance). Strength: 100 makes everything outside the selection black and white; 0 leaves the photo unchanged.
- Pipeline order: Develop and Edit adjustments, Light Leaks, **Selective Colour**, Grain, Vignette.
- Undo/Redo: a pick, a colour removal, a painted stroke and Clear are one step each; one slider drag is one step.
- Compare shows the original; preview and Save copy use the same renderer; the session restores picks, area and values.

## Decisions needed

1. Selective Colour: the one-panel design above (fourth Effects tab; eyedropper, brush, eraser; dots; Range, Strength, Brush size).
2. Defaults: Range 40, Strength 100.
3. Order in the pipeline: after Light Leaks, before Grain and Vignette.
4. Proposal 2: remove the On/Off switch from Light Leaks, Grain and Vignette.

Photo appearance on this page is an in-browser illustration (canvas, Lab colour distance), like the rest of the prototype's CSS simulations; it is not the native renderer.
