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
- `compare/<cell>/<screen>.png`: reference left, native right.

**Reference variant used for the Develop screens.** Every approved Develop screen is drawn with Auto *applied* (`newSession` sets `auto: 'applied'`). No Auto model ships (D1), so the build can only show the approved unavailable state. The references for `model-unavailable`, `dev-*`, `compare`, `saving` and `saved` were therefore rendered with the approved renderer and the screen's own setup plus `s.auto = 'unavailable'` (the approved combination of "presets still work" with that screen). The screens exactly as registered (Auto applied, no notice) are **blocked by D1** in every cell. `loading`, `developing` and `develop-failed` are compared as registered.

**Status of the 24 cells** (21 screens each). Capture runs were stopped at the coordinator's request; nothing below is inferred from another cell.

| Cell | Native captured (final build 1a4503c) | Reviewed side by side |
|---|---|---|
| iphone17 portrait light default | 21/21 | all 21 (contact sheets 1, 3, 5; sheets 2, 4, 6 reviewed on the capture before 1a4503c; that commit changed only the tab row scrolling and disabled-icon dimming, both rechecked) |
| iphone17 portrait light large | 21/21 | 4 screens (`dev-favourites`, `dev-fav-full`, `dev-fav-replace`, `dev-bw`); 17 unverified-pending |
| iphone17 portrait dark default | 21/21 | 4 screens (`dev-favourites`, `dev-fav-full`, `dev-fav-replace`, `dev-bw`); 17 unverified-pending |
| iphone17 portrait dark large | 21/21 | 0; 21 unverified-pending (an earlier build's `dev-preset`/`dev-amount` were reviewed and found the dark-mode tab bug fixed in 773adec) |
| iphone17promax portrait light default | 21/21 | 4 screens (`dev-original`, `dev-preset`, `dev-dragging`, `dev-browse`); 17 unverified-pending |
| iphone17promax portrait light large | 21/21 | 4 screens (`dev-large`, `dev-long-name`, `dev-amount`, `dev-starred`); 17 unverified-pending |
| iphone17promax portrait dark default | 21/21 | 0; 21 unverified-pending |
| iphone17promax portrait dark large | 21/21 | 0; 21 unverified-pending |
| ipadpro11 portrait light default | 21/21 | 4 screens (`dev-favourites`, `dev-fav-full`, `dev-fav-replace`, `dev-bw`); 17 unverified-pending |
| ipadpro11 portrait light large | 21/21 | 0; 21 unverified-pending |
| ipadpro11 portrait dark default | 21/21 | 0; 21 unverified-pending |
| ipadpro11 portrait dark large | not captured | 21 unverified-pending |
| ipadpro11 landscape light default | not captured on the final build | 21 unverified-pending (an earlier build's `dev-preset` and `dev-fav-replace` matched apart from deviation M2) |
| ipadpro11 landscape light large, dark default, dark large | not captured | 63 unverified-pending |
| ipadpro13 portrait and landscape, all 8 cells | not captured | 168 unverified-pending |

No cell is recorded as exact-match verified as a whole: every reviewed cell carries at least the deviations below.

### Results for the reviewed screens

Matched in layout, controls, copy, hierarchy, colours, icons and state (apart from the deviations listed for that cell): `loading`, `developing`, `model-unavailable`, `develop-failed`, `dev-original`, `dev-preset`, `dev-dragging` (Fine shown), `dev-browse` (Applied context, selected tab at 120 pt), `dev-large`, `dev-amount`, `dev-starred`, `dev-favourites`, `dev-fav-full`, `dev-bw`, `dev-landscape-photo`, `dev-portrait-photo` (Portrait offered by Vision), `saving`, `saved` on iPhone 17 light default; the four listed screens in each partially reviewed cell; side layout (`dev-preset`, `dev-fav-replace`) on iPad 11-inch landscape (earlier build).

### Deviations (expected / observed / evidence)

| # | Cells | Expected (approved) | Observed (native) | Evidence | Cause / action |
|---|---|---|---|---|---|
| D1 | all | Develop screens with Auto applied: dot filled, no notice, stop zero "Auto"; `developed` with the "Developed" toast | Auto dimmed, the unavailable notice, "Original"; `developed` unreachable | every `compare/*/model-unavailable.png`, `dev-*.png` | No shippable Auto model (dependency D1). Blocked, not a design change |
| M1 | all reviewed | Status bar 9:41, prototype icons | Simulator status bar (time, Wi-Fi, battery %) | all captures | System UI |
| M2 | iPad (all) | Top safe area 24 pt (`DEVICES.safe.top`) | iPadOS 26 status bar 32 pt: top bar and photo start 8 pt lower, photo 8 pt shorter | `compare/ipadpro11-portrait-*/*` | Platform safe area; needs the user's acceptance or a decision to draw under the status bar |
| M3 | large text cells | Text at ×1.24 with the browser's metrics | Same point sizes (Dynamic Type XXL, ×1.235) but SF's optical tracking makes lines ~4 % narrower, so some wraps differ: "The Walking Dead 03" fits on one line (Pro Max large), notices wrap one word later | `compare/iphone17promax-portrait-light-large/dev-large.png`, `compare/iphone17-portrait-light-large/dev-fav-full.png` | Text rendering; needs a decision (matching would mean overriding iOS's system tracking) |
| M4 | iPhone 17 light default | "Landscape 15 - Winter / Wonderland" | "Landscape 15 - / Winter Wonderland" | `compare/iphone17-portrait-light-default/dev-long-name.png` | Same text-metric cause as M3 at default size |
| M5 | `compare`, `saving`, `saved` (all) | Effects tool shows the "used" dot (the screen's setup turns a vignette on) | No dot | `compare/*/compare.png` | The Effects tool is slice 4; the state cannot be set up yet |
| M6 | `dev-fav-replace` (all captured cells) | "Cancel" in the sheet head at 17 pt (`.sheethead` font inherited) | 15 pt | `compare/iphone17-portrait-light-large/dev-fav-replace.png` | **Fixed in 7278bfc after the captures; unverified-pending recapture** |
| M7 | all photo screens | The prototype simulates each Look with a CSS filter | The real preset rendered from the pack recipe | every `dev-*` capture | Expected: the reference does not process photographs |
| M8 | `loading`, `developing`, `saving` | `.spinner` drawn still | The same ring, turning | — | See UX conflict 3 |

## Tests

Final run at 7278bfc, through `scripts/heavy`, iPhone 17 simulator (iOS 26.5), Large text:

- **Unit (`LightlyTests`): 241 tests, 0 failures, 3 skipped.** The skips are the timing assertions, which run only in optimised builds (`DevelopPerformanceTests` bake and parse, `EditorSessionTests` scrubbing); their optimised run passed (numbers above). New in slice 2: `DevelopParityTests` (7), `EditRecipeCodecTests` (7), `EditorSessionTests` (25: opening and Auto states, Portrait visibility, ruler preview/commit/undo, category browsing and context, Amount, favourites and Replace, Compare, whole-recipe undo/redo, spatial stages, tiles without seams, preview and Save copy of the same recipe, the four metadata combinations, save errors, cancel writes nothing, closed sessions, scrubbing staleness, a photo opened while the library loads), `DevelopPerformanceTests` (3, including the bundled-pack packaging check), `PreviewFrameTimingTests`, `AppStateTests` photo switching (2), `ControlContrastTests` on the approved tokens (4), `ExportColorPipelineTests` through Save copy.
- **UI (`LightlyUITests`): 28 tests, 0 failures, 6 skipped** (the capture tests, which run only with `LIGHTLY_CAPTURE_DIR`). `EditorFlowUITests` covers the picker into the unavailable state, loading with the photo visible, ruler drag and one-step undo/redo, browsing with the Applied line and the tab row scrolled by a finger, Amount with Done, the favourites full notice and Replace, saving and saved, leaving with unsaved edits, Portrait only for a photo with a person, the marked development stub, and Retry / Continue with original.
- `scripts/check_app_icon.sh` passes as the app target's last build phase; the pack check is `DevelopPerformanceTests.testBundledPackIsTheFullFormatThreeCatalogue`.
