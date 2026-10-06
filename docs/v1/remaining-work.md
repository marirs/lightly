# Lightly 1.0: remaining work (single list, updated 2026-10-06)

The one list of what stands between the current builds and release. Items leave this list only with recorded evidence;
nothing here is "done". Row-level status lives in `implementation-checklist.md`; this list replaces its former
"What remains unverified" section.

Build on the review devices: **0c45e50, 1.0.0 (261005066)** (review simulator, review emulator, iPhone 11 Pro Max).
1.1 (not 1.0): Eraser.

## iOS

### Functional defects
1. **Change background hair edges: red spill.** Release blocker. Confirmed with live Vision on the iPhone 11 Pro Max
   (experiments/depth/results/portrait-edges-2026-10-05/). Not fixed. At the red pixels the Vision matte is 1.0 (fully
   subject), so no compositing rule can change them; a fix needs a different matte, not a colour correction.

### Unverified on the physical device (iPhone 11 Pro Max)
The Mac cannot launch the app on this phone (developer disk image unavailable over the network), so each item needs the
owner to run it.
Log destination and retrieval: DEBUG builds append to the app container's `Documents/save-trace.log`
(`DiagnosticTrace`, also os_log category "Diagnostics"); retrieved with `xcrun devicectl device copy from --device
4C50E425-9BEA-58DB-9D5E-2BF46A9F0A6C --domain-type appDataContainer --domain-identifier com.lightlylabs.lightly
--source Documents/save-trace.log`. 261005066 writes `launch: Lightly 1.0.0 (261005066)` at every start. The file has
been 0 bytes since 2026-10-05 16:23; that shows only that nothing was recorded, not whether the app was used. If the
launch line is still missing after the owner opens the app, logging is diagnosed before anything else.
2. **Background stall reported by the owner.** Code fix: subject outline and depth independent (5df8bea), Cancel returns
   to the panel and ignores late results (7b7c56d). Unverified on the phone until a trace from 261005066 exists.
3. **Ordinary Save copy to Photos:** the new Photos item itself (its original file, not a Share export) and the
   unchanged original. Earlier device runs of the DEBUG save-to-Documents path (273c5e6) produced no file within 150 s
   (portrait-edges README); not diagnosed.
4. Free crop, Straighten then crop, ruler header and Cancel on the phone (Simulator-verified: crop edges, content and
   orientation of the saved file match the on-screen frame).
5. Camera flows, first-save Photos permission, 48 MP memory/time, VoiceOver pass, `pt-no-usable-face` on the bar photo
   (the Simulator's Vision finds no person there, P3).
6. **Restore after system termination** (memory pressure, background kill): implemented (R1 88973a6, R2 fix c230f28)
   and Simulator-tested (`testTheSessionComesBackAfterTheSystemEndsTheApp`); not run on the phone.
   **User force-quit** (swiped away in the app switcher): the session is discarded by design, as the platform does;
   whether to keep it is owner question W9.

### Unfinished features
7. **Auto** (D1): no model ships; the approved unavailable state ships. Unfinished requirement.
8. **Gated models** (counsel sign-off, legal-proposals §3.5): depth (Focus & Blur), LaMa (Remove). With the gates closed,
   a release build shows the failure states.
9. Grain (M9) and vignette (G2) calibration: needs Lightroom references.

### Owner decisions (iOS-specific)
10. M2 iPad status-bar offset; M4 SF text metrics; P1 Portrait ring proportion; slice-1 #1 More pages inside the sheet.

## Android

### Functional defects
1. **Change background hair edges: teal cast and grey haze.** Release blocker. Not fixed. The teal appears only with the
   foreground-colour estimate. One bounded rule was tested on the recorded stages (2026-10-06): skip the estimate where
   it had to be clipped. `portrait_medium_02` dark: teal 52,733 → 15,211 px, but red excess 1.3 → 7.6 (the red fringe
   returns); not adopted.
2. **Object cut-out (U²-Netp):** halo reduced, not fixed; the no-subject rule fails held-out photos (4/9 and 10/29).
   Experimental, behind the vision gate.
3. Portrait on the bar photo (`pt-no-usable-face`): one dim ring sits beside the middle person's head, over the shelf,
   instead of on the person (emulator, real models, 2026-10-06, `experiments/android-vision/work/bar-ring/`, on disk, not tracked). The
   approved notice is shown. Cause not established (face-box placement). Low impact.

Closed as stale (evidence re-checked 2026-10-06):
- *Ring on the disco ball:* the pose detector's false "person" (recorded as "the lamp", box x 0.29–0.59, y 0–0.18, which
  is the disco ball) got a ring; fixed in 0904c81. Re-run on the emulator with real models: no ring on the ball.
- *Red-pink glow beside the shoulder in a blurred Save copy* (checks-2026-10-04): fixed in e56b907 (rendering-v2
  revision 3; red excess at 10–20 px 18.8 → 0.1 on the device export). Its goldens pass on current code
  (`:core-background:test` 24/24).

### Unverified on a physical device
4. **Historical hardware result (kept):** M2 build 9b1fcd8 passed on two dev phones on 2026-10-02 (Nothing A069,
   Snapdragon SM7635, Android 16; motorola edge 60, MediaTek MT6878, Android 15): picker, a preset, Strength,
   Compare/Undo/Redo/Reset, Save copy (new 3000×2000 JPEG, original sha256 unchanged), no crash or ANR
   (`docs/m2/android-foundation.md` §9.10). **Why it is not sufficient now:** 267 commits since, including every v1 tool
   (Background, Portrait, Edit with Remove, Effects with Selective Colour, Watermark, Border), the 2,591-preset pack and
   ruler, the LiteRT vision models (faces, landmarks, pose, MODNet, U²-Netp, depth) that have never run on hardware,
   tiled Save copy with memory caps, session restore, and the crop-handle gesture exclusion. Renderer still CPU (the GL
   renderer is not wired), so the earlier timing caveat stands.
5. Emulator-verified 2026-10-05: ruler header/cancel/Undo/Redo, free crop (edges match the saved file), Background
   Cancel → reopen → retry. Restore after process death: tested on the emulator (slice 4/5); behaviour after the user
   swipes the app away is not recorded.

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
