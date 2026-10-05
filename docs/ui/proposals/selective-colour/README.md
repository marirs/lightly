# Proposal: Effects › Selective Colour (not approved)

Requested by the owner on 2026-10-04 as an addition to the approved UX. Nothing here is approved. The approved prototype in `../../app/` is unchanged: this page loads it as it is and adds one Effects tab and its states (`proposal.js`).

Open it from the repository root server (`python3 -m http.server 8765`) at http://127.0.0.1:8765/docs/ui/proposals/selective-colour/index.html. The proposed screens are under **Effects** in the Screen index, named `PROPOSAL · Selective Colour · …`.

## What it shows

| Screen | State |
|---|---|
| `fx-selective-empty` | Effects › Selective Colour, nothing picked yet (no On switch: the effect is active while at least one colour is kept): **Pick** is active, "Tap the photo on a colour to keep it." |
| `fx-selective-picked` | One colour kept (the red arrow), **Matching colours**, Range 40, Strength 100. The lips are red too and stay partly in colour: that is what colour matching does. |
| `fx-selective-overlay` | The temporary blue overlay (Background › Refine's tint) while Range is dragged: what will stay in colour. |
| `fx-selective-multi` | Several colours kept (sky, red door, orange sign), each a removable chip. **Keep** and the **+** (pick another colour) are pinned; only the colour dots scroll, so adding another colour stays in reach. |
| `fx-selective-area-painting` | **Painted area** while painting: drag on the photo to paint a stroke at the Brush size; the blue tint shows the painted area while the finger is down and for a moment after, then the result. |
| `fx-selective-area` | Painted area, Add, the result without the overlay. One dab caught the lips, so they stay red. |
| `fx-selective-area-remove` | Painted area, Remove, the result: the lips are taken back out of the painted area. |
| `fx-selective-leak` | With a Light Leak on: Selective Colour is applied after the leak, so the leak's colour does not come back outside the kept colours. |

Each panel scrolls like the approved Effects panels; Strength and **Clear selection** are at its end.

## Two different ways to choose what stays in colour

- **Matching colours** (default): every pixel close to a picked colour stays in colour, anywhere in the photo. This is colour matching only. It does not know what an object is: picking a red dress also keeps red lips, a red sign and anything else of that red.
- **Painted area**: manual refinement. The person paints the area, with Add and Remove brushes, where the picked colours may stay in colour. Outside the painted area the photo turns black and white. The app does not find the dress or the balloon: the painting is what limits it.

Not proposed: automatic object selection. The Background subject mask separates a person from the background, but it cannot tell a dress from the person wearing it, or one balloon from several, so it is not offered as "select the dress".

## Behaviour (both platforms)

- Picks and painted dabs are stored in photo coordinates (fractions of the photo), so resizing or rotating the editor does not move them.
- Range: how far neighbouring shades are included (a colour distance). Strength: 100 makes everything outside the selection black and white; 0 leaves the photo unchanged.
- Pipeline order: Develop and Edit adjustments, Light Leaks, **Selective Colour**, Grain, Vignette.
- Undo/Redo: a pick, a chip removal, a scope change, a painted stroke and Clear selection are one step each; one slider drag is one step.
- Compare shows the original; preview and Save copy use the same renderer; the session restores picks, area and values.

## Decisions needed

1. A fourth Effects tab named "Selective Colour", after Vignette.
2. The scope labels "Matching colours" and "Painted area".
3. No On switch: picking a colour applies it; removing the last colour or Clear selection removes it.
4. Kept colours as small 28 pt dots in 44 pt touch targets; tapping one removes it (a small × on each), and a **+** dot of the same size picks another.
5. The overlay: the Refine blue tint, shown for a moment after each pick, while Range is dragged, and while painting (gone a moment after each stroke, so the result is visible).
6. Defaults: Range 40, Strength 100, Matching colours.
7. Order in the pipeline: after Light Leaks, before Grain and Vignette (owner's recommendation), so "everything else black and white" holds with a coloured leak on.

Photo appearance on this page is an in-browser illustration (canvas, Lab colour distance), like the rest of the prototype's CSS simulations; it is not the native renderer.
