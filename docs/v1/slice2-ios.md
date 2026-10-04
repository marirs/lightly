# Slice 2 on iOS: the editor session and Develop with the real preset catalogue

Reference: the approved prototype `docs/ui/app/` (revision ff5c5ae, relocated at 0352972), the rendering contract `shared/contracts/rendering-v2.md`/`.json`, EditState schema 3 (`shared/contracts/edit-recipe-v1.json`) and the format-3 preset pack (`shared/look-pack/build_pack.py`). Slice 1 is described in [slice1-ios.md](slice1-ios.md).

## What was built

| Screen / behaviour | Native implementation | Status |
|---|---|---|
| Editor shell, `below` (phones) | `Features/Develop/EditorScreen.swift`: top bar (Close, Undo, Redo, hold-to-Compare, Save copy, ⋮ More), contain-fitted stage, Develop panel capped at 34 % of the screen height and scrolling, dock of all tools (scrolls, fades at 86 %) | working |
| Editor shell, `wide` (tablet portrait) | Panel 600 pt (640 pt on 13-inch) centred, capped at 30 %, wrapped category tabs, centred dock | working |
| Editor shell, `side` (tablet landscape) | Side panel 360 pt (400 pt on 13-inch) with the "Develop" title and the category list, then the 84 pt tool rail | working |
| Tool navigation | All seven tools in approved order. Portrait only when Vision finds a face or a person (`ImageEngine/Analysis/PersonDetector.swift`, built-in Vision, CPU on the simulator). Background, Portrait, Edit, Effects, Watermark and Border open a panel marked "Development stub" in DEBUG builds; in release builds they stay listed and do not open (`DEFERRED(slices 3–5)`) | working (stubs by design) |
| `loading`, `developing` | The photo stays visible under "Opening photo…" while the preview copy, person detection and the pack are prepared, then "Developing…" while automatic Develop runs | working |
| `model-unavailable` | No Auto model ships (D1): the approved info notice, Auto dimmed and inert, stop zero reads "Original". Nothing is ever presented as Auto | working |
| `develop-failed` | A failed Auto (DEBUG `--auto-fails` stands in for a model failure) shows the approved warning with Retry and Continue with original | working (reachable only with a model) |
| `developed` | Auto applied with the "Developed" toast | **pending D1**: no model, so this state cannot occur |
| One session per photo | `Features/Develop/EditorSession.swift`. EditState schema 3 recipes (`Domain/EditRecipe/`), whole-recipe undo/redo (50 entries), revision counter. Opening another photo, Close, or Saved › Choose another photo closes the session: no render or save result for it is shown later | working |
| Latest-request-wins previews | `LatestWinsRenderScheduler` (one running, one waiting). Frames only move forward; a release's full frame is queued after its fast frame | working |
| Develop panel | `DevelopPanelView`, `DevelopPanelModel`, `CategoryTabStrip`, `StopRuler`: Favourites first with "n/5", counts, the applied-category dot (tabs only, as in the prototype), the Auto switch, name / position / star / Amount, the "Applied: …" context line, Landscape as the category shown when nothing is applied (prototype default) | working |
| Ruler | One 12 pt tick per stop, longer every ten, a number every fifty, fixed needle, faded ends. Dragging previews the photo and the name row and commits nothing; release commits one undo step (a flick carries on, as the prototype's native scroll does); no interpolation and no arrows. Holding still for 0.5 s while dragging shows "Fine" and slows the ruler to a quarter. VoiceOver: adjustable, one stop per swipe | working; Fine timing/speed need confirmation (the prototype shows the state only) |
| Amount | "Amount N" opens the approved slider (90 pt track) with Done; dragging previews, release is one step; re-selecting the applied preset keeps its Amount, and returning to a preset restores the Amount chosen for it in this session | working |
| Favourites | Star adds/removes (the same `FavouritePresetsStore` as Preferences), five at most, the "Favourites holds five presets." notice with Replace… / Not now, and the Replace a favourite sheet | working |
| Compare | Press and hold shows the original with the "Original" badge; for VoiceOver the same button is a toggle | working |
| Save copy | The committed recipe at full resolution, tiled (1024 pt tiles with a halo for the spatial stage), the slice-1 metadata switches read at each save, then `saving` (Cancel writes nothing and shows "Save cancelled · nothing was written") and `saved` (Share, Keep editing, Choose another photo). Photos-denied, storage-full and export-failed alerts use the approved copy | working; Share uses the system share sheet with the saved JPEG |
| Leaving with unsaved edits | The approved "Leave without saving?" alert (Save copy / Discard edits / Keep editing) | working (checklist slice 5, built here because Close needed it) |

The approved UX was implemented as is. **No Reset control was added and the strength control is Amount** (see "UX conflicts" below).

### Removed

The M2 LUT editor (`Features/Editor`), the Looks screen, the legacy export sheet, the format-2 Look pack loader and its LUT book, the schema-2 saved-edit codec and the unordered favourites manager were removed with their tests and snapshot baselines. They implemented a superseded design; no approved screen used them.

## Develop rendering

### Pack (format 3)

- `scripts/bundle_look_pack.sh` copies `shared/look-pack/out/manifest.json` (and `luts/*.f32` if a validated override ever exists) into `Lightly.app/LookPack/`. It looks in `$LIGHTLY_LOOK_PACK_DIR`, this checkout, then the main checkout of a worktree. **A pack of another format version now fails the build**; a missing pack is a warning, and `DevelopPerformanceTests.testBundledPackIsTheFullFormatThreeCatalogue` then fails, so a build without the pack cannot pass the unit suite.
- `PresetPackLoader` refuses any format but `lightly-look-pack` 3, recipe version 1 and rendering contract 2; a pack whose `developModel.constantsSha256` differs from the bundled contract's; and a pack whose `catalogue.uiSha256` is not the bundled `develop-design-ui.json`. A recipe with an unknown operator or a missing parameter drops that preset with a report. A preset with a `globalOverride` is refused (`DEFERRED`: none exists).
- The contract is bundled verbatim (`rendering-v2.json`); `DevelopModel` reads the constants from it and recomputes `constantsSha256`.
- The format-2 loader is retired.

### develop.global

`ImageEngine/Develop/DevelopGlobal.swift` ports `reference_model.develop_global` statement for statement in double precision (natural-spline curve tables stored as float32 like the reference, OKLab with the same 1e-7 floor, HSL band weights, grading zones). The 33³ LUT is baked on the device per blue slice in parallel and cached by `lookVersion` (24 entries), then applied by the existing Metal LUT path. Amount is `in + s·(LUT(in) − in)`.

**Parity** (`DevelopParityTests`, against `shared/fixtures/look-pack/`, all 40 cases):

| Check | Tolerance | Worst measured |
|---|---|---|
| 17³ bake vs golden float16 LUT, every node | 1e-3 | 2.4e-4 (float16 quantisation of the golden file) |
| develop.global on the 24 probes | 5e-4 | 5e-8 |
| 33³ bake + trilinear lookup | 1e-3 | 5e-8 |
| `lookVersion` recomputed | equal | equal, all 40 |
| `lowbias32` / Gaussian field | exact / 1e-6 | exact / within 1e-6 |
| Metal applying the bake (8-bit input) | 1e-4 vs CPU trilinear | within |

### Spatial and finishing operators

All four Develop spatial operators (noise reduction, clarity, texture, sharpening) and the preset's finishing operators (vignette, grain with the portable random field) are implemented on the CPU (`DevelopPixelOperators`, `DevelopFrameRenderer`) and run in preview (after a fast global-only frame) and export. None has golden vectors yet. Port-level approximations, recorded per applied preset in the `DevelopCoverage` log:

1. Clarity's large Gaussian (σ = 5.4 % of the long edge) is computed on a fixed 256 px proxy of the developed photo and sampled back bilinearly. Allowed by rendering-v2 §5 ("a port may approximate large Gaussians"); preview and export use the same proxy size, so they agree.
2. One OKLab conversion for the whole spatial stage, with L clamped after each operator as the reference does; the reference re-encodes and clips between operators. Differences only for intermediate out-of-gamut colours.
3. Vignette and grain run on the uncropped frame: slice 2 has no geometry, so the frame is the photo.
4. While the ruler is being dragged only the global stage is shown; on release the full frame follows.

Tiles with a halo match a single whole-frame render within 1/255 (`testTilesDoNotSeam`).

**Contract issue to report:** the experimental grain is extreme at real preset amounts. "5 - (Portrait) - Glow" (Portrait 13, grain 55) covers the photo in coarse, coloured grain; `reference_model.apply_grain` produces the same result on the same photo (rendered with the shared reference at 1600 px), so this is the uncalibrated `GRAIN_K`, not the port. 618 presets carry grain.

Coverage of the presets the captured screens apply (from the pack):

| Category, stop | Preset | Operators | Completeness | Approximated (pack) | Unsupported |
|---|---|---|---|---|---|
| landscape 37 | 05 Hiking 05 | calibration, exposure, toneSliders, parametricCurve, toneCurve, hsl, vibranceSaturation, colorGrading, noiseReduction, clarity, sharpening, grain | approximate | adaptive-tone-global, grain-uncalibrated, local-contrast-calibrated, noise-reduction-provisional, sharpening-provisional | — |
| landscape 41 | 06 Drone 06 | calibration, toneSliders, parametricCurve, toneCurve, hsl, vibranceSaturation, colorGrading, clarity | approximate | adaptive-tone-global, local-contrast-calibrated | — |
| cinematic 564 | The Walking Dead 03 | whiteBalance, toneSliders, parametricCurve, toneCurve, hsl, vibranceSaturation, colorGrading, noiseReduction, clarity, sharpening, vignette | approximate | adaptive-tone-global, local-contrast-calibrated, noise-reduction-provisional, sharpening-provisional, vignette-uncalibrated | — |
| landscape 419 | Landscape 15 - Winter Wonderland | calibration, toneSliders, parametricCurve, toneCurve, hsl, vibranceSaturation, colorGrading, noiseReduction, clarity, sharpening | approximate | adaptive-tone-global, local-contrast-calibrated, noise-reduction-provisional, sharpening-provisional | — |
| portrait 13 | 5 - (Portrait) - Glow | calibration, shadowTint, toneSliders, toneCurve, hsl, vibranceSaturation, colorGrading, noiseReduction, clarity, sharpening, grain | approximate | adaptive-tone-global, grain-uncalibrated, local-contrast-calibrated, noise-reduction-provisional, sharpening-provisional | — |
| travel 5 | 01 Festive 01 | calibration, shadowTint, toneSliders, dehaze, toneCurve, hsl, vibranceSaturation, colorGrading, noiseReduction, clarity, sharpening | approximate | adaptive-tone-global, dehaze-global, local-contrast-calibrated, noise-reduction-provisional, sharpening-provisional | — |
| black-white 8 | 08 Black and White 08 | whiteBalance, toneSliders, parametricCurve, toneCurve, colorGrading, grayscale, clarity, grain | approximate | adaptive-tone-global, grain-uncalibrated, local-contrast-calibrated | — |
| golden-hour 12 | 12 Golden Hour 12 | calibration, whiteBalance, exposure, toneSliders, dehaze, parametricCurve, toneCurve, hsl, vibranceSaturation, colorGrading, noiseReduction, clarity, sharpening | approximate | adaptive-tone-global, dehaze-global, local-contrast-calibrated, noise-reduction-provisional, sharpening-provisional | — |

Nothing in the pack is validated; nothing is labelled validated in the app.

## Performance (iPhone 17 simulator on the build Mac, optimised build; device numbers pending)

| Measure | Target | Measured |
|---|---|---|
| 33³ bake, 120 bakes over the 40 parity presets | median ≤ 16 ms, p95 ≤ 33 ms | median 4.7 ms, p95 5.7–6.4 ms, max 6.8 ms (10 cores) |
| Manifest parse + index, 2,591 presets | ≤ 300 ms | 261–288 ms |
| Scrubbing 20 consecutive stops at 60 Hz, 1600 px preview | no preview older than 100 ms | worst 42 ms, median 30 ms over 22 requests |
| One preview frame, 1600 px: global stage | — | 15 ms median |
| One preview frame, 1600 px: with spatial and finishing | — | 150 ms median, 265 ms max |

Unoptimised (`-Onone`) test builds record these and skip the assertions; the numbers above come from `SWIFT_OPTIMIZATION_LEVEL=-O` runs of `DevelopPerformanceTests` and `EditorSessionTests.testScrubbingTwentyStopsNeverShowsAStalePreview`. The parse is close to its limit; making recipe decoding lazy is the next step if a device misses it.

## Auto

No shippable model exists (D1). The build ships `ModelNotBundledAutoEnhancer`; the editor shows the approved unavailable state and the recipe records `auto.modelVersion = "no-model-in-build"`, strength 0. The failure state with Retry and Continue with original is implemented and tested with a failing enhancer.

## UX conflicts (reported, not resolved)

1. **"Strength" and "Reset" in the slice description.** The approved prototype has **Amount** as the strength control and **no Reset control**. Implemented as approved: Amount, no Reset.
2. **Fine control timing.** The prototype shows the Fine state (`dev-dragging`) but not how it starts or how much slower it is. This build: hold still 0.5 s while dragging, quarter speed. Needs confirmation.
3. **The spinner turns.** The prototype draws `.spinner` still; natively it rotates (each frame looks like the approved ring).
4. **Release builds and unbuilt tools.** The stub panels exist only in DEBUG; in release builds the five unbuilt tools are listed but do not open. Needs a decision before any release build is distributed.

## Comparison matrix

**Artifacts:** `~/.codex/artifacts/lightly/v1/slice2/ios/`
- `reference/<device>-<orientation>-<theme>-<text>/<screen>.png`: the approved renderer (`docs/ui/app`, same calls as `docs/ui/tools/shot.js`) at the device's logical size and scale, all 21 screens × 24 cells.
- `native/<cell>/<screen>.png`: the app on the simulator (`Tests/LightlyUITests/EditorCaptureUITests.swift`, DEBUG `--open-photo <prototype photo> --scenario <screen id>`; optimised build; Large = simulator extra-extra-large).
- `compare/<cell>/<screen>.png`: reference left, native right (review copies; new ones are JPEG, generated on demand).
- References from now on come from the shared cache (`scripts/reference_cache.py`, variant `auto-unavailable` for the Develop screens).

**Reference variant used for the Develop screens.** Every approved Develop screen is drawn with Auto *applied* (`newSession` sets `auto: 'applied'`). No Auto model ships (D1), so the build can only show the approved unavailable state. The references for `model-unavailable`, `dev-*`, `compare`, `saving` and `saved` were therefore rendered with the approved renderer and the screen's own setup plus `s.auto = 'unavailable'` (the approved combination of "presets still work" with that screen). The screens exactly as registered (Auto applied, no notice) are **blocked by D1** in every cell. `loading`, `developing` and `develop-failed` are compared as registered.

**Status of the 24 cells: complete, current (runner v5).**
- **Build.** All 504 screens were recaptured with capture tool v5 from one recorded build at `5c3a3ee` (clean tree), one cell per heavy-lock acquisition. Artifacts: `~/.codex/artifacts/lightly/v1/slice2/ios/runner5/native/<cell>/`, each PNG with its JSON record.
- **Why the recapture.** It was triggered by the v5 re-check of the iPhone 17 cell. Against the ea75592 captures, the only photo differences were the screens showing a grain preset ("05 Hiking 05" and Glow). Those changed because of the revision-1 grain port (ec1df87), not because of the readiness signal: with the code held equal, v5 changed nothing.
- **Comparison with the reviewed captures.** In every cell, each v5 capture was diffed against its reviewed predecessor (rows of the status bar excluded, since the iPad shows the date). Every screen was identical or differed by at most 1 level on icon edges, except the grain screens. The grain screens were reviewed again against the references, and their results are unchanged.
- **Older captures.** The `runner/` and `native/` captures are marked STALE.

Each entry gives the result and the revision of the capture (`@revision`). Every capture also carries D1, M1 and M7, and M8 stays recorded for the owner.

In total: 72 screens V, 432 with recorded deviations (M2, M3, M4, M5, M9). There is no open defect and no unverified screen.

#### iPhone 17, portrait

| Screen | light, default | light, Large | dark, default | dark, Large |
|---|---|---|---|---|
| `loading` | V @5c3a3ee | V @5c3a3ee | V @5c3a3ee | V @5c3a3ee |
| `developing` | V @5c3a3ee | V @5c3a3ee | V @5c3a3ee | V @5c3a3ee |
| `model-unavailable` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `develop-failed` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-original` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-preset` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-dragging` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-browse` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-large` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-long-name` | M4 @5c3a3ee | M3 @5c3a3ee | M4 @5c3a3ee | M3 @5c3a3ee |
| `dev-amount` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-starred` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-favourites` | V, M9 @5c3a3ee | M3, M9 @5c3a3ee | V, M9 @5c3a3ee | M3, M9 @5c3a3ee |
| `dev-fav-full` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-fav-replace` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-bw` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-landscape-photo` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-portrait-photo` | V, M9 @5c3a3ee | M3, M9 @5c3a3ee | V, M9 @5c3a3ee | M3, M9 @5c3a3ee |
| `compare` | V, M5 @5c3a3ee | M3, M5 @5c3a3ee | V, M5 @5c3a3ee | M3, M5 @5c3a3ee |
| `saving` | V, M5 @5c3a3ee | M3, M5 @5c3a3ee | V, M5 @5c3a3ee | M3, M5 @5c3a3ee |
| `saved` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |

#### iPhone 17 Pro Max, portrait

| Screen | light, default | light, Large | dark, default | dark, Large |
|---|---|---|---|---|
| `loading` | V @5c3a3ee | V @5c3a3ee | V @5c3a3ee | V @5c3a3ee |
| `developing` | V @5c3a3ee | V @5c3a3ee | V @5c3a3ee | V @5c3a3ee |
| `model-unavailable` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `develop-failed` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-original` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-preset` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-dragging` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-browse` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-large` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-long-name` | M4 @5c3a3ee | M3 @5c3a3ee | M4 @5c3a3ee | M3 @5c3a3ee |
| `dev-amount` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-starred` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-favourites` | V, M9 @5c3a3ee | M3, M9 @5c3a3ee | V, M9 @5c3a3ee | M3, M9 @5c3a3ee |
| `dev-fav-full` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-fav-replace` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-bw` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-landscape-photo` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |
| `dev-portrait-photo` | V, M9 @5c3a3ee | M3, M9 @5c3a3ee | V, M9 @5c3a3ee | M3, M9 @5c3a3ee |
| `compare` | V, M5 @5c3a3ee | M3, M5 @5c3a3ee | V, M5 @5c3a3ee | M3, M5 @5c3a3ee |
| `saving` | V, M5 @5c3a3ee | M3, M5 @5c3a3ee | V, M5 @5c3a3ee | M3, M5 @5c3a3ee |
| `saved` | V @5c3a3ee | M3 @5c3a3ee | V @5c3a3ee | M3 @5c3a3ee |

#### iPad Pro 11-inch, portrait

| Screen | light, default | light, Large | dark, default | dark, Large |
|---|---|---|---|---|
| `loading` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `developing` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `model-unavailable` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `develop-failed` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-original` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-preset` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-dragging` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-browse` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-large` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-long-name` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-amount` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-starred` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-favourites` | M2, M9 @5c3a3ee | M2, M3, M9 @5c3a3ee | M2, M9 @5c3a3ee | M2, M3, M9 @5c3a3ee |
| `dev-fav-full` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-fav-replace` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-bw` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-landscape-photo` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-portrait-photo` | M2, M9 @5c3a3ee | M2, M3, M9 @5c3a3ee | M2, M9 @5c3a3ee | M2, M3, M9 @5c3a3ee |
| `compare` | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee |
| `saving` | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee |
| `saved` | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee |

#### iPad Pro 11-inch, landscape

| Screen | light, default | light, Large | dark, default | dark, Large |
|---|---|---|---|---|
| `loading` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `developing` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `model-unavailable` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `develop-failed` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-original` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-preset` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-dragging` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-browse` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-large` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-long-name` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-amount` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-starred` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-favourites` | M2, M9 @5c3a3ee | M2, M3, M9 @5c3a3ee | M2, M9 @5c3a3ee | M2, M3, M9 @5c3a3ee |
| `dev-fav-full` | M2, M4 @5c3a3ee | M2, M3 @5c3a3ee | M2, M4 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-fav-replace` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `dev-bw` | M2, M4 @5c3a3ee | M2, M3 @5c3a3ee | M2, M4 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-landscape-photo` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-portrait-photo` | M2, M4, M9 @5c3a3ee | M2, M3, M9 @5c3a3ee | M2, M4, M9 @5c3a3ee | M2, M3, M9 @5c3a3ee |
| `compare` | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee |
| `saving` | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee |
| `saved` | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee |

#### iPad Pro 13-inch, portrait

| Screen | light, default | light, Large | dark, default | dark, Large |
|---|---|---|---|---|
| `loading` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `developing` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `model-unavailable` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `develop-failed` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-original` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `dev-preset` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `dev-dragging` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `dev-browse` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `dev-large` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `dev-long-name` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `dev-amount` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `dev-starred` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `dev-favourites` | M2, M9 @5c3a3ee | M2, M9 @5c3a3ee | M2, M9 @5c3a3ee | M2, M9 @5c3a3ee |
| `dev-fav-full` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-fav-replace` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `dev-bw` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `dev-landscape-photo` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `dev-portrait-photo` | M2, M9 @5c3a3ee | M2, M9 @5c3a3ee | M2, M9 @5c3a3ee | M2, M9 @5c3a3ee |
| `compare` | M2, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M5 @5c3a3ee |
| `saving` | M2, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M5 @5c3a3ee |
| `saved` | M2, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M5 @5c3a3ee |

#### iPad Pro 13-inch, landscape

| Screen | light, default | light, Large | dark, default | dark, Large |
|---|---|---|---|---|
| `loading` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `developing` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `model-unavailable` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `develop-failed` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-original` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-preset` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-dragging` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-browse` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-large` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-long-name` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-amount` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-starred` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-favourites` | M2, M9 @5c3a3ee | M2, M3, M9 @5c3a3ee | M2, M9 @5c3a3ee | M2, M3, M9 @5c3a3ee |
| `dev-fav-full` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-fav-replace` | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee | M2 @5c3a3ee |
| `dev-bw` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-landscape-photo` | M2 @5c3a3ee | M2, M3 @5c3a3ee | M2 @5c3a3ee | M2, M3 @5c3a3ee |
| `dev-portrait-photo` | M2, M9 @5c3a3ee | M2, M3, M9 @5c3a3ee | M2, M9 @5c3a3ee | M2, M3, M9 @5c3a3ee |
| `compare` | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee |
| `saving` | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee |
| `saved` | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee | M2, M5 @5c3a3ee | M2, M3, M5 @5c3a3ee |


### Capture runner (one launch per cell)

`EditorCaptureUITests` now photographs a whole cell in one launch. A DEBUG-only driver (`App/DebugCaptureDriver.swift`, compiled out of release builds) takes each screen's arguments from a command file. Before each screen it closes the previous editor and waits until that session's work has stopped (open, subject separation and depth, Save copy, renders). It then resets preferences, favourites and the Develop bake cache, and opens the screen's photo through the normal open path. The editor marks `capture.ready.<n>` only when the scenario has been applied, the renders for the current recipe have landed (`settleRendering`), the screen's save state holds (`saving`, `saved`), and two Core Animation commits have passed. The test waits for that marker; there are no fixed sleeps. Animations are off in a capture session, so the spinner stands still. The launch-per-screen path stays available (`LIGHTLY_CAPTURE_MODE=launch`) only to validate the runner. The lifecycle tests (Welcome, recovery, launch) remain launch-based.

**Validation (old launch-per-screen path against the runner, same build, same simulator, status bar fixed at 9:41, all 21 slice-2 screens, pixel by pixel).** Artifacts: `~/.codex/artifacts/lightly/v1/runner-validation/<cell>/{launch,session,launch2}/`, each PNG with a JSON record (revision, local-change fingerprint, device, orientation, theme, text size, mode, tool version, PNG SHA-256).

| Cell | Identical | Differences | Explanation |
|---|---|---|---|
| iPhone 17 portrait light default | 4 of 21 | `loading`, `developing`, `saving`: 611–838 px in a 65 px square at the spinner. 14 other screens: 1–54 px, every one a difference of 1 level in one channel. | Spinner: the runner turns animations off, so the ring stands still; the old path photographs it mid-turn (M8). The 1-level differences lie on the anti-aliased edges of stroked vector icons: the top bar's close and undo icons, and the tool dock and rail icons. |
| iPad Pro 11-inch landscape light default | 6 of 21 | Spinner squares as above; elsewhere 3–9 px of 1 level, on the undo icon at (112–115, 56–61) pt and one rail-icon pixel. | Same. Control: a second launch-per-screen run of five screens against the first shows the same 1-level differences on the same icon pixels (4–8 px). The old path is not bit-stable at those pixels either, so this is rasteriser noise, not state. |

No difference is unexplained, and no state, layout, copy, colour or photo pixel differs. Timing per batch (21 screens): iPhone 17 170 s → 57 s; iPad 11-inch 180 s → 62 s. The whole jobs, including build and unit tests for the first, ran 409 s and 377 s (`/tmp/lightly-heavy.log`: `ios-runner-validate-iphone17`, `ios-runner-validate-ipad11-landscape`).

**Measured demonstration (iPhone 17 portrait light default, all 21 slice-2 screens, one build, `22d673f`, local-change fingerprint `a2a5c3a3691f859d`).** Components come from timestamps the app (`--capture-timing`) and the test write with the same clock. Launch = from the test's launch call to the app's first event. Setup = driver navigation and reset (runner), or app start to scenario applied (old path). Render = scenario applied until `settleRendering` returns. Readiness = render done until the screenshot starts. Capture = screenshot taken and written.

| Batch | Job (heavy log) | Launches (counted) | Launch | Setup | Render | Readiness | Capture | Sum |
|---|---|---|---|---|---|---|---|---|
| Old, launch per screen | `capture-ios-iphone17-light-default-launch` 225 s | 21 | 56.0 s | 15.9 s | 7.0 s | 81.3 s (fixed sleeps) | 3.4 s | 163.7 s |
| Runner | `capture-ios-iphone17-light-default-session` 103 s | 1 | 6.5 s | 7.9 s | 4.8 s | 33.3 s | 3.0 s | 55.5 s |
| Runner after the fix below | `capture-ios-iphone17-light-default-session-after` 87 s | 1 | 6.8 s | 11.1 s | 7.4 s | 4.1 s | 4.8 s | 34.2 s |

The runner's largest component was readiness: 32.2 s of it was the test noticing the app's signal, because XCTest refreshes an accessibility query (and an `NSPredicate` expectation) about once a second. Fix: the app also writes the sequence to `<command file>.ready`, and the test polls that file, and the acknowledgement, every 10 ms. Detection fell from 32.2 s to 0.14 s. The rest of readiness is the test's assertion that the screen's own element exists (3.9 s, an accessibility query per screen). The job also carries about 50 s of simulator boot and shutdown outside the batch. The builds before the two runs were `build-ios-runner-demo` (46 s) and `build-ios-runner-detect-fix` (27 s).

Equivalence: the old and new captures from the same build differ only at the spinner (`loading`, `developing`, `saving`: 811–845 px in the 65 px spinner square, M8) and by 1 level in 1–55 px elsewhere. Every one of those pixels lies on an anti-aliased stroked icon: close (20–32, 80–88) pt, compare/undo (68–112, 80–92) pt, the Favourites star in the category row (100–104, 576) pt, the star by the preset name (24–32, 680–692) pt, the tool dock (116–120, 800–808) pt, and the Share icon in `saved`. The runner's captures before and after the fix are identical except 59 and 4 such icon pixels.

**Did the old path photograph screens before rendering finished?** No, for the screens measured. It waited for an element and then a fixed time (2.5 s; 1.5 s for `saved`), not for a render signal. In the measured batch every screenshot started 1.7–4.3 s after the app's render-complete event, and the photo areas match the runner's captures exactly. The earlier matrix captures (1a4503c, 7356591) used the same method but have no timestamps, so this cannot be proven for them; they are already marked STALE and will be replaced by runner captures.

Since validation, the capture test gained one argument: in the Simulator, Background screens may use subject mattes that Vision computed on macOS (slice 3; see docs/v1/slice3-ios.md). This does not touch the slice-2 screens; the tool version is now `editor-capture-4` (ready file).

### Favourites reorder (the coordinator's failing UI test)

`WelcomeAndMoreUITests.testFavouritesCanBeRemovedAndReordered` failed at line 166 because of **a defect in the code, not in the test**. The page reordered through a system drag session (`onDrag`/`onDrop`). That needed a long-press lift and changed the order only when the system delivered `dropEntered` over another row, so a press-and-drag of the handle sometimes moved nothing. Fixed in 9df579b (a direct drag gesture on the handle: the row follows the finger and takes the slot it passes) and 476ab35 (the handle's gesture takes priority over the page's scroll view). The test is unchanged. Targeted run on the working tree containing both commits: **5 of 5 passed** (job `ios-slice3-build-reorder-captures`). An earlier batch run failed 2 of 3, but that batch started building at 19:06:02, while 9df579b (19:06:51) and 476ab35 (19:07:14) were still being committed, so its app need not contain them.

### Deviations (expected / observed / evidence)

| # | Cells | Expected (approved) | Observed (native) | Evidence | Cause / action |
|---|---|---|---|---|---|
| D1 | all | Develop screens with Auto applied: dot filled, no notice, stop zero "Auto"; `developed` with the "Developed" toast | Auto dimmed, the unavailable notice, "Original"; `developed` unreachable | every `compare/*/model-unavailable.png`, `dev-*.png` | No shippable Auto model (dependency D1). Blocked, not a design change |
| M1 | all reviewed | Status bar 9:41, prototype icons | Simulator status bar (time, Wi-Fi, battery %) | all captures | System UI |
| M2 | iPad (all) | Top safe area 24 pt (`DEVICES.safe.top`) | iPadOS 26 status bar 32 pt: top bar and photo start 8 pt lower, photo 8 pt shorter | `compare/ipadpro11-portrait-*/*` | Platform safe area; needs the user's acceptance or a decision to draw under the status bar |
| M3 | large text cells | Text at ×1.24 with the browser's metrics | Same point sizes (Dynamic Type XXL, ×1.235) but SF's optical tracking makes lines ~4 % narrower, so some wraps differ: "The Walking Dead 03" fits on one line (Pro Max large), notices wrap one word later | `compare/iphone17promax-portrait-light-large/dev-large.png`, `compare/iphone17-portrait-light-large/dev-fav-full.png` | Text rendering; needs a decision (matching would mean overriding iOS's system tracking) |
| M4 | default text: iPhone 17 (`dev-long-name`); iPad 11-inch landscape (`dev-fav-full`, `dev-bw`, `dev-portrait-photo`) | "Landscape 15 - Winter / Wonderland" | "Landscape 15 - / Winter Wonderland" | `compare/iphone17-portrait-light-default/dev-long-name.png` | Same text-metric cause as M3 at default size |
| M5 | `compare`, `saving`, `saved` (all) | Effects tool shows the "used" dot (the screen's setup turns a vignette on) | No dot | `compare/*/compare.png` | The Effects tool is slice 4; the state cannot be set up yet |
| M6 | `dev-fav-replace` (all cells) | "Cancel" in the sheet head at 17 pt (`.sheethead` font inherited) | 15 pt | `compare/iphone17-portrait-light-large/dev-fav-replace.png` | Fixed in 7278bfc; the runner captures at ea75592 match in every cell |
| M7 | all photo screens | The prototype simulates each Look with a CSS filter | The real preset rendered from the pack recipe | every `dev-*` capture | Expected: the reference does not process photographs |
| M8 | `loading`, `developing`, `saving` | `.spinner` drawn still | The same ring, turning | — | See UX conflict 3 |
| M9 | `dev-favourites`, `dev-portrait-photo` (all) | The prototype's CSS stand-in for "5 - (Portrait) - Glow" | Coarse, coloured grain over the whole photo | `compare/*/dev-portrait-photo.png` | The preset's grain (55) with the uncalibrated `GRAIN_K` and `GRAIN_REF_LONG`. Rendering-v2 revision 1 (ported in ec1df87) removed the colour noise and the small-preview aliasing; the strength remains until Lightroom references exist (contract-fixes-1 §3). Recaptured at ec1df87 in every cell |
| X1 | `loading`, `developing` (Pro Max and iPad) | `.progress` shrinks to its content | The box was as wide as its maximum | earlier captures | Defect, fixed in 7356591; the recaptures match |
| X2 | `developing` on iPad 11-inch landscape (4 cells) | `.progress` is a mark inside `.imgbox`, so it is at most half the *photo's* width | The box was capped at half the screen's width, so it was wider than the prototype's and its subtitle did not wrap | runner captures at ea75592 | Defect, fixed in 5976127; the runner captures match in all four cells |

## Tests

Final run at 7278bfc, through `scripts/heavy`, iPhone 17 simulator (iOS 26.5), Large text:

- **Unit (`LightlyTests`): 241 tests, 0 failures, 3 skipped.** The skips are the timing assertions, which run only in optimised builds (`DevelopPerformanceTests` bake and parse, `EditorSessionTests` scrubbing); their optimised run passed (numbers above). New in slice 2: `DevelopParityTests` (7), `EditRecipeCodecTests` (7), `EditorSessionTests` (25: opening and Auto states, Portrait visibility, ruler preview/commit/undo, category browsing and context, Amount, favourites and Replace, Compare, whole-recipe undo/redo, spatial stages, tiles without seams, preview and Save copy of the same recipe, the four metadata combinations, save errors, cancel writes nothing, closed sessions, scrubbing staleness, a photo opened while the library loads), `DevelopPerformanceTests` (3, including the bundled-pack packaging check), `PreviewFrameTimingTests`, `AppStateTests` photo switching (2), `ControlContrastTests` on the approved tokens (4), `ExportColorPipelineTests` through Save copy.
- **UI (`LightlyUITests`): 28 tests, 0 failures, 6 skipped** (the capture tests, which run only with `LIGHTLY_CAPTURE_DIR`). `EditorFlowUITests` covers the picker into the unavailable state, loading with the photo visible, ruler drag and one-step undo/redo, browsing with the Applied line and the tab row scrolled by a finger, Amount with Done, the favourites full notice and Replace, saving and saved, leaving with unsaved edits, Portrait only for a photo with a person, the marked development stub, and Retry / Continue with original.
- `scripts/check_app_icon.sh` passes as the app target's last build phase; the pack check is `DevelopPerformanceTests.testBundledPackIsTheFullFormatThreeCatalogue`.
