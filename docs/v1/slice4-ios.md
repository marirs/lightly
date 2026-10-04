# Slice 4 on iOS: Edit, Effects and Remove

Reference: the approved prototype `docs/ui/app/` (`editPanel`, `effectsPanel`, `marksFor`, `toolUsed`, the `ed-*` and `fx-*` screens), rendering contract v2 revision 1 (stages 4, 5, 6 and 10; `shared/contracts/rendering-v2.md`, `.json`), edit recipe v1 (`tools.edit`, `tools.effects`) and `docs/v1/remove-evaluation.md`.

Status: **progress, not accepted.** Built and tested; one cell fully captured and reviewed at the final build, one more captured; the other 22 cells are pending (bulk capture paused by the owner). Deviations need owner decisions; device checks are pending.

## Commits

| Kind | Commit | What |
|---|---|---|
| Tooling | e20fb85 | Capture scripts promoted from the session backup into `ios/Tools/capture/` with configurable paths |
| Code | bc71828 | Edit (geometry, Adjust, Remove), Effects, the LaMa release gate and bundling, tests |
| Tooling | fc46c25 | Build and fingerprint a preflight snapshot (git-ignored models from the main checkout) |
| Code | 6fa497a | `.opt` chips keep the prototype's border-box width (were 2 pt narrower; found in the slice-4 review) |
| Code | d153545 | Floored border widths, as the approved Chromium renders draw them (coordinator request; see below) |
| Code | 08f73a0 | Progress box content centred at its 200 pt minimum width (`bg-separating`, `ed-removing`) |
| Docs | this file | Slice-4 report |

Verification build: `scripts/verify_preflight.py snapshot 08f73a0` → one recorded build (`BUILD_RECORD` = `08f73a0 snapshot`) for unit, UI-flow and capture runs.

## Capture tooling (`ios/Tools/capture/`)

Every path comes from `env.sh` and can be overridden: `LIGHTLY_REPO`, `LIGHTLY_DD_UNIT`, `LIGHTLY_DD_UI`, `LIGHTLY_ARTIFACTS`, `LIGHTLY_TOOLS_BIN`, `LIGHTLY_SHEETS_DIR`, `LIGHTLY_CAPTURE_TOOL`. A snapshot build also needs `LIGHTLY_MAIN_CHECKOUT` (the models and Look pack are git-ignored).

| Script | Use |
|---|---|
| `build.sh unit\|ui\|both` | build-for-testing once per revision; writes `BUILD_RECORD` (revision, local-change fingerprint, or `snapshot`) |
| `capture.sh MODE UDID DEV OR TH TX ONLY OUT` | one runner-v5 batch from the recorded UI build; counts launches; JSON record per PNG (revision, fingerprint, cell, tool version, `subjectMatte`, `faceQuality`, `removeModel`) |
| `cellall.sh UDID DEV OR TH TX root=screens…` | one cell, one launch per group (keep groups ≤ 18 heavy screens: render-server stall) |
| `seqrun.sh label cmd…` | one submission through `scripts/heavy`, one same-label resubmission after BUSY, never more |
| `diff5.sh OLD NEW [rows]`, `pixdiff.swift` | recapture vs reviewed capture |
| `sheets5.sh CELL ROOT screens…`, `compose.swift`, `tile.swift` | JPEG review sheets on demand; references only from `scripts/reference_cache.py` |
| `fingerprint.sh` | revision and local-change fingerprint |

Example: `scripts/heavy capture-ios-<cell> ios/Tools/capture/cellall.sh <udid> iphone17 portrait light default 'slice4/ios/runner5=ed-crop,…' 'slice4/ios/runner5=fx-leak,…'`.

## What is built

**Edit** (`Features/Edit`, `ImageEngine/Edit`), the approved `editPanel`:
- Tabs Crop, Rotate, Straighten, Perspective, Adjust, Remove.
- Crop: Original, Free, 1:1, 4:5, 3:2, 16:9, 9:16 (a fixed aspect takes the largest centred rect; Original resets); the crop frame mark (inset 6 %, darkened outside, corner handles, thirds grid). Drag a corner to crop (keeps a fixed aspect; cropping an uncropped photo makes it Free), pinch to zoom; each gesture is one undo step.
- Rotate: Rotate left, Rotate right (quarter turns), Flip horizontal, Flip vertical.
- Straighten: Angle −45…45 with the approved note; thirds grid.
- Perspective: Vertical and Horizontal −100…100; thirds grid.
- Adjust: Light (Exposure, Contrast, Highlights, Shadows), Colour (Temperature, Tint, Saturation, Vibrance), Detail (Sharpness, Clarity, Noise reduction).
- Remove: Brush size (35), Undo stroke (disabled without strokes), the note; brushing on the photo removes the stroke; "Removing…" over the photo and in the panel with Cancel ("Cancelled · nothing changed"); "Couldn't remove that area." with Try again. Strokes are drawn as the prototype's translucent red marks.

**Effects** (`Features/Effects`, `ImageEngine/Effects`), the approved `effectsPanel`:
- Tabs Light Leaks, Grain, Vignette, each with the dot when on; On/Off row with the switch.
- Light Leaks: Warm edge, Amber flare, Rose, Prism; Intensity; Rotation; drag on the photo to move it.
- Grain: Fine, Film, Coarse; Amount, Size, Roughness. Vignette: Amount, Size, Softness.
- The approved notice when the applied preset already has its own grain or vignette and the person's is on: "…This one is added to it, not replaced." Both are rendered.

**Tool "used" dots** follow the prototype's `toolUsed` exactly. Effects: any effect on. Edit: a crop aspect other than Original, a turn, a horizontal flip, a straighten angle, any Adjust slider, or a Remove stroke (including the one being removed or that failed, as the prototype adds the stroke before removing). **This closes M5**: `compare`, `saving` and `saved` now set the prototype's `edited` state (preset plus vignette) and show the Effects dot.

**One session.** Every Edit and Effects change is a whole-recipe undo step through `EditorSession` (`commitEdit`, `commitEffects`); sliders preview without committing. Preview and Save copy render the same committed recipe; only the resolution differs.

## Rendering (rendering-v2 revision 1)

The bundled `rendering-v2.json` stays at revision 1 (DevelopModel checks it). With no Edit or Effects edit the slice-2/3 path runs unchanged, so their captures stay valid.

- **edit.geometry** (`GeometryStage.swift`): one projective map in pixel coordinates — quarter turns → flips → perspective → straighten (rotation about the centre, zoom `max(cos + H/W·sin, cos + W/H·sin)`, the smallest with no empty corner) → crop rect in the straightened frame. Bilinear resampling. Marks and touches (focus target, face rings, refine and Remove strokes, refine tint) map through the same transform.
- **edit.adjust** (`AdjustStage.swift`): the contract's provisional mapping — `develop.global` with ev = exposure/50, contrast/highlights/shadows, white balance temp/tint, saturation/vibrance, baked to a 33³ LUT (cached by value); Detail as `develop.spatial` noise reduction (luminance = colour = noise), clarity, sharpening (amount = sharpness, radius 1.0, detail 25, edge masking 0). A replaced background receives the Adjust colour too (stage-7 note).
- **effects** (`EffectsStage.swift`): light leak → preset vignette → user vignette → preset grain → user grain, on the frame. User vignette maps to F1 (amount = −amount, midpoint = size, feather = softness, roundness 0, style 1); user grain reuses `GrainEvaluator` (revision-1 grain: chromaticity kept, supersampling) with size × 0.7/1.0/1.5 for Fine/Film/Coarse and the seed fixed at creation. Light leak: radial glow at (x, y) %, core intensity/130, 30 % ring intensity/400, fade to 0 at 55 % of the long edge, rotated about the frame centre, screen-blended in encoded sRGB as CSS does, premultiplied interpolation; Prism sweeps the hue around the centre (provisional).

### Contract gaps (reported to the coordinator, not changed)

- **C1 — Remove's place in the order.** rendering-v2 §1 puts `edit.remove` at stage 6, in the frame after Adjust, but `docs/v1/remove-evaluation.md` §7 says Remove runs "on the full-resolution source pixels, before tone and colour adjustments", so later tone changes never re-run the model. iOS follows §7: patches are replayed on the source before stage 1.
- **C2 — Adjust and stages 7–9 before geometry.** iOS runs Adjust (5) and Background/Portrait (7–9) in source coordinates and geometry (4) after them (scene mattes, depth and faces are in source coordinates). Colour is per pixel, so the only difference is that Detail's and Focus & Blur's radii follow the uncropped long edge. Marked `CONTRACT GAP` in `EditorSession.renderPixels`.
- **C3 — Perspective.** "±100 scales the far edge by 1 ∓ 0.3" names neither which edge is far for each sign nor how the keystone is zoomed. iOS: positive vertical narrows the top edge, positive horizontal the right edge; then the smallest zoom about the centre that leaves no empty area.
- **C4 — Light leak geometry.** The contract says "fades to 0 at 55 % of the long edge"; the prototype's CSS `radial-gradient(circle at …)` measures its stops along the farthest-corner ray. iOS follows the contract (equal within 0.05 % on the 3:2 sunset at the default position). Ring stop taken as 30 % of the long edge for the same reason.

## Remove (LaMa big-lama)

| Item | Value |
|---|---|
| Model | LaMa big-lama (advimman/lama @ 786f593), converted to Core ML fp16 at a fixed 512 × 512 input (`lama_512_fp16.mlpackage`, 103 MB) |
| Official source | weights `https://huggingface.co/smartywu/big-lama/resolve/05cb2be7f8dbe6ca7c6e78f4fc827a4b2baaa4a9/big-lama.zip` (the mirror linked from the official README), fetched by `experiments/inpaint/fetch_models.sh` for development only |
| Licence | Apache-2.0, code and weights. Training data: Places2 (non-commercial research terms on the images) |
| SHA-256 | `big-lama.zip` f1b358ca24093b93a106183b98a3dea6e8ed09f3b43ea7251eb2c81e7b4575f6; `best.ckpt` fccb7adffd53ec0974ee5503c3731c2c2f1e7e07856fd9228cdcc0b46fd5d423; package (files in path order) 787574a416b33050eb9940030f794c5afa41680d3fd0b0486897d48a1b4d6837; `weights/weight.bin` 805bc8896aa0f2c9991fc1855226783eba6128e55cedc0c78199d0ff340d9f4b — all re-verified 2026-10-04 |
| Conversion | `experiments/inpaint/convert.py` (already in the repo; FFTs replaced by exact DFT matrix products; coremltools 8.3, mlprogram, iOS 17, fp16; PSNR 64.4 dB vs PyTorch). Not re-run: the package on disk matches the recorded digest |
| Bundling | `ios/Tools/bundle_remove_model.sh` (LookPack aggregate target): verifies `weight.bin`'s SHA-256 (a mismatch fails the build), compiles once with `coremlcompiler` (cached by digest), copies `lama_512_fp16.mlmodelc` into the app |
| **Release gate** | **"pending legal sign-off (training data: Places2)"**: build setting `LIGHTLY_REMOVE_MODEL_TRAINING_DATA_SIGNED_OFF` (default `NO`) and Info key `LightlyRemoveModelTrainingDataSignedOff`. Release builds bundle and load the model only when YES; Debug builds always do. Without the model every stroke shows the approved failure state; the tool stays listed; there is no classical fill |
| Runtime | `.cpuAndGPU` on devices (never the Neural Engine, remove-evaluation §7); `.cpuOnly` in the Simulator. Loaded lazily on first stroke, off the main actor |

Pipeline (`RemoveEngine.swift`): rasterise the stroke (capsule, radius × long edge) plus a 3 px feather band; context window 2.2 × extent — ≤ 512 px is fed natively, larger is resized to 512 and back; the earlier strokes' patches are composited first; only the brush and its feather are pasted back. The patch (rect, RGBA with feathered alpha, source size) is stored by SHA-256 in the session's `RemovePatchStore`; the recipe's stroke records `patch` as a `derivedRef` (digest, model `lama-big-lama-coreml-fp16-512`/`787574a`, size). Preview composites the same patch scaled; export composites it at 1:1. Undo stroke is one step; redo replays the stored patch.

DEFERRED (marked in code): the tiled-native route for long thin strokes (§4); such strokes take the downscaled route, same engine.

**Timing (Simulator only; device timing pending).** iPhone 17 Simulator on the build Mac, CPU only, `RemoveModelTimingTests` on `landscape_03` (1600 × 1067) with the prototype's `ed-remove` stroke (downscaled route, one 512 tile), per run (load; three strokes): 08f73a0 933 ms; 2,482 / 2,240 / 2,369 ms — fc46c25 1,176 ms; 2,325 / 2,319 / 2,234 ms — development build 1,398 ms; 3,122 / 3,051 / 3,012 ms. Device timing (dev iPhones SE 3 and 11 Pro Max, `.cpuAndGPU`) is **pending**.

## Tests (recorded build 08f73a0; first run at fc46c25 with the same results)

- **Unit (`LightlyTests`): 290 tests, 0 failures, 4 skipped** (`test-ios-slice4-08f73a0`; also `test-ios-slice4-unit-fc46c25`). New: `EditEffectsStageTests` (13: geometry identity, turns, flips, straighten zoom, perspective coverage, crop aspect and round-trip; Adjust mapping and LUT; vignette, grain composition and repeatability, light leak; Remove patch changes only the brush and feather, preview composite, failure without fill), `EditEffectsSessionTests` (5: whole-recipe undo across Edit and Effects, preview and export of the same cropped recipe, Remove commits one step with its patch and Undo stroke, no model → failed state with nothing changed, Cancel changes nothing), `RemoveModelTimingTests` (1, real LaMa).
- **UI (`EditorFlowUITests`): 15 tests, 0 failures** (`test-ios-slice4-08f73a0`; also `test-ios-slice4-ui-flows-fc46c25`). New: Edit and Effects in the Develop session, the used dots, Undo/Redo one whole step at a time. The stub test now opens Watermark (still slice 5).

## Comparison matrix

**Status: PENDING — progress, not acceptance.** The owner's intervention (2026-10-04, `docs/v1/verification-workflow.md`) paused bulk capture: the 24-cell run at 08f73a0 was stopped after 2 cells and is not restarted without the owner's scheduling approval.

| Cell | 08f73a0 (final build) | Review |
|---|---|---|
| iphone17 portrait light default | 53 screens captured (15 slice-4, compare/saving/saved, 18 slice-2, 9 slice-3 Background, 8 slice-3 Portrait) | all 53 reviewed side by side (sheets plus 1:1 crops of chips, crop frame, Auto dot, rings, progress box, Remove stroke) |
| iphone17promax portrait light default | 53 captured | `ed-removing` … `compare` reviewed; the rest captured, review pending |
| ipadpro11 portrait light default | interrupted (incomplete, not evidence) | pending |
| the other 21 cells | not captured | pending |

Earlier evidence (superseded by later fixes, kept, not current): `runner5-fc46c25-superseded/` (iphone17 and Pro Max light default, iPad 11 portrait light default; 18 screens each) and `runner5-d153545-superseded/` (iphone17 light default, 53). Development captures at e20fb85 + local changes: iphone17 light default and ipadpro11 landscape light **large** (18 slice-4 screens each) — the side layout and Large text matched apart from the deviations below. The slice-2 and slice-3 matrices of other cells keep their recorded results at 5c3a3ee/73a42cc but are **stale** for the floored-border and chip fixes (below) until recaptured.

Artifacts: `~/.codex/artifacts/lightly/v1/slice4/ios/runner5/native/<cell>/` (PNG + JSON: revision 08f73a0, fingerprint `snapshot`, cell, tool `editor-capture-5`, `subjectMatte`, `faceQuality`, `removeModel`); review sheets in `~/.codex/artifacts/lightly/v1/sheets/`.

### Results, iPhone 17 portrait light default @08f73a0 (every capture also carries D1, M1, M7)

| Screen | Result |
|---|---|
| ed-crop, ed-rotate, ed-adjust-light, ed-adjust-colour, ed-adjust-detail, ed-remove, ed-remove-failed, fx-leak, compare, saving*, saved* | V (*saving, saved also G2 under the scrim/sheet) |
| ed-straighten | E1 |
| ed-perspective | E2 |
| ed-removing | M4 |
| fx-grain, fx-combined | M9 (fx-combined also G2) |
| fx-vignette | G2 |
| fx-preset-conflict | F1, M9 |
| slice-2 screens (18) | as recorded at 5c3a3ee (V, M4 on dev-long-name, M9 on dev-favourites/dev-portrait-photo); the floored Auto dot, knob and spinner now match |
| bg-separating | M4 (was V; centring defect X4 fixed) |
| other slice-3 screens (16) | as recorded at 5c3a3ee (S1–S3, P1, P2); rings, target and knobs now 1 pt as rendered |

M5 (no Effects dot on compare, saving, saved) is **closed** in the reviewed cells: the dot and the vignette show as the prototype's `edited` setup.

### Deviations (expected / observed / evidence)

| Id | Screens | Expected (approved) | Observed (native) | Cause / needs |
|---|---|---|---|---|
| E1 | ed-straighten | `rotate(−3deg) scale(1.12)`: fixed 1.12 zoom | the contract's smallest no-empty-corner zoom (1.077 at −3° on 3:2), so the photo is less magnified | rendering-v2 §7; owner decision |
| E2 | ed-perspective | the photo is not warped (the prototype draws only the grid) | keystone applied (vertical +18 narrows the top) | rendering-v2 §7 (and gap C3); owner decision |
| F1 | fx-preset-conflict | the prototype applies Film 5, chosen by its stand-in hash `presetHasEffect` | Film 3 ("01 Vintage 01"): Film 5's real recipe has no grain, so the approved notice could not appear with it | owner decision on the substitution |
| G2 | fx-vignette, fx-combined, saving, saved | CSS radial overlay to 0.32 black at the corners | F1 vignette with the uncalibrated `VIGNETTE_K`: corners lighter (bottom-left 56 vs 45 sRGB levels on the lake photo) | contract calibration (as M9) |
| M9 | fx-grain, fx-combined, fx-preset-conflict | the prototype's SVG noise overlay | revision-1 F2 grain with the uncalibrated `GRAIN_K`: much coarser and stronger | Lightroom references (contract-fixes-1 §3) |
| M4 | ed-removing, bg-separating | Inter line metrics | the progress box is ~1.3 pt shorter (SF line height at 14 pt) | text rendering, as M3/M4 |
| D1, M1, M2, M3, M7 | as in slice 2 | | | |

**Owner question Q1.** The approved `toolUsed` for Edit leaves out Flip vertical and Perspective, so `ed-perspective` shows no Edit dot. Implemented exactly as approved; please confirm.

### Defects fixed during this review

| Id | Fix | Affects |
|---|---|---|
| X4 | 6fa497a: `.opt` chips were 2 pt narrower (border drawn inside 12 pt padding; CSS is border-box with 12 pt padding plus 1 pt border) | ed-crop, ed-rotate, fx-leak, fx-grain, fx-preset-conflict, pt-multi (face chips) |
| X5 | d153545: floored border widths (below) | every screen with the Auto dot, a slider, the spinner, the focus target, face rings or the crop frame |
| X6 | 08f73a0: progress box content was left of centre at the 200 pt minimum width (13 pt on bg-separating) | bg-separating, ed-removing |

## Floored border widths (coordinator request)

Measured in the reference renderer itself (`getComputedStyle`, playwright-core Chromium, the prototype's `stateFor` + `screenHTML`, iphone17 @3x and ipadpro11 @2x, fonts ready, CSS viewport = the device's logical size): `.autoT::before` 1px (9px content box → 11 px dot), `.spinner` 2px, `.target` 1px, `.trk b` 1px, `.faceRing` 1px, `.cropframe` 1px (`.cropframe i` 3px, unchanged). iOS drew the CSS source values (1.5 and 2.5). Fixed in d153545 (its own commit): Auto dot 11 pt with a 1 pt ring; slider knobs (panel sliders and Amount) 1 pt; focus target 1 pt; face rings 1 pt; spinner 2 pt; crop frame 1 pt with handles and grid placed from it. Android's equivalent is 0a5fe7d.

Affected slice-2 screens (all 21: Auto dot, Amount knob or spinner): loading, developing, model-unavailable, develop-failed, dev-original, dev-preset, dev-dragging, dev-browse, dev-large, dev-long-name, dev-amount, dev-starred, dev-favourites, dev-fav-full, dev-fav-replace, dev-bw, dev-landscape-photo, dev-portrait-photo, compare, saving, saved.
Affected slice-3 screens (17): bg-focus, bg-soft, bg-swirl, bg-motion, bg-refine, bg-change-image, bg-replaced-blur, bg-separating, bg-no-subject, pt-skin, pt-under, pt-eyes, pt-teeth, pt-hair, pt-landscape-photo, pt-multi, pt-hidden. Unaffected: bg-change-colour, bg-change-gradient, bg-failed, pt-no-usable-face.
Recaptured and reviewed at 08f73a0: iphone17 portrait light default (all of them); Pro Max light default captured. **Pending in the other 22 cells** (bulk capture paused).


## Pending

- Device checks (dev devices only): Remove timing and memory with `.cpuAndGPU`; export memory with geometry and patches at full resolution.
- The 24-cell matrix at 08f73a0 (22 cells, plus the Pro Max review), including the slice-2/3 recaptures for X4–X6: needs the owner's scheduling approval (bulk capture paused).
- Owner decisions: E1, E2, F1, G2, contract gaps C1–C4, the Edit dot rule (Q1).
- Legal: Places2 training data (Remove release gate).
- Lightroom grain and vignette references (contract-fixes-1 §3) for M9 and G2.
