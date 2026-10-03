# Contract fixes 1: blur strength, hole fill, depth gaps, grain

Rendering contract v2 **revision 1** (2026-10-03). Both platform ports matched the reference model, but the reference itself was wrong in three places: Focus & Blur barely blurred the background (B1, gaps G1/G2), the pull-push fill went black in large holes (G7), and preset grain was coloured and, at small sizes, aliased (iOS M9, Android S8). This document gives the evidence, each decision, and what each platform must change.

Changed files: `experiments/depth/refocus.py`, `shared/look-pack/reference_model.py` (+ tests), `shared/contracts/{build_rendering_v2.py, rendering-v2.json, rendering-v2.md, edit-recipe-v1.json, schema_check.py, make_edit_recipe_examples.py, make_rendering_goldens.py}`, `shared/contracts/tests/test_rendering_goldens.py`, `shared/fixtures/edit-recipe/*`, `shared/fixtures/rendering/*` (new), `docs/v1/depth-evaluation.md` §6.

`developModel.constantsSha256` is unchanged, so **every `lookVersion` and the look pack are unchanged**; `shared/fixtures/look-pack/` needs no regeneration. The change is versioned by `rendering-v2.json` `"revision": 1` and the change log in `rendering-v2.md`.

Evidence (scripts, JSON results, sheets) is in `~/.codex/artifacts/lightly/v1/contract-fixes-1/`.

## 1. Blur strength (B1, G1, G2)

### What the approved prototype draws
`docs/ui/app/app.js` (`photoHTML`) draws the background as the photo, scaled by 1.04, with CSS `filter: blur(blur/9 px)`, under a sharp subject layer masked by soft ellipses. CSS blur is a Gaussian with σ in CSS pixels. bg-focus, bg-soft, bg-swirl and bg-motion all use the woman photo (`portrait_medium_02`), Blur 55, Focus depth 40 (default) and target (0.40, 0.48) on the face; bg-replaced-blur uses Blur 60. The prototype's blur does not depend on the style.

### Measurement
- **Reference captures** came from `scripts/reference_cache.py` at reference tree `0999277`, assets `89e4fb2`, Chromium 153.0.8010.12.
- **Method.** The photo's rectangle was located in each capture (template match). The equivalent Gaussian σ was then fitted by least squares, allowing a per-channel gain and offset, against the original photo resized to the same rectangle (and scaled 1.04, as the CSS does). The fit used background pixels only: outside the prototype's subject ellipses ×1.15 and outside the Vision matte dilated by 30 px, with a 45 px margin from the edges (321,465 px on Pixel 9 Pro). Sobel edge energy in the same region, relative to the unblurred photo, is a second measure.
- **Check of the method.** On Pixel 9 Pro the fit gives σ = 15.75 device px = 6.00 CSS px, against the nominal 55/9 = 6.11.

| Device (portrait unless stated) | Photo long edge (device px) | Fitted σ (px) | σ / long edge |
|---|---|---|---|
| iPhone 17 | 1129 | 18.5 | 0.0164 |
| iPhone 17 Pro Max | 1377 | 18.5 | 0.0134 |
| Pixel 9 Pro (bg-focus) | 1254–1257 | 15.75–16.0 | 0.0125–0.0128 |
| Pixel 9 Pro (bg-soft, bg-swirl, bg-motion) | 1289 | 15.75 | 0.0122 |
| Pixel 10 Pro XL | 1374 | 15.75 | 0.0115 |
| iPad Pro 11" | 1521 | 12.75 | 0.0084 |
| iPad Pro 13" landscape | 1878 | 12.75 | 0.0068 |

Edge-energy ratio on Pixel 9 Pro: 0.124 for every bg-* screen.

**Native reference on the same photo.** `refocus.py` rendered `portrait_medium_02` at 839×1257, the logical size of the Pixel 9 Pro capture. Its depth was the Depth Anything V2 Small map (`experiments/depth/cache/depth/da2_small`), its matte the Vision matte, and the target (0.40, 0.48). The focal disparity was 0.458, and the wall's disparity 0.006 / 0.012 / 0.018 (p5 / p50 / p95). The same fit was applied, plus edge energy on the face and on the jacket inside the eroded matte (1.0 = sharp).

| Candidate (Lens, round) | σ / long edge | Wall edges | Jacket edges | Verdict |
|---|---|---|---|---|
| Contract v2: R 0.03, h = 0.5·dof/100, ÷(1 − h) | 0.0026 | 0.72 | 0.95 | barely blurred (the Android finding) |
| depth-evaluation §R4: R 0.035, h = 0.30·(dof/100)^1.5, ÷(1 − h) | 0.0040 | 0.51 | 0.74 | a third of the prototype; shoulder blurred |
| §R4 h, ÷(1 − h), R 0.11 | 0.0129 | 0.12 | 0.51 | matches only with a radius that blur 100 never reaches elsewhere |
| §R4 h, ÷(S − h), R 0.055 | 0.0131 | 0.12 | 0.51 | shoulder blurred |
| Per-side scale, R 0.045 | 0.0133 | 0.11 | 0.54 | rejected: different scales in front and behind break the thin-lens ratio |
| h = 0.5·dof/100, ÷(S − h), R 0.055 / 0.06 / 0.065 | 0.0123 / 0.0133 / 0.0143 | 0.13 / 0.12 / – | 0.83 / 0.82 / 0.82 | wall right, shoulder still soft |
| **Chosen:** h = 0.5·dof/100, ÷(S − h), R 0.06, subject in focus | **0.0133** | **0.116** | **1.00** (face 1.00) | matches |

The chosen rule, per style, at the bg-* settings:

| Style | σ / long edge | Wall edge ratio | Face / jacket |
|---|---|---|---|
| Lens (round) | 0.0133 | 0.116 | 1.00 / 1.00 |
| Soft | 0.0129 | 0.113 | 1.00 / 1.00 |
| Swirl | not isotropic (fit 0.023) | 0.109 | 1.00 / 1.00 |
| Motion (0°) | streak along x | 0.96 overall; x-gradient 0.64 (Lens 0.63) | 1.00 / 1.00 |

Motion keeps the wall's horizontal slats sharp because its streak is horizontal at the default Direction. That is the style working as specified (§R5.4), not a strength difference. The sheet `sheet_final.png` puts the reference next to all four styles; `jacket.png` shows the shoulder before the subject rule.

### Decisions
- **maxBlurRadius = 0.06 of the long edge** [contract]. It was 0.03 in the contract and 0.035 in §R4. The prototype's σ / long edge varies by phone from 0.0115 to 0.0164, because its blur is fixed in CSS pixels. 0.06 gives 0.0133, the middle of that range: −19 % against iPhone 17, +16 % against Pixel 10 Pro XL, +4 to +9 % against Pixel 9 Pro. Both the prototype and the renderer are linear in Blur, so bg-replaced-blur (Blur 60) scales the same way.
- **Depth of field: h = 0.5·depthOfField/100** [contract]. This keeps the contract's value. §R4's 0.30·(dof/100)^1.5 is replaced, and depth-evaluation.md is amended.
- **CoC scale: S − h, with S = max(d_f, 1 − d_f)** [contract]. It was 1 − h. Normalised disparity always spans [0, 1], so S is the distance from the focal plane to the farthest content, and Blur sets how blurred that content is, as in the prototype. One scale serves both sides of the focal plane, so the blur ratio between any two depths is still the thin-lens ratio.
- **Subject in focus** [contract]. When the focus is on the subject (M(target) ≥ 0.5, or a null target with a subject), the subject plane's CoC is 0. The prototype keeps the whole person sharp. Focusing on the background still blurs the subject.
- **True depth falloff is kept (§R8).** Only the background plane's depth sets its blur. On `portrait_light_01`, whose wall recedes, the background's CoC runs from 0.10 to 0.98 of R_max (p5–p95) at the default target. On `backlit_02`, the ground in front of the focal plane blurs too. Nothing becomes a flat mask blur.

### Conflicts that need the product owner (not changed)
1. **The prototype's blur depends on the device**, because it is in CSS pixels. Tablets show half the phone strength (0.0068–0.0084 of the long edge). A resolution-independent renderer, required so that preview and export match, cannot reproduce every device: with 0.06, tablets blur about 1.6–2× more than their prototype screens. Either accept the phone calibration on tablets, or decide otherwise.
2. **Styles.** The prototype draws the same Gaussian for Lens, Soft, Swirl and Motion. The native styles differ by design (the kernels in §R5, the approved Bokeh, Glow, Swirl and Direction controls). The strength matches; the texture of the blur cannot.
3. **Subject edge.** The prototype's elliptical mask blurs the outer hair and leaves a blurred halo around it. The native matte keeps hair edges sharp. The prototype labels its mask "illustration only".
4. **Ring position (Android B2)** is unrelated to this fix and still blocked on D3.

## 2. Pull-push hole fill (G7) and gaps G3–G6

### G7, fixed
The pull stopped when the short side was ≤ 4 px. At that level it divided by the coverage, so any cell with no coverage stayed 0, and a large disocclusion filled toward black. A hole covering 83 % of a 120×90 plane filled with 0.0017 instead of the border colour.

Now the pull goes to 1×1, as Kraus & Strengert do. The 2×2 box mean is exact: an odd last row or column is repeated first (OpenCV's INTER_AREA is no longer used, so the step is portable). The push uses half-pixel bilinear upsampling. The same hole now fills with the border colour to within 1e-5. `test_large_hole_fills_from_its_neighbours_not_black` and `test_hole_takes_the_colour_of_the_nearer_neighbour` cover it, and `shared/fixtures/rendering` holds the golden (`pullPush/large-hole`). The spec text is in depth-evaluation.md §R6 and rendering-v2.md §7.1.

### G3 – G6
| Gap | Resolution |
|---|---|
| **G3** `depth.source = subject-matte` vs §R8 | `subject-matte` now means **no depth**. The edit-recipe reader rejects `blur > 0` with it (`schema_check`, new `invalid-blur-without-depth.json`), and the renderer never blurs from a matte. The token is kept, so v1 documents keep their bytes and no schema version changes. `background-focus-subject-matte-motion.json` became `background-focus-estimated-motion.json`; `background-focus-swirl.json` and `demo-combined.json` now carry an estimated map. |
| **G4** depth direction | The recipe stores depth (0 near, 1 far: `map`, `focusDepth`); the renderer works in disparity, `D = 1 − depth`. A stored `focusDepth` is used as `d_f = 1 − focusDepth` and never re-resolved. A null one is resolved with §R3 at the target, or at the default target. `refocus.render(focal_override=…)` takes it; `FocusBlurParams.subject_focus` covers a null target. |
| **G5** no renderer goldens | `shared/fixtures/rendering/` (generator `shared/contracts/make_rendering_goldens.py`, test `test_rendering_goldens.py`) holds: the CoC, half-width, S and R_max vectors; the highlight curve; every kernel; two pull-push cases; nine whole renders (every style and bokeh, subject and background focus, depth only, replaced background) with their inputs; and the grain cases. Tolerances are in `index.json`. |
| **G6** `replacementDepth` vs §R2.4 | §R2.4 "plane" wins. The placement is a pure function of the stored map and matte, so it is recomputed; `replacementDepth` is not read, and writers write 1. "Own depth" for photo backgrounds is not in the 1.0 contract (the recipe has no field for the replacement's depth map). |

## 3. Grain (iOS M9, Android S8)

618 of the 2,591 presets carry grain (the pack's `recipe.finishing.grain`). Amounts: median 20, quartiles 10 and 30, maximum 100. Sizes: median 25, range 0–65. "5 - (Portrait) - Glow" (portrait stop 13) has amount 55, size 25 and roughness 59.

### Defects found and fixed
1. **Coloured grain.** `_with_lightness` kept OKLab a and b fixed while L moved, so every darkened grain cell became more saturated and every lightened one less. On the skin of `portrait_medium_02` with Portrait 13, OKLab saturation (C/L) varied by **12.7 %** (std), with hue noise of 0.8°. Gamut clipping was secondary: 5.8 % of the pixels clipped.
   - **Fix:** a and b scale with L. Scaling (L, a, b) by r scales linear RGB by r³, so hue and saturation are kept exactly.
   - **After:** saturation noise 1.3 %, hue noise 0.4°, 3.4 % of the pixels clipped. What remains comes from clipping at white and black.
2. **Aliasing at small render sizes.** With more grain cells than pixels, the bilinear "upsample" became a point sample at 1.5× amplitude (the 2/3 normalisation assumes interpolation). For size 25 (600 cells), this happens below 1,200 px on the long edge; for size 0, below 2,400 px.
   - **Fix:** render at s = ceil(2·cells/longEdge) times the size and take the mean of each s×s block. A 300×400 preview now equals the 900×1200 export averaged over 3×3 blocks, exactly (test).
   - **Scope:** this was **not** the cause of M9/S8. Portrait 13 (size 25) previewed at 1,600 px has s = 1.
3. **GRAIN_K's documented meaning** is off by 1.2. lr_model says "L standard deviation for amount 100", but the midtone weight is 1.2 at L = 0.5, so mid-grey gets 0.144. This is documented in rendering-v2.md F2. The constant is unchanged, because there is no target to change it to.

### What is still wrong, and why it is not fixed here
After the fixes, Portrait 13 still moves skin lightness by a standard deviation of **0.075** OKLab L, in blobs about 8 px across at 1,600 px (roughness 59 weights the coarse layer). That is the "extreme" look. It comes from the constants: `GRAIN_K` 0.12 and `GRAIN_REF_LONG` 1200 are lr_model's first guesses and are **calibrated against nothing**. Nothing in the repository compares them with Lightroom.

No Lightroom export exists locally. `experiments/presets/lr_kit/{kit,kit-pilot,kit-v2}/exports/` are empty (D8, plan.md). So no target was invented, and no scale factor against Lightroom's amount, size or roughness can be established. Whether Lightroom scales grain with image resolution is unknown too. It decides whether `GRAIN_REF_LONG` should be per long edge at all.

### Lightroom references needed (smallest set)
Lightroom's grain pattern is random, so only statistics are compared:
- the L standard deviation in flat patches, against a grain-off export;
- the autocorrelation length;
- the chroma of the grain.

Inputs: `kit-v2/photos/fixture_smooth.jpg` (flat grey and muted patches, made for grain) and `portrait_medium_02` (the photo of M9/S8). Both are already in kit-v2 and rights-cleared (Unsplash licence, generated card).

| # | Develop settings (everything else neutral, as kit-v2's `global` presets) | Photo | Export sizes | Exports |
|---|---|---|---|---|
| 1 | Grain off (reference) | fixture_smooth | full, 1200 px long edge | 2 |
| 2 | Amount 25 / 55 / 100, Size 25, Roughness 50 | fixture_smooth | full, 1200 px | 6 |
| 3 | Amount 55, Size 0 and Size 100, Roughness 50 | fixture_smooth | full, 1200 px | 4 |
| 4 | Amount 55, Size 25, Roughness 0 and 100 | fixture_smooth | full, 1200 px | 4 |
| 5 | "5 - (Portrait) - Glow", kit-v2 `full` and `nograin` style | portrait_medium_02 | full, 1200 px | 4 |

- **Total:** 20 exports, Lightroom Classic.
- **Export settings:** sRGB, 16-bit TIFF, no output sharpening, no metadata changes. "1200 px" means Resize to Fit, long edge 1200.
- **What each part gives:**
  - Rows 1–2 calibrate GRAIN_K, the amount mapping, and its midtone weighting (the card's grey patches).
  - Row 3 gives the size → cell mapping.
  - Row 4 gives roughness.
  - The two export sizes show whether Lightroom's grain follows the image or the pixel grid.
  - Row 5 checks the result on the case users saw.
- **Kit-v2 is not enough on its own:** its six grain Looks (amount 20–41, size 20–28) give no amount or size sweep and use a single export size. Its 1,932 exports are still useful for validating the full recipe.

## 4. Porting notes

### Both platforms
1. **Contract file.** Bundle the new `shared/contracts/rendering-v2.json` and check `"revision": 1`. In `stages[background.focus].operators[0]`, `maxBlurRadius` moved from `params` to `constants`, next to the other focus constants (`focusHalfWidthPerUnit`, `defocusRange`, `subjectInFocus`, `layersPerSide`, …). A parser that reads `params.maxBlurRadius` must change. The look pack does not change.
2. **CoC** (rendering-v2.md §7.1):
   - `R_max = blur/100·0.06·longEdge`;
   - `h = 0.5·depthOfField/100`;
   - `S = max(d_f, 1 − d_f)`;
   - `c = sign(Δ)·clamp((|Δ| − h)/max(S − h, 1e-6), 0, 1)·R_max`.
3. **Subject in focus.** When the focus is on the subject (`M(target) ≥ 0.5`, or a null recipe target with a subject), the subject plane's CoC is 0. Use it for layer membership, and in Soft's glow defocus map.
4. **Pull-push.**
   - Pull until the level is 1×1. Each step is an exact 2×2 mean, with an odd last row or column repeated.
   - Divide by the coverage at the 1×1 level.
   - Push back with half-pixel bilinear upsampling.
   - Replace any test that pinned the old black fill.
5. **Depth sources.**
   - Never blur from `subject-matte`.
   - The codec rejects `blur > 0` with `source = subject-matte`.
   - Write `focusDepth = 1 − d_f` at the tap, and render with `d_f = 1 − focusDepth` when it is not null.
   - Do not read `replacementDepth` (write 1); place a replacement by §R2.4 "plane".
6. **Goldens.** Add tests over `shared/fixtures/rendering/index.json`: scalars, kernels, pull-push, the nine renders (ΔE00 mean ≤ 1, p99 ≤ 4) and the grain cases. Its README lists what each section checks.
7. **Grain** (preset and user grain, Effects stage):
   - Replace the "keep a, b" lightness write with `(L', a·L'/L, b·L'/L)`.
   - Add the supersampling factor `s = max(1, ceil(2·cells/longEdge))`: interpolate both layers to `s·H × s·W`, mix them, then take the s×s block mean.
   - Check against the `grain` goldens.
8. **Edit-recipe fixtures.**
   - `background-focus-subject-matte-motion.json` was replaced by `background-focus-estimated-motion.json`.
   - `invalid-blur-without-depth.json` is new.
   - `background-focus-swirl.json` and `demo-combined.json` changed bytes.
   - Codec round-trip tests that list the folder pick these up; nothing references the old name.
9. **UX evidence.** Recapture bg-focus, bg-soft, bg-swirl, bg-motion and bg-replaced-blur after porting (the previous native captures are stale), plus every screen that shows a grain preset (bg-failed, dev-portrait-photo, dev-favourites). Section 1's tablet and style conflicts remain open for the product owner, so those cells cannot be marked exact-match until the owner decides.

### Android
| Where | Change |
|---|---|
| `core-background/.../Refocus.kt` | `MAX_BLUR_FRACTION_OF_LONG_EDGE` 0.03 → 0.06. `halfWidth` is unchanged. `signedCoc` (≈ line 178): divide by `max(max(focal, 1 − focal) − halfWidth, 1e-6)` instead of `max(1 − halfWidth, 1e-6)`. Apply the subject-in-focus rule where the subject plane's CoC is built (≈ line 200). `pullPushFill` (≈ line 379): change the loop condition from `min(w, h) > 4` to `max(w, h) > 1`, with an exact 2×2 mean and edge repeat. Update the G7 pin test. |
| `core-session/.../EditTools.kt` (≈ line 178) | Add the reader rule: reject `blur > 0` when `source == SUBJECT_MATTE`. |
| `core-develop/.../DevelopRenderer.kt` `applyGrain` (≈ lines 438–445) | Make the lightness write keep chromaticity, and supersample with box averaging. |
| `slice3-android.md` G1–G7 | Mark them as resolved by revision 1 (that agent's file). |

### iOS
| Where | Change |
|---|---|
| `ImageEngine/Background/RefocusRenderer.swift` | `maxCoCFractionOfLongSide` 0.035 → 0.06. Half-width: `0.30·pow(fd/100, 1.5)` (≈ line 164) → `0.5·fd/100`. CoC divisor (≈ line 180): `max(S − h, 1e-6)`. Apply the subject-in-focus rule. `FloatImage.pullPushFill`: pull to 1×1 as above. |
| `ImageEngine/Background/BackgroundStage.swift` (≈ lines 36–50) | Remove the two-plane disparity built from the matte when the source is `subjectMatte`: it is the mask-only blur §R8 forbids. Without depth, render no blur (the panel shows the approved failure state). Use the stored `focusDepth` (`d_f = 1 − focusDepth`) instead of re-resolving the target. |
| `Domain/EditRecipe/EditRecipeCodec.swift` (≈ line 231) | Add the reader rule: reject `blur > 0` with `subject-matte`. |
| `ImageEngine/Develop/DevelopPixelOperators.swift` grain (≈ lines 278–320) | Make the lightness write keep chromaticity, and supersample with box averaging. |
