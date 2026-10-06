# Lightly 1.0: remaining work (single list, updated 2026-10-06)

The one list of what stands between the current builds and release. Items leave this list only with recorded evidence;
nothing here is "done". Row-level status lives in `implementation-checklist.md`; this list replaces its former
"What remains unverified" section.

Not for submission. No limitation listed here is an approved scope cut.
1.1 (not 1.0): Eraser.

## iOS

### Functional defects
1. **Change background hair edges: red spill.** Release blocker until verified on the phone. Cause established with the
   live iPhone matte: the instance mask is a smooth blob at curly hair, so wall between the curls is "subject" (75 % of
   the red pixels: matte ≥ 0.98, passed through unchanged). Fix 21bf473: Vision person segmentation `.accurate`
   refines the matte in the hair zone around faces. App saved copies (Simulator, live instance matte, macOS person
   matte): red 6,120 → 48 (dark), 5,080 → 26 (light); regression portrait unchanged. Promising **fixture** evidence,
   not a device fix: unverified on the phone (live instance + person segmentation, light/dark replacements, hair, ears,
   held objects). Residual: faint dark-teal tint on a few wisps on dark backgrounds. DEBUG builds now keep the three
   mattes and the saved bytes in Documents/evidence (`scripts/iphone_evidence.sh`).
   (`experiments/depth/results/portrait-edges-2026-10-06/`)

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

### Features: technical readiness vs distribution approval
7. **Auto (Core Image auto enhancement):** implemented with image-dependent guards (b16e6e4). Controlled evaluation on
   synthetic degradations of the 12 approved photos (`experiments/auto-ci/eval/eval.txt`; development evidence only):
   24 degraded cases, each in exactly one class by mean ΔE to the original (±0.5): **13 improved, 8 unchanged,
   3 worse** (13 + 8 + 3 = 24). By degradation: −1.5 EV 10 improved, 2 unchanged, 0 worse; warm cast 3 improved,
   6 unchanged, 3 worse (warm light read as a cast; cast undetected). The 12 undegraded originals moved ΔE 0–4.3.
   **Not complete:** not a cast corrector (Core Image proposes no general white balance); low-key vs underexposed is a
   heuristic; CIHighlightShadowAdjust is local (LUT error up to 20/255) and **not applied**, so Auto is the reduced
   Core Image set; real (not synthetic) underexposed/cast photos and the phone unverified. The Auto LUT is identical
   across Save-copy tile boundaries (test, 13.5 MP).
8. **Focus & Blur:** technically ready with the depth model (Debug builds). **Distribution blocked**: the depth model's
   release gate (training-data sign-off, legal-proposals §3.5). Without it, the Release build blurs only photos with
   embedded depth and shows the depth-failure state otherwise. That reduced behaviour is **not approved** and must not
   ship as if it were the feature.
9. **Remove:** technically ready with LaMa (Debug builds). **Distribution blocked**: LaMa's release gate (Places2
   sign-off). In the Release build Remove always fails: a **release blocker**, not a finished feature. Eraser (1.1) does
   not change 1.0's Remove scope.
10. **Release build (checked 2026-10-06):** no ML model bundled (both gates `NO`); Change background, Portrait (Vision)
    and Auto (Core Image) work. Prepared and ready to flip when sign-off arrives: the bundling scripts
    (`ios/Tools/bundle_depth_model.sh`, `bundle_remove_model.sh`, pinned hashes) and the Info.plist gates. Not
    submittable while 8 and 9 stand: a submission must not contain knowingly non-functional controls.
11. **Live preset preview:** fixed on both platforms (drag frames on a reduced base with a coarse LUT; latest-wins with
    forward-only publication; a drag frame no longer waits behind a settled render). Simulator: 57–144 ms to the first
    drag frame. Unverified on the phone (the trace now records "first drag frame visible after N ms").

### Owner decisions (iOS-specific)
12. M2 iPad status-bar offset; M4 SF text metrics; P1 Portrait ring proportion; slice-1 #1 More pages inside the sheet.

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
5. Live preset preview (spare emulator, real touches, 2026-10-06): drag during the initial full render → first drag frame
   after 1,385 ms (was ~23 s); slow drag → 23–208 ms, one frame per stop; continuous fast scrub with reversal →
   42–58 ms, frames every 30–85 ms; release → fast frame after 19–136 ms; Undo → 57 ms; names coherent (LightlyRuler log).
   Emulator-verified 2026-10-05: ruler header/cancel/Undo/Redo, free crop (edges match the saved file), Background
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

## Release configuration: what actually works (checked 2026-10-06)
Built in Release: iOS Simulator Release build (no `.mlmodelc` in the bundle; both gates `NO`); Android
`assembleRelease` (no `.tflite` in the APK; the Debug APK carries depth, LaMa and six vision models).

| Feature | iOS Release | Android Release |
|---|---|---|
| Develop (presets, ruler, Amount, Favourites) | works | works |
| Auto | works (Core Image auto, reduced set: see Auto) | **unavailable** (no model; approved unavailable state) |
| Background › Change background | works (Vision) | **fails for every photo** (no segmenter: approved failure state) |
| Background › Focus & Blur | **only photos with embedded depth**; others: depth failure state | **only photos with embedded depth** |
| Portrait | works (Vision) | **hidden** (no person detection) |
| Edit › Remove | **always fails** | **always fails** |
| Edit (crop, rotate, straighten, perspective, adjust), Effects, Watermark, Border, Save copy | work | work |

None of the bold rows is an approved scope. No submission while any control is knowingly non-functional or a promised
feature is silently hidden. The gates stay closed until the approvals below.

## Submission blockers and the exact approvals that resolve them
Neither scope reduction (Remove failing, Focus & Blur limited to embedded depth) is approved; the register's
"ship without the model" options (dependencies.md items 1B, 2B) are not decisions.

**Established (recorded in dependencies.md, with sources):**
- Depth Anything V2 Small: code Apache-2.0; the Small weights are stated Apache-2.0 by the authors (Base/Large/Giant
  are CC-BY-NC-4.0); Apple's Core ML package is tagged apache-2.0. Training data per the paper: synthetic sets
  (BlendedMVS, Hypersim, IRS, TartanAir, VKITTI 2) and pseudo-labelled real sets including research-only ImageNet-21K,
  SA-1B ("research purposes only") and BDD100K; VKITTI 2 is CC BY-NC-SA, Hypersim CC BY-SA. Several dataset terms were
  not checked (Google Landmarks, LSUN, Objects365, TartanAir, BlendedMVS, IRS).
- LaMa big-lama: code Apache-2.0 (Samsung Research); no separate weights licence upstream; our weights are
  byte-identical to the file the official README links (Hugging Face smartywu/big-lama @ 05cb2be7). Training data
  Places2, whose recorded download terms say non-commercial research and no redistribution of the images (not
  re-verified: the site refused connections).
- Apache-2.0 obligations if shipped: licence text, attribution notices, and a statement that the files were converted.

**Not established (legal interpretation; only counsel can answer; no conclusion is drawn here):**
1. Whether trained weights are an adaptation of their training images, so that NC/ShareAlike or research-only image
   terms could reach the weights through copyright.
2. Whether the model authors had the right to license the weights as Apache-2.0 given that lineage.
3. Whether dataset terms accepted by the authors bind a later user of the weights (on their face they bind the
   downloader).

**Then, to resolve:** counsel's sign-off on 1–3 for each model; then iOS `LIGHTLY_DEPTH_MODEL_TRAINING_DATA_SIGNED_OFF`
/ `LIGHTLY_REMOVE_MODEL_TRAINING_DATA_SIGNED_OFF: "YES"` (ios/project.yml) and Android `-PlightlyDepthLegalSignOff=true`
/ `-PlightlyRemoveLegalSignOff=true`, plus the notices. Android vision models (item 3): the owner's D3 resolution and
counsel on MODNet's (undocumented) and U²-Netp's (DUTS-TR) training data, then `-PlightlyVisionModels=true`.

## Owner decisions (both platforms)
- **Preview that cannot render (proposal, Android; not implemented in the UI):** after the retry fails, a notice over
  the photo: "Couldn't update the preview." with one action, "Try again" (re-requests the current edit). It stays until
  a frame renders; the controls and the edit are unchanged. Needs the owner's approval of copy and placement.
1. **Depth-failure message: provisional, not approved.** Installed: "Couldn't measure depth. Blur needs it. Change
   background still works." Candidate: "Couldn't estimate depth. Try again to use Focus & Blur." Unchanged until chosen.
2. **Preset names:** `release/preset-name-proposal.md` (variant numbers bound to ids; category line in Favourites).
3. **Legal:** Terms clause replacement; Licences row (option A) or Terms notices (option B); operator, minimum age,
   pricing, bundled background photos (`release/legal-proposals.md`).
4. W1 watermark/blur sizing policy; S1 blur strength; S3 default focus; E1 straighten zoom; E2/Q1 perspective;
   P2 multi-face photo; F1 substitute Film preset; Selective Colour overlay; ruler fine-mode timing; About version scheme.
5. No store submission until the owner says so.

## Test infrastructure
- Resolved (33cb001): the order-dependent UI failure was the test's start state, not session leakage. XCUITest's
  terminate() ends the app as the system does, so a plain launch correctly restored the previous test's edit; setUp now
  starts clean (--reset-preferences). The failing pair passes in sequence; the restore test still passes.

## Android memory (checked 2026-10-06, spare emulator, 192 MB heap, 13.5 MP)
- Second render lane: only light frames (no Background/Portrait) run concurrently (da90aa7). Develop-only stress: two
  lanes 130 MB peak heap, 0 OOM; single lane 137 MB, 0 OOM; both saved.
- **Background memory (506a23e), qualified:** three successful exports; no app-observed allocation failures; runtime
  OOM diagnostics remain. The runtime's "Throwing OutOfMemoryError" lines are real throws, not log noise. With thread
  ids (`-v threadtime`) and every catch site logging (below), the same 11 MB allocations show the throwing thread
  continuing at once and its frame publishing: ART's large-object space fails (address-space fragmentation) and ART
  clears the exception and retries in the main space (`art/runtime/gc/heap-inl.h`). That retry is internal; the
  heap is still near its limit: during settled Background frames 186–191 MB of 192 MB stayed in use after GC (after9),
  and a debug comparison render beside them failed outright (11 MB request, 10–11 MB free). With the meminfo sampler
  off (it caused an explicit GC every ~2 s), peak after GC was 175 MB; allocation-triggered GCs 50, 978 ms in total,
  55 ms at most (drag-order run6, 852×1280 proxy).
- **Failures that were masked, fixed (2026-10-06):** (1) the replacement photo's decode was wrapped in
  `runCatching`: an OutOfMemoryError there became "photo unreadable" with no trace, and the frame could render
  without the chosen background. Errors now propagate and fail the render; only an unreadable photo is "no
  replacement", logged. (2) The drag-base prefetch dropped its failures; the prefetch is gone (see Ruler).
- **Preview failure:** the last frame stays while the failed edit is retried once; the retry is the failed request's
  own edit, only when nothing newer was requested, and a newer request or cancel supersedes it. If the retry fails,
  `previewFailed` is set (cleared by the next rendered frame); the edit is untouched (Undo, Redo, Save copy). **Not
  shown: the notice needs approved copy (proposal below).** Until then the stale frame is not marked.
- **Ruler with Background active (2026-10-06):** the cached-composite drag frame (the Look applied after
  the Background composite) previewed a different edit: on release the background's colour and banding and the subject
  edge changed (mean ΔE 4.0–5.9 in the background, 51–75 % of its pixels over ΔE 3; two Looks, 12 MP, replacement +
  blur; `experiments/android-vision/work/drag-order`). Drag frames now keep the pipeline order at the lower working
  resolution (Look on the half-size proxy, then Background at 640 px): to the settled frame, background mean ΔE
  0.45–0.50 (≤ 0.07 % over 3), soft edge 1.8–2.1, subject 0.9–1.6 (the global-only drag plan, as on any drag). Cost on
  the CPU emulator: 3.7–7.2 s per drag frame; one frame appeared during the 13.5 MP sweeps. **Live preview with
  Background active is therefore not complete on the emulator;** device timing unmeasured (no physical Android device).
- **Depth variation explained (A2, 2026-10-06):** preprocessing input, not inference. Two fresh processes with the
  same 1067×1600 display proxy gave identical depth statistics (after8, after9: min 0.318, p50 3.165); the differing
  run had an 853×1280 proxy because the spare emulator's screen was still resized by the drag-order runs (test setup).
  Within a session the analysis is computed once per photo (cached by input-tensor hash) and preview and Save copy
  read the same `BackgroundSession.analysis`. Note: the proxy, and so the depth, follows the screen size (a Fold's
  inner and outer screens give slightly different blur for the same photo).
- Manifest text held for lazy preset parsing: 12.9 MB resident (UTF-16); could be halved with byte offsets (not done).
