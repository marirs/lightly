# Slice 3 on iOS: Background and Portrait

Reference: the approved prototype `docs/ui/app/` (`backgroundPanel`, `portraitPanel`, `marksFor`, the `bg-*` and `pt-*` screens), rendering contract v2 stages 7–9, edit recipe v1 (`tools.background`, `tools.portrait`), and the refocus specification in `docs/v1/depth-evaluation.md` §6 with its reference `experiments/depth/refocus.py`.

Status: **in progress.** The sections below are written as the work lands; anything not marked working is not claimed.

## Depth model

| Item | Value |
|---|---|
| Model | Depth Anything V2 Small, Apple's Core ML package `DepthAnythingV2SmallF16P8.mlpackage` (8-bit palettised, 518 × 392 input) |
| Official source | https://huggingface.co/apple/coreml-depth-anything-v2-small, revision `cfef6f6f2a70783dedc0bfae40cecbc2052285d3` |
| Licence | Apache-2.0 (code and weights; model card). Training-data note: pseudo-labels of datasets with research-only terms (depth-evaluation.md T1) |
| SHA-256 | `Data/com.apple.CoreML/weights/weight.bin` = `660a57cf7becfeac080a9bb02a263be59fd57b5c4d17ff8912833bc8b6edae04` (matches `experiments/depth/MODEL_SOURCES.csv`) |
| Download | none in this slice: the package was already fetched for the depth evaluation (`experiments/depth/models/apple_coreml_da2_small`, git-ignored); its hash was re-checked |
| Bundling | `ios/Tools/bundle_depth_model.sh` (LookPack aggregate target) verifies the hash, compiles with `coremlcompiler` and copies `DepthAnythingV2SmallF16P8.mlmodelc` into the app. A wrong hash fails the build |
| **Release gate** | **"pending legal sign-off (training data)"**: build setting `LIGHTLY_DEPTH_MODEL_TRAINING_DATA_SIGNED_OFF` (default `NO`). Release builds bundle and load the model only when it is `YES`; Debug builds always do, for development. With the gate closed, photos without embedded depth show the approved "Couldn't separate the subject" state in Background (never a mask-only blur) |
| "Focus depth" | depth of field (decision T3), as the specification defines it |

## Contract (rendering-v2 revision 1, contract fixes 1)

The first port's gaps (max radius 0.03 vs 0.035, swirl half-angle, `replacementDepth`, subject-matte depth) were resolved upstream by rendering-v2 revision 1 (fea63fb, docs/v1/contract-fixes-1.md). Ported on iOS:

- **Focus & Blur:**
  - R_max = 0.06 of the long edge;
  - h = 0.5·focusDepth/100;
  - CoC scaled by max(d_f, 1 − d_f) − h;
  - the subject plane is held sharp when the focus is on it (M(target) ≥ 0.5, or a null target with a subject).
- **Pull-push:** pulls to 1×1 with an exact 2×2 mean and pushes back half-pixel bilinear, so large holes no longer fill toward black.
- **No depth means no blur (§R8).** `BackgroundStage` no longer builds a two-plane blur from the matte. The codec rejects `blur > 0` with `depth.source = subject-matte`.
- **Stored focal plane.** A tap stores `depth.focusDepth = 1 − d_f`, and rendering uses the stored value (G4). `replacementDepth` is not read; replacements use §R2.4 "plane" placement (G6).
- **Matching the reference's numerical details.** These were needed for the golden tests:
  - kernels are convolved (flipped), with numpy-reflect borders;
  - morphology uses OpenCV's elliptic element;
  - medians follow numpy;
  - the glow Gaussian uses BORDER_REFLECT_101.
- **Grain:**
  - lightness changes keep chromaticity (a and b scale with L);
  - when there are fewer than 2 pixels per grain cell, the grain is supersampled and box-averaged.
  - The grain constants are unchanged and still uncalibrated (M9 stays a deviation).
- **Contract check.** `DevelopModel` refuses a contract whose revision is not 1 or whose focus constants differ from the renderer's.
- **Tests.** `RenderingGoldenTests` checks against `shared/fixtures/rendering`: constants, signed CoC, highlights, ten kernels, pull-push, nine whole renders (ΔE00 mean ≤ 1, p99 ≤ 4) and four grain cases.

Still open (owner decisions, contract-fixes-1 §1):
- the tablet blur strength differs from the prototype, whose blur is in CSS pixels;
- the styles' textures differ from the prototype's single Gaussian;
- the prototype's subject-edge halo.

Portrait's operators are still provisional, because the contract gives no equations for them.

## What is built

**Background** (`Features/Background`, `ImageEngine/Background`), the approved `backgroundPanel`:
- Subject separation with Vision `VNGenerateForegroundInstanceMaskRequest` (all instances, soft matte), once per photo, cancellable ("Finding the subject…" with Cancel; Cancel leaves the recipe untouched and shows "Cancelled · nothing changed"). States: separating, failed ("Couldn't separate the subject." with Try again), no clear subject (depth-only blur with the approved notice), ready.
- Depth: the photo's embedded disparity or depth (`AVDepthData`, oriented, §R2.1 normalisation) when present; otherwise Depth Anything V2 Small behind the release gate. Depth is never faked from the matte (§R8): without depth, Background shows the failed state.
- Focus & Blur: the four styles (Lens with round, hex, heart and star bokeh; Soft with Glow; Swirl; Motion with Direction), Blur, Focus depth (depth of field), tap the photo to set focus (the focus ring mark), Refine edges (Add/Remove brush, Brush size, the blue subject tint, one undo step per stroke).
- Change background: the four approved bundled images (Unsplash, from `docs/ui/assets/photos`), the eight swatches, the four gradients, Scale, drag the photo to position, Remove background change. Focus & Blur keeps working on the new background (§R2.4 placement).
- Renderer: a CPU port of §R1–§R6 (`RefocusRenderer`): highlight expansion and compression, two planes with pull-push fill and a de-contaminated subject, guided-filter disparity, signed CoC with K tent layers per side (4 while a control moves, 8 for the settled frame and export), the five kernels, far-to-near "over" then pull-push, front layers summed. §R7 latitude: layers are gathered at reduced resolution (radius ≥ 6 px there) and upsampled.
- Working resolution: Focus & Blur runs at 640 px (moving), 1,024 px (settled preview) or 2,048 px (export) on the long edge and is merged into the full-resolution frame by a defocus weight, so in-focus detail stays at full resolution. Replacement compositing is at full resolution.
- Recipe: every edit is one undo step through `EditRecipe.tools.background`; the first edit records the matte and depth map as `derivedRef`s (SHA-256 of the float data, model id and version, size).

**Portrait** (`Features/Portrait`, `ImageEngine/Portrait`), the approved `portraitPanel`:
- Vision face landmarks plus face capture quality and human rectangles. A face is usable when it is at least 5 % of the frame, has eye and lip landmarks and capture quality ≥ 0.2; otherwise the approved "No face can be edited in this photo." notice shows. People without a usable face get the dim rings. Faces are ordered left to right ("Face 1, 2, 3"), each with its own settings and a change count on its chip (`Face 2 · 3`).
- Multi-face is tested on `experiments/test-photos/group_three_01.jpg` (three usable faces, left to right).
- Tabs and controls exactly as approved: Skin (Smoothing, Blemishes, Even tone, Keep texture), Under-eye, Eyes, Teeth, Hair & Beard, with the approved notes.
- Operators: provisional (contract gap 4). They change OKLab lightness, or pull chroma toward its own local mean, so eye colour and skin tone are kept; nothing moves geometry. Teeth are capped at L 0.92 and at most 40 % of the way there. Only pixels an operator changed are written back.

## Deferred (marked in code)

- `AddBackgroundButton` ("Choose a photo" in Change background › Image): DEFERRED; the prototype's control is a no-op too.
- Export memory: Background and Portrait hold several full-resolution float planes during export. Not yet measured on a device (simulators only in this slice).

## Simulator limits (blockers for verification here)

- **Subject matte.** `VNGenerateForegroundInstanceMaskRequest` fails in the iOS Simulator ("Could not create inference context", Vision code 9), on the default devices and on the CPU. `SceneAnalysisTests.testSubjectMatteCoversThePerson` therefore skips in the Simulator; it needs a device. For development captures only, DEBUG Simulator builds may load the matte the same request computes on macOS 14 (`ios/Tests/Fixtures/SubjectMattes`, regenerated by `ios/Tools/make_subject_matte_fixtures.swift`; recipes record the model as `macos-fixture`). The device path never uses them.
- Face landmarks, capture quality, person segmentation and the depth model do run in the Simulator, on the CPU.

## Comparison (development cell: iPhone 17, portrait, light, default text)

The 21 slice-3 screens were captured with the one-launch runner from the build at \`420f429\`. They took two launches, one for the Background screens and one for the Portrait screens; see "Runner findings" below.
- **References.** All come from \`scripts/reference_cache.py\` (\`auto-unavailable\`).
- **Mattes.** Every Background capture used the macOS-computed matte fixture (DEBUG Simulator only). Each capture's JSON record says so (\`subjectMatte\`). Verifying the matte on a device is pending, on dev devices only.
- **Review.** Every screen was reviewed side by side.

| Screen | Result |
|---|---|
| \`bg-focus\`, \`bg-soft\`, \`bg-swirl\`, \`bg-motion\` | S1, S2, S3 |
| \`bg-refine\` | S2 (the tint follows the real matte; the prototype tints its illustration ellipses) |
| \`bg-change-image\`, \`bg-change-colour\`, \`bg-change-gradient\` | S2 |
| \`bg-replaced-blur\` | S1, S2, S3 |
| \`bg-separating\` | V |
| \`bg-failed\` | M9 (the approved setup applies Portrait 13 "Glow") |
| \`bg-no-subject\` | V |
| \`pt-skin\`, \`pt-under\`, \`pt-eyes\`, \`pt-teeth\`, \`pt-hair\`, \`pt-landscape-photo\` | P1 |
| \`pt-multi\` | P1, P2 |
| \`pt-no-usable-face\` | P3 (blocker for this screen) |
| \`pt-hidden\` | V |

Deviations (expected / observed / cause):
- **S1. Blur strength and texture.**
  - The prototype draws one CSS Gaussian in CSS pixels. Revision 1 calibrated the strength to it.
  - On iPhone 17 the native result is about 19 % weaker, and Lens, Soft, Swirl and Motion keep their own textures.
  - These are owner decisions listed in contract-fixes-1 §1 (the conflicts on the tablet blur strength and on the styles).
- **S2. Subject edge.** The prototype masks the subject with soft ellipses ("illustration only"), which leaves a blurred halo of the old background (red arrow, wall slats) around the hair and shoulder. The native matte has no halo (contract-fixes-1 §1, conflict 3).
- **S3. Focus point.**
  - With no tap, the approved screens use the prototype's fixture point (0.40, 0.48) on the face. Native focuses on the centre of the detected face (0f8cc0c).
  - So the ring sits a few points lower and to the right of the approved one. Its size and look match.
- **P1. Face ring geometry.**
  - The prototype's ring comes from its photo data (for the man, 0.22 × 0.25 of the photo). Native uses the detected face box, extended for the forehead (420f429).
  - The native ring is about 1.3 times wider. Its shape and style match.
- **P2. Multi-face photo.** The approved \`pt-multi\` shows the one-face photo of the man. The prototype itself notes that no licensed multi-person photo was available. Native shows the licensed group photo \`experiments/test-photos/group_three_01.jpg\`, with three faces, three rings, "Face 1 · 1" and the note.
- **P3. People found, but no usable face.**
  - Approved: the Portrait tool is listed, the notice shows, and dim rings mark the people at the bar.
  - Native, in the Simulator: Vision finds no person in this dark photo, so the Portrait tool is hidden and no rings are drawn. The notice still shows only because the capture forces the tool open.
  - This has not been checked on a device. It is a detection limit, not a layout change. Device check pending.

Fixed during this review (all re-reviewed):
- **Panel height.** A 4 pt bottom padding made the photo shorter (0f8cc0c).
- **Focus ring.** It was at the matte centroid on the shoulder (0f8cc0c).
- **Landmark-based ring.** In the Simulator it moved between runs (420f429).
- **Simulator face analysis.**
  - Face capture quality is unreliable there; one run marked a clear face as unusable (10317d5).
  - A failed analysis is now retried (5489d4c).

## Runner findings during slice 3 (tooling)

- **Readiness was too early.**
  - Three facts measured in the first slice-3 run:
    - two main-queue turns after the render did not guarantee that a tool switch was on screen;
    - \`pt-eyes\` was photographed with the Develop panel;
    - the face rings were missing.
  - Since 792868d (tool version 5), readiness is reported from the ready marker's own render pass, followed by three display refreshes.
  - The slice-2 runner captures were taken with the earlier signal. Their equivalence with the launch-per-screen path was measured, and all 504 were reviewed with the correct states, so they are kept. Re-checking one cell with version 5 is pending (the lock was busy).
- **Untracked person segmentation.** The task stayed untracked and re-rendered after "ready" (10ce7d2, ce0221f).
- **Simulator render server stall.** After about 18 heavy screens in one launch, the app's Core Animation commit to the Simulator render server blocked. The app's main thread was waiting in \`mach_msg\` at 0 % CPU, and the screenshot timed out.
  - Seen with the full 21-screen slice-3 list, three times.
  - Not seen with 12 or 9 screens per launch.
  - Slice-3 cells are therefore captured as two launches: Background, then Portrait.

## Status

**Working**, verified by unit tests and the iPhone 17 runner cell:
- Background: subject separation states; Focus & Blur, with all styles, bokeh shapes, Blur and Focus depth (revision-1 renderer, parity goldens); tap to focus, stored as \`focusDepth\`; Refine edges; Change background (image, colour, gradient, Scale, drag to position, Remove); blur after replacement; no blur without depth.
- Portrait: face detection with left-to-right Face N chips and rings, five tabs with the approved controls and notes, per-face settings and change counts.
- Unit tests: \`RenderingGoldenTests\` (8), \`BackgroundRenderingTests\` (12), \`PortraitRenderingTests\` (5), \`SceneAnalysisTests\` (5; the matte test skips in the Simulator).

**Experimental**:
- The Portrait operators are provisional: the contract gives no equations for them.
- Depth Anything V2 Small is behind the release gate, pending legal sign-off (training data).

**Blockers and pending items**:
- The subject matte and \`pt-no-usable-face\` (P3) need a dev device: Vision's foreground mask and person detection are unreliable or unavailable in the Simulator.
- Owner decisions: S1, plus the tablet blur strength, the styles and the subject edge (contract-fixes-1 §1); P2, the multi-face photo substitution.
- The slice-3 matrix beyond the iPhone 17 cell is pending, and so is the slice-2 re-check with capture tool version 5.
- Export memory has not been measured on a device.
- "Choose a photo" (the + in Change background) is deferred; the prototype's control is also a no-op.
