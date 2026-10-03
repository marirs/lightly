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
| **Release gate** | **"pending legal sign-off (training data)"**: build setting `LIGHTLY_DEPTH_MODEL_TRAINING_DATA_SIGNED_OFF` (default `NO`). Release builds bundle and load the model only when it is `YES`; Debug builds always do, for development. With the gate closed, photos without embedded depth show the approved "Couldn't separate the subject" state in Background (never a faked mask-only blur) |
| "Focus depth" | depth of field (decision T3), as the specification defines it |

## Contract gaps (reported; `shared/` not edited)

1. **Max blur radius:** rendering-v2.json `maxBlurRadius` 0.03 of the long edge; the refocus specification gives 0.035 [contract]. This port uses 0.035, as the reference renders.
2. **Swirl half-angle:** the specification prose says 6·r·s/diagonal; `refocus.py` uses 12·r·s/diagonal. This port follows the reference code.
3. **`depth.replacementDepth`** (recipe, 0…1, default 1) has no mapping onto the specification's replacement placement (§R2.4: a plane at the old background's disparity, capped behind the subject). Recorded, not used.
4. **Portrait has no equations** in rendering-v2 (parameters and the "never change eye colour or skin tone" rule only). The operators here are this port's provisional ones (see `PortraitRenderer`).
5. **Subject-matte depth source:** the recipe allows `subject-matte` (two planes), but the specification's §R8 says depth must never be faked by a matte. This port uses `subject-matte` only when a recipe records it; new edits record `embedded` or `estimated`, and with no depth the failure state is shown.

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

## Status

Paused at the coordinator's request while the capture runner was measured (committed in 5976127). Working, by unit test: the refocus renderer (identity at blur 0, every style keeps the focused subject sharp and blurs the background, focus depth widens the sharp band, normalised kernels, pull-push, blur after replacement), refine strokes, CSS gradients, replacement positioning, percentile normalisation, three usable faces left to right in `group_three_01.jpg`, depth puts the person in front, and the Portrait operators (identity, eye hue kept, blemish redness reduced with skin tone kept, teeth capped, smoothing). Not yet verified: every slice-3 screen against its reference. The only slice-3 captures so far were taken with the first, unvalidated driver and are marked invalid.
