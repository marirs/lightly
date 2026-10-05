# Proposal: Effects › Selective Colour

Requested by the owner on 2026-10-04 as an addition to the approved UX. The approved prototype in `../../app/` is unchanged: this page loads it as it is and adds one Effects tab and its states (`proposal.js`).

Open it from the repository root server (`python3 -m http.server 8765`) at http://127.0.0.1:8765/docs/ui/proposals/selective-colour/index.html. The proposed screens are under **Effects** in the Screen index, named `PROPOSAL · Selective Colour · …`.

## Status (recorded 2026-10-05)

- **Reference the apps implement: this page at commit `330cf5b`**, screens `fx-selective-empty`, `fx-selective-picked` and `fx-selective-multi` (the panel layout below). The owner described this layout ("show the selected colour on top, the controls at the bottom, Clear to the right, a (+) to add another"), asked for a × on each colour when there is more than one, and on seeing `330cf5b` wrote: "Ok this is better.. can you continue the work now". That message is the only acceptance on record: it was taken as approval of the **panel layout** to implement. It is not a visual acceptance of the built apps (not yet given).
- **Not separately confirmed** (implemented as written here, open for the owner): the defaults (Range 40, Strength 100); one Range and one Strength shared by every kept colour (not per colour); at most eight kept colours.
- **Pipeline order:** after Light Leaks, before Grain and Vignette, as the owner's review of 2026-10-04 recommended.
- **In this page, not in the apps:** the temporary blue overlay (after a pick, while Range is dragged). **Removed from the design:** painting an area (the owner's layout has no place for it).
- **Proposal 2 (switches on Light Leaks, Grain, Vignette):** not approved; the apps keep the approved switches.

## Panel (Effects › Selective Colour)

Owner's layout, 2026-10-05:

```
Nothing kept yet:   [eyedropper] Tap a colour in the photo to keep it.

After a pick:       ●  ●  (+)  Clear
                    Range     ───────●────────
                    Strength  ───────────────●
```

- The kept colours sit on top; (+) beside them adds another (tap (+), then the photo); Clear is right beside them. With more than one colour, each has a small × that removes just that colour.
- Below: the controls only.
- No On switch: picking a colour applies the effect.
- Colour matching: the kept colours stay wherever they appear in the photo; it does not know what an object is (a red dress also keeps red lips). Painting an area is not in this layout.

Screens under **Effects** in the Screen index: `fx-selective-empty`, `fx-selective-picked`, `fx-selective-overlay`, `fx-selective-multi`, `fx-selective-leak`.

## Proposal 2: no On/Off switch on Light Leaks, Grain and Vignette

Owner, 2026-10-05. Changes approved screens, so it needs explicit approval before the apps change. Each effect is on while its main slider (Light Leaks Intensity, Grain Amount, Vignette Amount) is above 0; dragging it to 0 turns it off; choosing a style while it is at 0 starts it at the approved default. Screens: `fx-noswitch-leak-off`, `fx-noswitch-leak-on`; every approved Effects screen on this page also shows the panels without the switch.

## Behaviour (both platforms)

- Picks are stored in photo coordinates (fractions of the photo), so resizing or rotating the editor does not move them.
- Range: how far neighbouring shades are included (a colour distance). Strength: 100 makes everything outside the selection black and white; 0 leaves the photo unchanged.
- Pipeline order: Develop and Edit adjustments, Light Leaks, **Selective Colour**, Grain, Vignette.
- Undo/Redo: a pick, a colour removal and Clear are one step each; one slider drag is one step.
- Compare shows the original; preview and Save copy use the same renderer; the session restores picks and values.

## Open decisions

1. Defaults: Range 40, Strength 100 (implemented; not separately confirmed).
2. One shared Range and Strength for all kept colours, or per colour (shared is implemented).
3. The temporary blue overlay (in this page; not implemented in the apps).
4. Proposal 2: remove the On/Off switch from Light Leaks, Grain and Vignette (not approved; not implemented).

Photo appearance on this page is an in-browser illustration (canvas, Lab colour distance), like the rest of the prototype's CSS simulations; it is not the native renderer.
