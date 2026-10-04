# Slice 4 on Android: Edit, Effects and Remove

Reference: the approved prototype `docs/ui/app/` (`editPanel`, `effectsPanel`, `marksFor`, `toolUsed`, the `ed-*` and `fx-*` screens), rendering-v2 **revision 2** (`shared/contracts/rendering-v2.md`, contract fixes 2: C1–C4), edit recipe v1 (`tools.edit`, `tools.effects`) and `docs/v1/remove-evaluation.md`. iOS (`docs/v1/slice4-ios.md`) was the behavioural reference; where it and the approved design differ, the design is followed.

**Status: progress, not accepted.** Built, unit- and Robolectric-tested, one setup (Pixel 9 Pro portrait, light, default text) captured and reviewed at the final build. Every other cell is pending, because bulk capture is paused. Deviations need owner decisions.

## Commits

| Kind | Commit | What |
|---|---|---|
| Code | b0a637c | Edit (geometry, Adjust, Remove), Effects, the LaMa release gate, the pipeline, panels, marks, dots, capture scenarios, tests |
| Code | 8ba8d11 | Requires rendering-v2 revision 2. The light leak leaves areas the rotated overlay does not cover untouched (C4). Tested against the `lightLeak` goldens |
| Tests | a09315e, 3035a3f, 471c778 | Test fixes (the cancel toast, the stub test now uses Watermark, an import) |
| Tooling | 27da227 | Capture photo mapping for the slice-4 screens (field, street, sunset) |
| Code | 8c165eb | Shared component fixes found in this review: `.opt` chip width, and the `.tabs` selected-tab scroll (X1, X2 below) |
| Tooling | 699087b | `s4-export` debug scenario for the saved-JPEG check |
| Docs | this file | |

Verification source: snapshots of each commit (`scripts/verify_preflight.py snapshot`). APK 699087b: `apk_sha256` 402e20b6…f4ab, 288 MB (LaMa fp32 and depth bundled; debug).

## What is built

**Edit** (`EditPanel.kt`, `EditMarks.kt`, `EditModels.kt`), the approved `editPanel`:
- Tabs: Crop, Rotate, Straighten, Perspective, Adjust, Remove.
- **Crop:** Original, Free, 1:1, 4:5, 3:2, 16:9, 9:16. A fixed aspect takes the largest centred rect; Original resets. The crop frame mark: inset 6 %, 1.5 dp white border (the CSS source value), the outside darkened by .42, 18 dp handles with 3 dp borders, and the thirds grid. Dragging a corner crops (a fixed aspect is kept; an uncropped photo becomes Free). Pinching zooms the crop. Each gesture is one step.
- **Rotate:** Rotate left, Rotate right, Flip horizontal, Flip vertical. A fixed aspect is laid out again after a turn; a Free rect turns with the photo.
- **Straighten:** Angle −45…45, the approved note, the thirds grid.
- **Perspective:** Vertical and Horizontal, −100…100, the thirds grid.
- **Adjust:** Light (Exposure, Contrast, Highlights, Shadows), Colour (Temperature, Tint, Saturation, Vibrance), Detail (Sharpness, Clarity, Noise reduction).
- **Remove:** Brush size (35), and Undo stroke (opacity .4 with no strokes), with the note. Brushing on the photo removes the stroke. While it runs, "Removing…" shows over the photo and in the panel, with Cancel ("Cancelled · nothing changed"). A failure shows "Couldn't remove that area." with Try again. Strokes are drawn as the prototype's rgba(235,60,60,.42) marks.

**Effects** (`EditPanel.kt`, `EffectsPanel`), the approved `effectsPanel`:
- Tabs Light Leaks, Grain and Vignette, each with the dot when on.
- The On/Off row with the approved switch.
- Light Leaks: Warm edge, Amber flare, Rose, Prism; Intensity; Rotation; drag on the photo to move the leak.
- Grain: Fine, Film, Coarse; Amount, Size, Roughness.
- Vignette: Amount, Size, Softness.
- The approved notice when the applied preset has its own grain or vignette and the person's is on (deviation F1 below).

**Used dots** follow the prototype's `toolUsed` exactly:
- Edit: an aspect other than Original, a turn, a horizontal flip, a straighten angle, any Adjust slider, or a stroke (including a pending or failed one). Q1: Flip vertical and Perspective do not set the dot, as approved.
- Effects: any effect on.
- The prototype's `edited` setup (compare, saving, saved, leave-unsaved, more) now turns the vignette on, so those screens show the Effects dot and the vignette (the M5 equivalent). Their slice-2 captures are **stale** until recaptured.

**One session.** Every Edit and Effects change is one whole-recipe undo step (`commitEdit`, `commitEffects`). Sliders and the leak drag preview without committing. A Remove stroke becomes a step only once its patch exists.

**Release:** Edit and Effects are offered in release builds (`EditorTools.isImplemented`). Background's release gating is left as slice 3 has it.

## Rendering (rendering-v2 revision 2)

`EditPipeline.kt` (app), plus `GeometryTransform`, `AdjustStage` and `EffectsStage` (core-develop). The order is Remove patches (1) → Auto (2) → Look (3, 4) → Adjust (5) → Background (6, 7) → geometry (9) → Effects with the preset's finishing (10), as revision 2 specifies. Without Edit or Effects edits, the slice-2/3 path runs unchanged.

- **Geometry:** one projective map, resampled once (bilinear). The steps are quarter turns → flips → perspective (§7.2: positive values narrow the top or right edge, then the smallest zoom with no empty area) → straighten (zoom `max(cos + H/W·sin, cos + W/H·sin)`) → crop. Marks, Remove strokes, the focus target and taps all map through it.
- **Adjust:** colour is baked through the Develop model as the contract maps it (33³, cached by value). Detail runs as the Develop spatial operators, in a second Develop pass. `DevelopRenderer.renderView` renders a tile from a region of a frame, so the pass also tiles for export.
- **Effects:** light leak (C4: farthest-corner stops; no leak where the rotated overlay does not reach) → preset vignette → user vignette → preset grain → user grain. Vignette and grain are the revision-1 `FinishingPass` operators. User mapping: vignette amount −amount, midpoint size, feather softness, style 1. Grain size × 0.7, 1.0 or 1.5, seed from the recipe.
- **Save copy:** tiles the OUTPUT frame. core-export lets a plan declare its output size (`ExportTileRenderer.outputSize`). For each frame tile, the renderer reads the source region its geometry maps to, plus the Adjust apron. Patches are composited 1:1 into the export's own decode.
  - Adjust › Clarity's large blur base comes from a 1024-px copy of the source, rescaled. This is an approximation, as Develop's own clarity base already is.

## Remove (LaMa big-lama)

| Item | Value |
|---|---|
| Model | LaMa big-lama (advimman/lama @ 786f593). Our LiteRT **fp32** conversion `lama_512_fp32.tflite` (`experiments/inpaint/convert_tflite.py`, litert-torch 0.9.4; 131 dB vs PyTorch). **No fp16 LiteRT conversion exists** (DEFERRED: remove-evaluation §7 asks for fp16, ~103 MB) |
| Official source | weights `https://huggingface.co/smartywu/big-lama/resolve/05cb2be7f8dbe6ca7c6e78f4fc827a4b2baaa4a9/big-lama.zip`, the mirror the official README links, fetched for development only by `experiments/inpaint/fetch_models.sh` |
| Licence | Apache-2.0, code and weights. Training data: Places2 (non-commercial research terms on the images) |
| SHA-256 (re-verified 2026-10-04) | `big-lama.zip` f1b358ca24093b93a106183b98a3dea6e8ed09f3b43ea7251eb2c81e7b4575f6; `best.ckpt` fccb7adffd53ec0974ee5503c3731c2c2f1e7e07856fd9228cdcc0b46fd5d423; `lama_512_fp32.tflite` 39fa82d6a2b576de99b30481c85d73d48955f126deb7bea8504e58b15b43ca0e (the build checks this when it bundles the model) |
| **Release gate** | **"pending legal sign-off (training data: Places2)"**. Debug builds bundle the model when the git-ignored file exists; release builds bundle it only with `-PlightlyRemoveLegalSignOff=true`. `BuildConfig.REMOVE_MODEL_ENABLED`; `-PlightlyRemoveModelFile` overrides the path. Without the model every stroke shows the approved failure state. The tool stays offered, and there is no classical fill |
| Runtime | LiteRT 1.4.2 Interpreter, CPU (XNNPACK on devices; built-in kernels on the emulator, which crashes in XNNPACK, as for depth). Loaded lazily on the first stroke. The merged-manifest privacy check passes |
| APK | Debug APK 288 MB (+206 MB, stored uncompressed for memory-mapping) |

Pipeline (`RemoveEngine.kt`):
1. Rasterise the stroke: a capsule chain of the brush radius, plus a 3 px feather outside it.
2. Take a context window of 2.2 × the stroke's extent, at least 512, clamped to the photo. A 512 window is fed natively; a larger one is resized to 512 and the fill resized back, with the mask grown by half a model pixel.
3. Paste back only the brush and its feather, on the full-resolution source with the earlier patches composited.
4. Store the patch by SHA-256 (`derivedRef`: model `lama-big-lama-litert-fp32-512`/`39fa82d6a2b5`).

Preview composites the patch scaled; export composites it 1:1. Undo stroke is one step; redo replays the stored patch.

DEFERRED:
- The tiled-native route for long thin strokes (as iOS).
- Patches are kept in memory only. A session restored after process death renders a stroke whose patch is missing without it.

**Timing (emulator only; device pending):** Pixel 9 Pro AVD on the build Mac, CPU built-in kernels, landscape_03 with the prototype stroke (native 512 route): **26.9 s** for one stroke (`LightlyRemove` log, export-check run). The `ed-remove` capture finished within its 8.9 s ready time, but its stroke time was not logged. Device timing (dev phones, XNNPACK) is **pending**.

## Tests (snapshots 8ba8d11 / a09315e / 699087b)

| Module | Result | What it covers |
|---|---|---|
| core-develop | 33/33 | **EditStagesTest** (14): identity, turns, flips, straighten zoom, keystone coverage and direction, crop aspect and round trip, tiled geometry equals whole, the Adjust mapping, exposure, the Adjust region view equals whole, vignette, user mappings, grain repeatability and tiling, leak fade, effects added to the preset's. **LightLeakGoldensTest**: the 4 revision-2 goldens (R, premultiplied overlay and output within 2e-4). DevelopRendererTest and GrainGoldensTest unchanged |
| core-export | 34/34 | |
| core-background | RenderingGoldensTest 6/6 | Revision-2 index; goldens byte-identical |
| app | **83/83** | **EditEffectsTest** (8): the patch changes only the brush and feather; the preview composites the same patch scaled; **tiled Save copy equals the whole-frame preview byte for byte** (turn, straighten, crop, Adjust colour and detail, all three effects); whole-recipe undo/redo across Edit and Effects, with sliders not committing; the used-dot rules (Q1); a Remove stroke is one step with its patch, and undo/redo never re-runs the model; with no model, the failure state and nothing changed; Cancel changes nothing; Save copy writes the cropped size. **EditorScreenTest**: Edit and Effects panels with the approved copy and the On/Off row |

## Visual check: Pixel 9 Pro portrait, light, default text, APK 699087b

Captured with `android/tools/capture/capture-batch.sh` (runner mode, one invocation, label `verify-android-slice4-699087b`; 17 screens in 167 s, 0 failures). References come from `scripts/reference_cache.py` (rendered fresh for the ed-*/fx-* screens; compare was a cache hit).
- Native PNG + JSON: `~/.codex/artifacts/lightly/v1/slice4/android/699087b/pixel9pro-portrait-light-default/`
- First pass (before X1/X2, superseded): `…/27da227/`.

Every screen also carries the platform differences recorded in slice 2: S1 (system status bar), D1 (Auto injected), and Look rendering (the prototype simulates looks).

| Screen | Result |
|---|---|
| ed-crop, ed-rotate, ed-adjust-light, ed-adjust-colour, ed-adjust-detail, ed-remove, ed-removing, fx-leak | V: layout, copy, chips, tabs (scrolled as the prototype), marks and dots match. The leak's colour at the sampled points is within 13 levels on one channel at (0.4, 0.3) and 1–3 levels elsewhere. Adjust and the preset are real processing |
| ed-remove-failed | V (with the preset rendered for real, darker than the simulation) |
| ed-straighten | **E1** (zoom 1.077, contract, vs the prototype's fixed 1.12) |
| ed-perspective | **E2** (the keystone is applied; the prototype does not warp) |
| fx-grain, fx-combined | **M9** (revision-1 grain with the uncalibrated GRAIN_K: much coarser and stronger than the prototype's SVG noise) |
| fx-vignette, compare | **G2** (F1 vignette with the uncalibrated VIGNETTE_K: corners lighter than the CSS overlay). compare now shows the Effects dot and vignette as approved |
| fx-preset-conflict | **F1** (the first Film preset whose real recipe has grain), M9 |

**Saved-JPEG check** (`s4-export` scenario, label `verify-android-slice4-export-699087b`). Recipe: a real LaMa stroke, straighten −3, exposure +30, contrast +20, temp +25, crop 4:5, leak, grain and vignette 60. Saved `Lightly_1791089049112.jpg`, **854 × 1067**, the 4:5 crop of the 1600 × 1067 source. It shows all of:
- the straightened horizon;
- the Adjust warmth and exposure;
- the leak's warm top-left;
- darkened corners;
- grain;
- continuous cloud where the stroke was.

Files: `~/.codex/artifacts/lightly/v1/slice4/android/699087b/export-check/` (`s4-export-saved.jpg`, `source-vs-saved.jpg`, `after-save.png`).

### Deviations (expected / observed / cause)

| Id | Screens | Expected (approved) | Observed (native) | Needs |
|---|---|---|---|---|
| E1 | ed-straighten | fixed `scale(1.12)` | the contract's no-empty-corner zoom (1.077 at −3° on 3:2) | owner decision (as iOS) |
| E2 | ed-perspective | the photo is not warped | keystone applied (rendering-v2 §7.2 names this deviation) | owner decision |
| F1 | fx-preset-conflict, the notice | the stand-in hash `presetHasEffect` picks Film n | the preset's real `recipe.finishing`; the scenario uses the first Film preset with grain | owner decision |
| G2 | fx-vignette, fx-combined, compare, saving, saved | CSS overlay up to 0.32 black | F1 vignette with the uncalibrated VIGNETTE_K: lighter corners | contract calibration |
| M9 | fx-grain, fx-combined, fx-preset-conflict | SVG noise overlay | revision-1 grain with the uncalibrated GRAIN_K: much coarser and stronger | Lightroom references (contract-fixes-1 §3) |
| Q1 | ed-perspective | `toolUsed` leaves out Flip vertical and Perspective | implemented exactly; no Edit dot | owner to confirm |

### Defects fixed during this review (shared components, 8c165eb)

| Id | Fix | Affects |
|---|---|---|
| X1 | `OptChip`: CSS `.opt` is border-box with 12 px padding plus a 1 px border. Compose drew the border inside the 12 dp padding, so every chip was 2 dp narrower (same as iOS X4) | crop, rotate, leak and grain chips; Background bokeh chips (their slice-3 captures are stale) |
| X2 | `OptionTabs`: the prototype's `scrollLeft = max(0, on.offsetLeft − 120)` for overflowing `.tabs`, as the Develop strip already did | Edit tabs from Straighten on; rows that fit are unchanged |

## Pending

- Every other cell of the matrix: phones, Fold outer and inner, Pixel Tablet portrait and landscape, dark, and large text. Bulk capture is paused. The roomy layouts add only the "Edit"/"Effects" panel title (no layout-specific code); a tablet and a Fold-inner check were not run in this pass.
- Recaptures made stale here: compare, saving, saved, leave-unsaved, more (the `edited` vignette); bokeh-chip screens (X1).
- Device checks (dev phones only): Remove timing and memory with XNNPACK; export memory with patches at full resolution.
- A release build with and without `-PlightlyRemoveLegalSignOff`. The gate is the same pattern as depth, but this pass did not build a release APK.
- Legal: Places2 training data (the Remove release gate).
- LaMa fp16 LiteRT conversion; Remove patch persistence.
- Owner decisions: E1, E2, F1, G2, M9, Q1.
- For later slices (noted, not built): watermark heights from the revision-2 constants; deviation W4 (Cormorant Garamond rendered, not the prototype's fallback); the 1 pt bordered-canvas outline.
