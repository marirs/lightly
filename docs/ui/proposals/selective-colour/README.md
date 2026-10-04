# Proposal: Effects › Selective Colour (not approved)

Requested by the owner on 2026-10-04 as an addition to the approved UX. Nothing here is approved. The approved prototype in `../../app/` is unchanged: this page loads it as it is and adds one Effects tab and its states (`proposal.js`).

Open it from the repository root server (`python3 -m http.server 8765`) at http://127.0.0.1:8765/docs/ui/proposals/selective-colour/index.html. The proposed screens are under **Effects** in the Screen index, named `PROPOSAL · Selective Colour · …`.

## What it shows

| Screen | State |
|---|---|
| `fx-selective-empty` | Effects › Selective Colour switched on, nothing picked yet: **Pick** is active, "Tap the photo on a colour to keep it." |
| `fx-selective-picked` | One colour kept (the red arrow), **Matching colours**, Range 40, Strength 100. The lips are red too and stay partly in colour: that is what colour matching does. |
| `fx-selective-overlay` | The temporary blue overlay (Background › Refine's tint) while Range is dragged: what will stay in colour. |
| `fx-selective-multi` | Several colours kept (sky, red door, orange sign), each a removable chip. |
| `fx-selective-area` | **Painted area**, Add brush: the blue tint shows the painted area. One dab caught the lips, so they stay red. |
| `fx-selective-area-remove` | Painted area, Remove brush: the lips are taken back out of the painted area. |
| `fx-selective-off` | Switched off: the photo is in full colour and the picks are kept for when it is switched on again. |

Each panel scrolls like the approved Effects panels; Strength and **Clear selection** are at its end.

## Two different ways to choose what stays in colour

- **Matching colours** (default): every pixel close to a picked colour stays in colour, anywhere in the photo. This is colour matching only. It does not know what an object is: picking a red dress also keeps red lips, a red sign and anything else of that red.
- **Painted area**: the person paints the area, with Add and Remove brushes, where the picked colours may stay in colour. Outside the painted area the photo turns black and white. The app does not find the dress or the balloon: the painting is what limits it.

Not proposed: automatic object selection. The Background subject mask separates a person from the background, but it cannot tell a dress from the person wearing it, or one balloon from several, so it is not offered as "select the dress".

## Behaviour (both platforms)

- Picks and painted dabs are stored in photo coordinates (fractions of the photo), so resizing or rotating the editor does not move them.
- Range: how far neighbouring shades are included (a colour distance). Strength: 100 makes everything outside the selection black and white; 0 leaves the photo unchanged.
- Undo/Redo: a pick, a chip removal, a scope change, a painted stroke and Clear selection are one step each; one slider drag is one step.
- Compare shows the original; preview and Save copy use the same renderer; the session restores picks, area and values.

## Decisions needed

1. A fourth Effects tab named "Selective Colour", after Vignette.
2. The scope labels "Matching colours" and "Painted area".
3. Removing a colour by tapping its chip (a × on the chip).
4. The overlay: the Refine blue tint, shown for a moment after each pick, while Range is dragged, and throughout Painted area.
5. Defaults: Range 40, Strength 100, Matching colours.
6. Order in the pipeline: proposed before Light Leaks, Grain and Vignette, so a light leak's colour sits on top of the black and white.

Photo appearance on this page is an in-browser illustration (canvas, Lab colour distance), like the rest of the prototype's CSS simulations; it is not the native renderer.
