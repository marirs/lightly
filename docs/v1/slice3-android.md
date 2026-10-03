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
| Monocular depth (Depth Anything V2 Small) | **blocked** | The LiteRT conversion exists locally (`experiments/depth/models/converted/da2_small_518x392_wi8.tflite`, SHA-256 `8e719085ce210eb4fb8e737ae9bca4f25e4e35b3aeafb80c468c3ff6c4eb8078`, 26.4 MB, from the Apache-2.0 weights `depth-anything/Depth-Anything-V2-Small-hf@5426e4f`). Running it needs the LiteRT runtime library, which is not a project dependency: adding it is a library download that has not been approved. Implemented and tested: the model input contract (518 × 392 stretch, ImageNet normalisation, NCHW) and the output pipeline (percentile normalisation, guided-filter upsampling). The runtime sits behind `DepthEstimator`; the app wires `UnavailableDepthEstimator`. When enabled it must sit behind the release gate "pending legal sign-off (training data)". |
| Subject segmentation (D3) | **blocked** | Behind `SubjectSegmenter`; `PendingSubjectSegmenter` throws "unavailable". No SDK chosen (MediaPipe / ML Kit evaluation pending on the dev phones). Change background and Refine edges therefore show the approved failure state. |
| Refine edges | **working (with a matte)** | Panel (note, Add/Remove, Brush size, Done), the subject tint on the photo, and brushing: each stroke is stored in `subject.refinements` (radius from Brush size, up to 5 % of the long edge) as one undo step and applied to the matte before rendering (`MatteRefinement`). Reachable only when a matte exists (D3). |
| Portrait | **blocked (D3)** | Face detection and landmarks are D3. The tool keeps its debug-only development stub. |
| Bundled background photos | **debug only** | The four approved photos come from the licensed sample set; their licence for redistribution in a release is unconfirmed, so only debug builds package them. |

## What a user sees in this build

- A photo with embedded depth (Pixel Portrait, Dynamic Depth): Focus & Blur works fully (depth-only refocus, no subject plane); Change background and Refine edges show "Couldn't separate the subject. Your other edits are kept."
- Any other photo: after "Finding the subject…", Focus & Blur, Change background and Refine edges all show the approved failure state, because neither depth nor a matte can be computed here. No mask-only or uniform blur is substituted (§R8).

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

## Comparison

**Pending.** No Background screen has been compared yet.
- Debug capture states exist for `bg-separating`, `bg-failed`, `bg-focus` and `bg-no-subject` (25f47bf). They open Background with real separation, which in this build always ends in the approved failure state.
- Of these, only `bg-separating` and `bg-failed` can match their references. `bg-focus`, `bg-no-subject` and every other bg-* screen need depth (LiteRT, blocked) or a matte (D3, blocked), so they are **blocked** rather than pending.
- References come from `scripts/reference_cache.py`.
