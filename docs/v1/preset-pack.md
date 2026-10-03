# Preset pack v2 and the edit recipe

**Status: provisional until native parity is proven.** The recipe architecture is not final for the full catalogue yet. Both native ports must first prove two things on both platforms:
- recipe → LUT parity, against the golden vectors below;
- browsing performance.

The manifest says so in `status`. Nothing in the pack is validated against Lightroom: all 2,591 presets are `approximate`.

## What it is

- **`shared/look-pack/build_pack.py`** turns the fixed design catalogue into the pack both apps bundle. One recipe per preset, no per-preset LUTs (plan.md decision 1).
  - The app bakes each preset's 33³ global LUT on the device from its recipe.
  - It then applies the spatial and finishing operators.
- **`shared/contracts/rendering-v2.md` / `.json`** is the whole-edit pipeline: 12 stages, every operator's parameters, ranges and units, the Develop equations and the calibrated constants.
- **`shared/contracts/edit-recipe-v1.json`** is the shared edit recipe, EditState schema 3. It covers every tool in the approved prototype.
- **`shared/fixtures/look-pack/`** holds the parity vectors. **`shared/fixtures/edit-recipe/`** holds the recipe examples.

## Build

The Python venv needs numpy, scipy, torch, pillow and tifffile. Cap its threads with `OMP_NUM_THREADS=4`.

```bash
python shared/look-pack/build_pack.py                 # ~2.5 min; writes shared/look-pack/out/ (git-ignored)
python shared/look-pack/make_golden.py                # parity subset + golden vectors -> shared/fixtures/look-pack/
python shared/contracts/build_rendering_v2.py         # only when constants or stage definitions change
python shared/contracts/make_edit_recipe_examples.py  # only when the edit-recipe examples change
python -m pytest shared/look-pack/tests shared/contracts/tests -q
```

**Inputs (never modified):**
- `presets/develop-design-ui.json`: 9 categories, 2,591 presets with ids, names and stops. These are copied exactly, and a test compares them field by field.
- `presets/develop-design-catalogue.json`: the private source bindings.
- `presets/library/`: the source files.

The build stops and writes nothing if any of these disagree:
- a source file's bytes do not match its `sourceAssetId`;
- the parsed settings do not match `settingsSha256`;
- the two catalogue files disagree on order, names or stops;
- a nested XMP value would override a converted setting;
- a recipe does not reproduce `lr_model` within 1e-3.

**Output (`out/`, deterministic, git-ignored like the format-2 pack):**

| File | Size | Bundled by the apps |
|---|---|---|
| `manifest.json` | 6.47 MB (0.68 MB gzip) | yes |
| `unconverted.json` | 0.82 MB | no: kept so a later converter never needs the private library |
| `luts/` | empty (no validated Lightroom override exists) | yes, when present |

## Per preset (manifest `categories[].presets[]`)

Every preset entry carries these fields:
- `id`, `displayName` and `stop`, exactly as in the UI catalogue;
- `sourceAssetId` and `settingsSha256`;
- `processVersion`, `recipeVersion` (1) and `lookVersion` (rendering-v2.md §4.3);
- `operators`: the Lightly operators the preset uses, in pipeline order;
- `recipe`: `{global, spatial, finishing}`, with only the operators that change pixels, each fully specified;
- `completeness`, which is separate from validation:
  - `complete`: every setting is converted to a Lightly operator;
  - `approximate`: everything is represented, some of it by an approximation;
  - `incomplete`: some setting is not converted.
- `approximated`, `unsupported` and `notApplied`: `{code, keys[, assumption]}`, with each reason given once in the manifest's `coverageCodes`. Every non-default source setting is either consumed by an operator or recorded here. A test enforces this.
- `effects` `{grain, vignette}`, derived from the real settings. These drive the approved "added on top, not replaced" notice.
- `validation`:
  - `{globalColour, fullRecipe}`, each with a status and evidence;
  - `conversion` and `status`;
  - `binding`: the recipe digest and renderer digest from `experiments/presets/evidence.py`, plus the LUT digest when a report names the preset.
- `globalOverride`: always null today.

## Coverage, measured over the 2,591 presets

| Operator | Presets | Stage | Status |
|---|---|---|---|
| toneSliders (contrast, highlights, shadows, whites, blacks) | 2,571 | global | calibrated; highlights, shadows, whites and blacks are global approximations of adaptive operators |
| hsl | 2,520 | global | calibrated |
| toneCurve | 2,423 | global | exact (natural spline as Lightroom reads it) |
| vibranceSaturation | 2,408 | global | calibrated |
| clarity | 2,055 | spatial | calibrated, not validated |
| colorGrading (incl. legacy split toning) | 1,970 | global | calibrated |
| calibration | 1,913 | global | calibrated |
| exposure | 1,879 | global | calibrated |
| noiseReduction | 1,878 | spatial | provisional, uncalibrated |
| sharpening | 1,852 | spatial | provisional, uncalibrated |
| whiteBalance (incremental) | 1,293 | global | calibrated |
| parametricCurve | 1,044 | global | calibrated |
| dehaze | 898 | global | calibrated global approximation (local dehaze reserved) |
| grain | 618 | finishing (Effects stage) | experimental, uncalibrated |
| shadowTint | 604 | global | calibrated |
| texture | 548 | spatial | calibrated, not validated |
| vignette | 451 | finishing (Effects stage) | experimental, uncalibrated |
| grayscale | 18 | global | calibrated |

**Completeness:** 16 complete, 2,411 approximate, 164 incomplete. Validated: 0.

| Category | Presets | Complete | Approximate | Incomplete | Grain | Vignette |
|---|---|---|---|---|---|---|
| Portrait | 158 | 0 | 149 | 9 | 44 | 13 |
| Landscape | 518 | 2 | 487 | 29 | 111 | 71 |
| Film | 253 | 1 | 210 | 42 | 151 | 58 |
| Cinematic | 564 | 8 | 503 | 53 | 120 | 149 |
| Street | 373 | 2 | 367 | 4 | 48 | 89 |
| Travel | 483 | 2 | 458 | 23 | 90 | 53 |
| Wedding | 152 | 0 | 152 | 0 | 44 | 1 |
| Golden Hour | 69 | 0 | 69 | 0 | 3 | 15 |
| Black & White | 21 | 1 | 16 | 4 | 7 | 2 |

### Approximated: rendered, by an approximation

| Code | Presets | Why |
|---|---|---|
| adaptive-tone-global | 2,568 | Lightroom adapts Highlights, Shadows, Whites and Blacks locally; Lightly applies the calibrated global curve |
| local-contrast-calibrated | 2,102 | Clarity and Texture: Lightly's operator, calibrated but not validated |
| noise-reduction-provisional | 1,878 | Provisional Lightly operator |
| sharpening-provisional | 1,852 | Provisional Lightly operator |
| dehaze-global | 898 | Lightroom's dehaze is spatial; Lightly uses a global approximation |
| grain-uncalibrated | 618 | Uncalibrated constants and a portable random field, not Lightroom's grain pattern |
| vignette-uncalibrated | 451 | Uncalibrated constants |
| process-version-2012 | 215 | PV 6.7 rendered with the model calibrated on PV 10 and 11 |
| iso-adaptive | 30 | ISO-adaptive presets vary Sharpness (and, in a few, Shadows, Blacks, NR or masking) with ISO. Lightly applies the preset's fixed values. The ISO data is kept verbatim. |

### Unsupported: changes the look, not rendered (the rest of the preset renders)

| Code | Presets | Why |
|---|---|---|
| local-adjustments | 122 | Masks: 117 mask groups, 5 graduated filters, 1 radial filter |
| creative-profile | 23 | "Vintage 01", a profile stub with no embedded table |
| lens-vignetting | 11 | Manual lens-vignetting correction (VignetteAmount) |
| camera-profile | 5 | "Default Monochrome" (4) and "Agfa Vista 800 - C" (1) |
| curve-refine-saturation | 3 | Tone-curve saturation refinement |

### Not applied: deliberately not part of a Look on a rendered photo

| Code | Presets | Why |
|---|---|---|
| raw-base-profile | 1,070 | Default Color, Adobe Standard or Camera Standard profiles, plus 34 "Adobe Color" profile stubs. Raw-only. **Assumption, unverified.** |
| absolute-white-balance | 636 | Absolute Temperature and Tint apply to raw files. **Assumption, unverified.** |
| lens-corrections | 402 | Lens profile, chromatic aberration, defringe |
| legacy-pv2010-inactive | 113 | Legacy `ToneCurve`/`ToneCurveName` written beside PV2012+ settings |
| enhance-filter-off | 30 | Decoded Enhance filter entry with Denoise, Super Resolution and Details all off: no pixel effect |

### Corrections to the plan's feature table
- **PV 6.7 is PV2012, not PV2010.** It uses the 2012 sliders, and its legacy keys are inactive. The catalogue holds no real PV2010 preset; one would be recorded `unsupported`.
- **Point Color: 0 active.** The 786 presets with `PointColors` contain only the −1 placeholder.
- **Creative profiles (57) split in two:**
  - 34 are the raw base profile "Adobe Color". This is `notApplied`, an assumption.
  - 23 are the creative "Vintage 01" stub. This is `unsupported`.
  - Neither embeds a table: the 30 `Table_…` blobs are Enhance-filter settings, not profiles.
- **Local masks: 122 presets.** The plan's 117 counted only mask groups.

## Validation

All 2,591 presets are `approximate`, with both validations `not-run`. They become `global-colour-validated` or `validated` only through bound evidence, using the format-2 rules unchanged (`build_look_pack._validation` and `promoted_status`):
- A Lightroom HALD LUT replaces the bake only when its global-colour validation passed with digests that match the shipped LUT and the original recipe.
- `validated` additionally needs the full-recipe validation, and no `unsupported` record.
- A model-derived global stage is never promoted, whatever a report says.

## Lightroom reference exports (dependency D8): inputs prepared, not run

`experiments/presets/lr_kit/make_kit_v2.py` reuses `make_kit.py` unchanged. It has prepared `experiments/presets/lr_kit/kit-v2/` (git-ignored, 44 MB):
- **Looks:** 36 of the 40 parity presets, in every category. They include PV 6.7, grayscale, grain, vignette, ISO-adaptive and the scalar-only incomplete cases.
  - The kit's look id **is** the pack preset id, so `ingest_kit`'s report plugs straight into `build_pack.py --validation-report`.
  - 4 presets are left out (listed in `sample.json`): those with masks or a profile stub, which the generated kit presets cannot carry.
- **Inputs:** 24 (22 photos plus 2 fixture cards).
- **Exports:** 1,932 in total. Each Look has 1 HALD, 24 global and 24 full exports; the 6 grain Looks also have 24 no-grain exports; and 24 neutral exports cover the whole kit.

When the exports exist:

```bash
python experiments/presets/lr_kit/ingest_kit.py experiments/presets/lr_kit/kit-v2
python shared/look-pack/build_pack.py --validation-report experiments/presets/lr_kit/kit-v2/results/report.json \
                                      --hald-dir experiments/presets/lr_kit/kit-v2/exports/hald
```

**Before full-recipe evidence can promote a pack preset:** `ingest_kit.full_recipe` must render the spatial and finishing stages with `shared/look-pack/reference_model.py`, which adds sharpening and noise reduction and uses the portable grain. `evidence.RENDERER_FILES` must also include that file. Today, `ingest_kit` still renders with `lr_model`'s operators, so its full-recipe results describe a slightly different renderer. Global-colour evidence is unaffected.

## Parity (gate before this pack is final)

**Parity subset:** `shared/fixtures/look-pack/manifest-parity.json` holds 40 presets in the pack format. `golden.json` and the `luts/` folder hold the expected values; see that folder's README. Each port runs these checks for every case:

| Check | Tolerance (max abs, encoded sRGB 0–1) |
|---|---|
| 17³ bake vs golden float16 LUT, every node | 1e-3 |
| develop.global evaluated directly on the 24 probes | 5e-4 |
| 33³ bake, then trilinear lookup of the probes | 1e-3 |
| `lookVersion` recomputed from the recipe | equal |
| `lowbias32` vectors / gaussian field | exact / 1e-6 |

**Procedure.**
1. Run the parity cases in the unit tests on both platforms, on CPU and on the GPU bake path where one exists.
2. Then run the full pack on a reference device per platform: bake all 2,591 recipes and report the worst node difference against a desktop bake. `build_pack` can emit per-preset 17³ bakes on request in a later slice.
3. Measure browsing:
   - Proposed acceptance: median 33³ bake ≤ 16 ms (one frame at 60 Hz) and p95 ≤ 33 ms, on the oldest supported device per platform.
   - Scrubbing through 20 consecutive stops must never show a stale preview for more than 100 ms.
   - Manifest parse plus index ≤ 300 ms at cold start.
4. Report the numbers to the product owner. Remove the `provisional` status only on their decision.

## What the native ports need (slice 2)

1. **Pack loader for formatVersion 3.**
   - Read `manifest.json` (6.5 MB; consider a gzip copy in the bundle) and reject any other format version. `scripts/bundle_look_pack.sh` still expects format 2 and `luts/*.f32`, so it must be updated.
   - Show categories and stops exactly as given; bundle only the stops.
2. **develop.global port** of `reference_model.develop_global`.
   - Port the natural spline curve tables and the OKLab helpers.
   - Embed the constants from `rendering-v2.json` `developModel`.
   - Bake 33³ on the device, with a cache keyed by `lookVersion`.
   - Apply Amount as `in + s·(LUT(in) − in)`.
3. **Spatial and finishing operators:**
   - clarity and texture (Gaussian blurs sized by the long edge);
   - noise reduction and sharpening (provisional);
   - vignette and grain in the Effects stage, using the portable hash RNG.
4. **Edit recipe v1** (EditState schema 3): a strict reader and writer with canonical bytes, migration 1 → 2 → 3, and unchanged Look resolution rules. Undo stores whole recipes.
5. **Parity tests** against `shared/fixtures/look-pack/` and `shared/fixtures/edit-recipe/`, plus the performance measurement above.
6. **UI data:**
   - `effects.grain` and `effects.vignette` drive the "added on top" notice.
   - `completeness`, `unsupported` and `validation.status` are available for an About or diagnostics view.
   - Nothing may be labelled validated.

## Decisions to confirm

1. The preset's vignette and grain are evaluated in the Effects stage, after geometry and background (rendering-v2.md §1), not in `develop.spatial`.
2. A replaced background receives the photo's global colour (Auto, Look, Adjust), as in the prototype.
3. Provisional mappings: Adjust exposure ±100 maps to ±2 EV, Light Leak style colours, watermark sizes, and the user grain styles.
4. These assumptions are recorded as `notApplied` and verifiable with kit-v2: raw base profiles and absolute white balance have no effect on rendered photos.
