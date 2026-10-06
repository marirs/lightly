# Lightly 1.0: remaining work (single list, updated 2026-10-06)

The one list of what stands between the current builds and release. Items leave this list only with recorded evidence;
nothing here is "done". Row-level status lives in `implementation-checklist.md`; this list replaces its former
"What remains unverified" section.

Build on the review devices: **0c45e50, 1.0.0 (261005066)** (review simulator, review emulator, iPhone 11 Pro Max).
1.1 (not 1.0): Eraser.

## iOS

### Functional defects
1. **Change background hair edges: red spill.** Release blocker. Confirmed with live Vision on the iPhone 11 Pro Max
   (experiments/depth/results/portrait-edges-2026-10-05/). Not fixed.

### Unverified on the physical device (iPhone 11 Pro Max)
The Mac cannot launch the app on this phone (developer disk image unavailable over the network), so each item needs the
owner to run it; the DEBUG trace (`Documents/save-trace.log`, launch line names the build) is read back afterwards.
2. **Background stall reported by the owner.** Code fix: subject outline and depth independent (5df8bea), Cancel returns
   to the panel and ignores late results (7b7c56d). No trace from 261005066 yet (file unchanged since 2026-10-05 16:23,
   i.e. the app has not been opened since install).
3. **Ordinary Save copy to Photos:** the saved image and the unchanged original, on the phone.
4. Free crop, Straighten then crop, ruler header and Cancel on the phone (Simulator-verified: crop edges, content and
   orientation of the saved file match the on-screen frame).
5. Camera flows, first-save Photos permission, restore after force-quit, 48 MP memory/time, VoiceOver pass,
   `pt-no-usable-face` on the bar photo.

### Unfinished features
6. **Auto** (D1): no model ships; the approved unavailable state ships. Unfinished requirement.
7. **Gated models** (counsel sign-off, legal-proposals §3.5): depth (Focus & Blur), LaMa (Remove). With the gates closed,
   a release build shows the failure states.
8. Grain (M9) and vignette (G2) calibration: needs Lightroom references.

### Owner decisions (iOS-specific)
9. M2 iPad status-bar offset; M4 SF text metrics; P1 Portrait ring proportion; slice-1 #1 More pages inside the sheet.

## Android

### Functional defects
1. **Change background hair edges: teal cast and grey haze.** Release blocker. Not fixed.
2. **Object cut-out (U²-Netp):** halo reduced, not fixed; the no-subject rule fails held-out photos (4/9 and 10/29).
   Experimental, behind the vision gate.
3. Portrait: a face ring is drawn on the disco ball (`pt-no-usable-face`).
4. Blur glow at 768 px after replacement (`bg-replaced-blur`, checks-2026-10-04).

### Unverified on a physical device
5. **No physical Android device has run any build.** Everything is emulator-only: performance, LiteRT delegates and
   model timing, gesture navigation on real hardware, Save copy to the gallery. Emulator-verified 2026-10-05: ruler
   header/cancel/Undo/Redo, free crop (edges match the saved file), Background Cancel → reopen → retry.

### Unfinished features
6. **Auto** (D1), as iOS.
7. **Gated models**, as iOS, plus U²-Netp object cut-out (experimental).
8. Grain (M9) and vignette (G2) calibration, as iOS.

### Owner decisions (Android-specific)
9. Splash mark ≈24 dp higher (slice-1 #8); Fold inner Welcome centred (slice-1 #6); LensModel and picked-photo GPS
   (`ACCESS_MEDIA_LOCATION`).

## Unverified on both platforms (carried over from the checklist, 2026-10-05)
- Storage full and export failed: implemented as alerts, never run under a forced condition.
- Lost photo access and model-unavailable mid-session: unit-tested only.
- Large text: one cell per platform; every other cell unverified. Screen readers: no end-to-end pass. 44 pt targets not
  measured across layouts.
- Saved-file metadata combinations on Android after slice 1; 48 MP memory and time on dev devices.
- Tablet and Fold cells of the sized screens: one iOS check (iPad 13 landscape) only.

## Owner decisions (both platforms)
1. **Depth-failure message: provisional, not approved.** Installed: "Couldn't measure depth. Blur needs it. Change
   background still works." Candidate: "Couldn't estimate depth. Try again to use Focus & Blur." Unchanged until chosen.
2. **Preset names:** `release/preset-name-proposal.md` (variant numbers bound to ids; category line in Favourites).
3. **Legal:** Terms clause replacement; Licences row (option A) or Terms notices (option B); operator, minimum age,
   pricing, bundled background photos (`release/legal-proposals.md`).
4. W1 watermark/blur sizing policy; S1 blur strength; S3 default focus; E1 straighten zoom; E2/Q1 perspective;
   P2 multi-face photo; F1 substitute Film preset; Selective Colour overlay; ruler fine-mode timing; About version scheme.
5. No store submission until the owner says so.
