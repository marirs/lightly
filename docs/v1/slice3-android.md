# Lightly 1.0, Android slice 3: Background (and Portrait, blocked)

Scope: Background › Focus & Blur, Change background and Refine edges, with Focus depth, on the approved `docs/ui/app/` design; Portrait as far as it is not blocked. Contracts: `shared/contracts/rendering-v2` (stages `background.replace`, `background.focus`), `shared/contracts/edit-recipe-v1.json` (`tools.background`), and the rendering specification in [depth-evaluation.md](depth-evaluation.md) §6.

**Status: in progress.** Nothing here is exact-match verified; see "Comparison" at the end.

## Working, experimental, blocked

| Area | State | Notes |
|---|---|---|
| Background panel | **working (UI)** | All approved states and copy: the Focus & Blur / Change background segment; Lens/Soft/Swirl/Motion tabs; Bokeh options; Glow / Swirl / Direction; Blur; Focus depth; Refine edges entry; Image / Colour / Gradient tabs with the approved swatches and gradients; Scale; "Remove background change"; the two notes; "Finding the subject…" (cancellable, on the photo and in the panel); "Couldn't separate the subject" with Try again; "No clear subject found". The target ring and tap-to-focus on the photo. |
| Recipe | **working** | Every control commits `tools.background` as one undo step on release (sliders preview while dragging). Depth source and the derived-result references (`depth.map`, `subject.matte`) are written with the edit; the focus target and the depth under it are resolved at the tap and stored (`depth.focusDepth`). |
| Embedded depth | **working** | Dynamic Depth 1.0 and GDepth (standard and extended XMP), 16-bit PNG and JPEG depth items, EXIF orientation applied; a port of `experiments/depth/embedded/dynamic_depth.py`. Checked on synthetic containers; the evaluation's real-layout fixtures are checked when present (git-ignored). A real Pixel Portrait photo is still needed (depth-evaluation.md E2 open item). |
| Focus & Blur renderer | **working (CPU)** | Port of `experiments/depth/refocus.py`: §R1 highlight expansion, §R2 scene planes (with or without a matte), §R3 focus, §R4 signed CoC with tent layers, §R5 kernels (round, hex, heart, star, Gaussian, motion, swirl), §R6 compositing with pull-push, §R7 reduced-resolution layers; preview K = 4, export K = 8. Kernels, CoC and the highlight curve match reference vectors; whole renders are not yet compared against `refocus.py` (needs OpenCV and SciPy, which no local venv has). |
| Change background renderer | **working (with a matte)** | Colour, CSS gradient, bundled photo or a picked photo (aspect-fill, scale, position), graded with the photo's global colour (rendering-v2 §1), placed behind the subject (§R2.4 "plane"). Reachable only when a subject matte exists. |
| Save copy | **working (approximate)** | Background renders once at the analysis size (≤ 1600 px long edge, K = 8); each full-resolution tile keeps its in-focus pixels and takes defocused or replaced pixels from that render (`BackgroundStage.composeTile`). Bounded memory; not a full-resolution refocus. |
| Monocular depth (Depth Anything V2 Small) | **working, behind the release gate** | `LiteRtDepthEstimator`, using the standalone LiteRT runtime (Interpreter API), CPU only. Model: our conversion `da2_small_518x392_wi8.tflite` (SHA-256 `8e719085…8078`, 26.4 MB). Source: the Apache-2.0 weights `depth-anything/Depth-Anything-V2-Small-hf@5426e4f`. **Release gate "pending legal sign-off (training data)":** debug builds package the model when the git-ignored file is present; release builds package it only with `-PlightlyDepthLegalSignOff=true`. The build checks the model's SHA-256 when it bundles it. Without the model, or if it fails to load or run, the app shows the approved unavailable state; it never crashes. Measured on the Pixel 9 Pro emulator for the `woman` photo: wall nearness 0.01–0.02, face 0.37–0.39, jacket 0.81. That is the correct ordering. |
| Subject segmentation (D3) | **blocked** | Behind `SubjectSegmenter`; `PendingSubjectSegmenter` throws "unavailable". No SDK chosen (MediaPipe / ML Kit evaluation pending on the dev phones). Change background and Refine edges therefore show the approved failure state. |
| Refine edges | **working (with a matte)** | Panel (note, Add/Remove, Brush size, Done), the subject tint on the photo, and brushing: each stroke is stored in `subject.refinements` (radius from Brush size, up to 5 % of the long edge) as one undo step and applied to the matte before rendering (`MatteRefinement`). Reachable only when a matte exists (D3). |
| Portrait | **blocked (D3)** | Face detection and landmarks are D3. The tool keeps its debug-only development stub. |
| Bundled background photos | **debug only** | The licence for redistribution in a release is unconfirmed, so only debug builds package them. The sources are listed below for the owner's decision. |

## What a user sees in this build

- A photo with embedded depth (Pixel Portrait, Dynamic Depth): Focus & Blur works fully (depth-only refocus, no subject plane); Change background and Refine edges show "Couldn't separate the subject. Your other edits are kept."
- Any other photo, debug build with the model: Focus & Blur works from estimated depth. Change background and Refine edges show the approved failure state, because there is no matte until D3 is resolved.
- Any other photo, release build without legal sign-off: Focus & Blur, Change background and Refine edges all show the approved failure state. No mask-only or uniform blur is substituted (§R8).

## LiteRT runtime (approved for this integration)

| Item | Value |
|---|---|
| Artifacts | `com.google.ai.edge.litert:litert:1.4.2` (AAR SHA-256 `9b02cdf9…a74`) and its only dependency `com.google.ai.edge.litert:litert-api:1.4.2` (`66c2ba80…57c`), from Google Maven |
| Licence | Apache-2.0 (both POMs) |
| Why 1.4.2 and not 2.x | 2.2.0 pulls in `ai-delivery` 0.1.1-alpha01 (AiPack model downloads), Guava and kotlinx-coroutines-guava. Its manifest also adds the FOREGROUND_SERVICE and FOREGROUND_SERVICE_DATA_SYNC permissions. 1.4.2's manifests declare nothing. |
| Merged manifest | `verify<Variant>ManifestPrivacy`, run by every assemble, fails the build if any of these appear: INTERNET, ACCESS_NETWORK_STATE, datatransport, firebase, gms measurement, analytics, telemetry or crashlytics. Debug and release both pass, and nothing had to be removed with `tools:node="remove"`. |
| APK size | Native `libtensorflowlite_jni.so`, stored uncompressed: arm64-v8a 4.48 MB, armeabi-v7a 2.64 MB, x86 6.59 MB, x86_64 6.27 MB, **19.98 MB for all four ABIs** (an arm64 device install from an ABI split carries 4.48 MB). The debug APK also carries the model, 27.65 MB stored uncompressed for memory-mapping. Debug APK: 37.6 MB → 82.0 MB. Release APK: 45.2 MB with the runtime and without the model. No same-revision release build without LiteRT exists, so the release delta is taken from the native-library entries. |
| Accelerators | CPU only. The evaluation's NPU → GPU → CPU order needs the 2.x CompiledModel API or the GPU delegate artifact, and neither is approved: DEFERRED. |
| Emulator | On the arm64 emulator (Apple M-series host), the XNNPACK delegate's initialisation kills the process with SIGILL (tombstone in `libtensorflowlite_jni.so`, `pthread_once`). On emulators (`Build.HARDWARE` ranchu/goldfish) the estimator therefore uses the built-in kernels; devices keep XNNPACK. Emulator timings do not represent devices. Measured on the emulator: about 60–90 s from opening Background to the first Focus & Blur preview in a debug build. Device timing is pending, because the dev phones are not connected. |

## Background photos (debug only, owner's decision)

From `docs/ui/assets/photos/SOURCES.csv`. All are under the Unsplash License, and each ships with a `_thumb` file from the same source.

| File | Source | Author |
|---|---|---|
| landscape_01.jpg | https://unsplash.com/photos/seceda-mountains-in-ortisei-italy-hOhlYhAiizc | Daniela Kokina |
| sunset_03.jpg | https://unsplash.com/photos/low-sun-over-calm-ocean-AksmkMQTdik | Martin Franco |
| wellexposed_02.jpg | https://unsplash.com/photos/a-street-with-houses-and-trees-on-both-sides-rlxo_XrKb6k | Mykyta Kravčenko |
| backlit_02.jpg | https://unsplash.com/photos/a-woman-standing-in-a-field-looking-at-the-sun-9nmReTKwQ3U | Alice Kotlyarenko |

## Contract gaps (reported, shared/ not edited)

| # | Gap | Implemented |
|---|---|---|
| G1 | Maximum blur radius: rendering-v2.json `maxBlurRadius` 0.03 of the long edge; depth-evaluation §R4 says 0.035 | 0.03 (the contract) |
| G2 | Depth of field: rendering-v2.md §7 "half-width depthOfField/100·0.5 around focusDepth"; §R4 says `h = 0.30·(focusDepth/100)^1.5` in disparity units | the contract's; both constants are in `Refocus.FocusConstants` only |
| G3 | rendering-v2 allows `depth.source = subject-matte` (two planes, no depth); §R8 says never fake depth with a mask-only blur | `subject-matte` is never written with blur; blur needs depth |
| G4 | Depth direction: the recipe stores depth 0 near / 1 far, the renderer works in disparity (1 near) | `focusDepth = 1 − nearness`, documented in `NormalisedDepth` |
| G5 | No parity goldens for the renderer in `shared/fixtures` (§R9 asks for them) | kernel/CoC/highlight vectors only, generated locally |
| G7 | Pull-push in `refocus.py` stops when the short side is ≤ 4 px and leaves uncovered cells of that coarsest level at 0, so large disocclusions fill toward black instead of from neighbours (Kraus & Strengert continue until the top level is covered) | ported as in the reference and pinned by a test; a fix belongs in the reference/spec first |
| G6 | `replacementDepth` (recipe) vs §R2.4 placement rule (median of the original background, capped behind the subject) | §R2.4 rule; `replacementDepth` is carried but not used |

## Comparison (Pixel 9 Pro portrait, light/default, runner)

Captures are in `~/.codex/artifacts/lightly/v1/captures/android/slice3-p9-light-default-2`, each with a JSON sidecar. They were taken with APK `a59c2da7…`, which is the tree of the slice-3 commit except for its diagnostic logging. References come from `scripts/reference_cache.py`.

| Screen | Status | Notes |
|---|---|---|
| bg-separating | **mismatch: S1 only** | Overlay box, panel notice, Cancel, tabs and hierarchy match. The only difference is the system status bar (S1). |
| bg-failed | **mismatch: S1, S8** | The failure notice, Try again, the selected segment and the Develop "used" dot match. The photo shows Portrait 13's grain far stronger than the reference (S8, below). |
| bg-focus | **deviation: B1, B2** | Panel layout and copy match: Lens tab, the bokeh row with round selected, Blur 55, Focus depth 40, Refine edges and the hint. **B1:** the background is barely blurred. With the contract's constants, Focus depth 40 gives a sharp band of ±0.20 and a maximum radius of 0.03 of the long edge, so the wall, 0.37 below the face, gets about 22 % of the maximum radius. The spec (§R4: h = 0.076, radius 0.035) would blur it clearly, as the reference shows. This is contract gap G1/G2 and needs a decision; it was not changed. **B2:** the target ring sits at the image centre (§R3's default when there is no matte), whereas the reference puts it on the subject. Without D3 there is no subject; blocked on D3. |
| bg-soft, bg-swirl, bg-motion | **deviation: B1, B2** | As bg-focus, with the style tab selected and the style's own control row. |
| bg-no-subject | **blocked (D3)** | "No clear subject found" needs a segmenter to say there is no subject. Without one, the panel shows Focus & Blur with Blur 0. |
| bg-refine, bg-change-*, bg-replaced-blur | **blocked (D3)** | These need a subject matte. |

**S8 (new, slice-2 rendering, pending investigation):** Portrait 13 renders with very coarse, strong grain at preview size. The same grain appears on dev-portrait-photo in the slice-2 runner captures. The earlier fixed-wait captures never showed a rendered preset, so this was hidden until now. The reference shows no grain because the prototype simulates looks (S3). Whether the native grain matches rendering-v2 F2 at preview scale has not yet been checked against the parity fixtures.

Other layouts are pending.
