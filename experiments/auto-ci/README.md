# iOS Auto: Core Image auto enhancement, inspected (2026-10-06)

Engine: `CIImage.autoAdjustmentFilters` (options: enhance on, red-eye off, crop off, level off), run on the ≤1024 px
analysis proxy. Applied: CIFaceBalance, CIVibrance, CIToneCurve (per-pixel, baked into the stage-1 Auto LUT).
Omitted: CIHighlightShadowAdjust (spatial; cannot be a LUT and would seam across a tiled Save copy). This is Core Image
auto enhancement: not the Apple Photos algorithm and not a trained model.

`auto_sheet.swift` (macOS Core Image; the same filters the app keeps) on the approved photos; `auto-sheet.jpg`
(before | after pairs). Mean luma, clipped share (any channel ≥ 254), mean chroma:

| Photo | Luma | Clipped % | Chroma | Applied |
|---|---|---|---|---|
| portrait_light_01 | 104→107 | 0.08→0.54 | 33→37 | face balance, vibrance 0.10, tone curve |
| portrait_medium_02 | 158→155 | 1.54→2.49 | 27→29 | face balance, vibrance 0.08, tone curve |
| portrait_deep_03 | 25→30 | 0.00→0.01 | 15→25 | face balance, vibrance 0.09, tone curve (lifts shadows) |
| backlit_02 | 97→97 | 7.32→7.41 | 28→34 | vibrance 0.16, tone curve |
| sunset_02 | 83→86 | 1.63→5.02 | 57→61 | vibrance 0.04, tone curve (lifts upper mids) |
| night_03 | 47→47 | 0.01→0.13 | 29→36 | vibrance 0.16, tone curve (deeper blacks) |
| landscape_01 (already good) | 126→115 | 19.88→19.90 | 24→29 | vibrance 0.10, tone curve (black point 0.08→0) |
| landscape_02 (already good) | 120→105 | 0.23→0.68 | 30→38 | vibrance 0.05, tone curve (black point 0.12→0) |

Findings for the owner (not tuned: changing Core Image's parameters would no longer be Core Image Auto):
- **Skin:** face balance warms skin; visible orange shift on portrait_light_01; strong chroma gain on portrait_deep_03.
- **Highlights:** clipping grows on the sunset (sun area) and the white jacket.
- **Already-good photos** are darkened, not brightened (raised black point).
- Device check pending: iOS's Core Image may choose slightly different parameters than macOS.

## 2026-10-06 (later): per-filter causes, guards, result

Per-filter comparison (`per_filter.swift`; original, each proposed filter alone, all):

| Regression | Cause |
|---|---|
| Redder/orange skin | CIFaceBalance: skin hue 59°→50° (light), 50°→43° (medium), 46°→42° (deep) |
| More highlight clipping | CIToneCurve (sunset 1.22→2.85 %, jacket 1.46→2.41 %); CIHighlightShadowAdjust (sunset → 2.85 %) |
| Already-good landscapes darker | CIToneCurve black-point stretch (p1 26→7, 38→9; luma 125→115, 119→105) |
| Low-key portrait relit | CIToneCurve + CIHighlightShadowAdjust (skin L 30→43) |

**CIHighlightShadowAdjust** is proposed with Radius 0, which is per-pixel: baked into a LUT it matches the filter within
0.15/255 mean, 2/255 max (`hsa_pointwise.swift`). It is now applied in the Auto LUT (no tile boundaries); a proposal
with a radius above 0 would be local and is recorded as omitted.

**Guards** (`ios/Lightly/ImageEngine/LUT/CoreImageAutoGuards.swift`, image-dependent, measured on the proxy): face
balance only when skin hue is outside 40–62° and only up to that edge; tone curve only when the photo does not already
span its range (p1 ≤ 0.15 and p99 ≥ 0.85); tonal filters stepped down (1, ¾, ½, ¼, 0) until they add ≤ 0.1 pp clipping
and, with a face, move skin lightness ≤ 5 L and chroma ≤ 15 %; vibrance stepped down only if it clips.

**Result** (`guarded-sheet.jpg`: original | Core Image as proposed | guarded; `guarded-notes.txt`; app test
`CoreImageAutoTests.testGuardedAutoOnTheApprovedPhotos`, same decisions on the Simulator):

| Photo | Applied after guards |
|---|---|
| portrait_light_01 | vibrance (face balance, tonal removed: skin plausible; clipping) |
| portrait_medium_02 | vibrance ×0.75 (range spans; clipping) |
| portrait_deep_03 | vibrance, tone curve + highlight/shadow at ¼ (skin guard) |
| sunset_02 | vibrance (tonal removed: clipping) |
| landscape_01, landscape_02, backlit_02 | vibrance, highlight/shadow at ¼ (tone curve removed: range spans) |
| night_03 | vibrance, tone curve at ¾ |

Mostly a light touch: on these photos, which are already well made, the guards remove most of Core Image's tonal
proposals. Device check pending (iOS Core Image on the phone).

## Correction (2026-10-06, later): highlight/shadow is local; Auto evaluated on controlled degradations

**CIHighlightShadowAdjust is not per-pixel.** The earlier 800 px check (max 2/255) was misleading. At 1600 px, the
filter through the app's 33³ LUT differs from the filter itself by p99.9 13–20/255, max up to 24/255, almost all in
shadows and on edges; at 65³ the error is unchanged, so it is not grid resolution (`lut_worst.swift`, per filter:
tone curve, face balance and vibrance stay within 0.5–6/255; highlight/shadow alone 15–20/255). It is again **not
applied** (recorded as omitted). Auto is the reduced Core Image set, not the complete enhancement.

**Guards revised after review.** No fixed skin-hue band (pooled face colour cannot define a correct skin colour):
face balance only with a measured global cast (the photo's least-coloured 20 % of mid-tones away from grey) and only
as far as it reduces it; vibrance skipped when a cast is measured (it amplified casts). Face lightness: a face lit well
above its scene is low-key and kept (±5 L); a face clearly below its scene, or a photo with no highlights (p99 < 0.7),
may be lifted by up to 20 L.

**Controlled evaluation** (`eval/main.swift`, `eval/eval.txt`, `eval/eval-sheet.jpg`). The approved set has no
underexposed or colour-cast originals, so each photo is degraded with a known amount in linear light (synthetic, not
real captures): −1.5 EV, and a warm cast (R ×1.18, B ×0.78). Mean CIELAB distance to the original before → after Auto:

| | Improved | Unchanged | Worse |
|---|---|---|---|
| −1.5 EV (12 photos) | 10 (e.g. sunset 23.2→17.5, wellexposed 20.5→13.5, night 12.0→7.4) | 2 (portraits medium_01, deep_01: skin guards block the lift) | 0 |
| Warm cast (12) | 4 portraits via face balance (deep_01 6.4→2.7, medium_01 7.5→5.4) | 5 (no neutrals, or no cast detected) | 3 (backlit_01 8.1→10.1: its warm sunset light reads as a cast; landscape_03 7.3→8.6: cast not detected, vibrance; deep_03 2.7→4.2) |
| Originals (12): Auto's own change | ΔE 0–4.3 (5 untouched) | | |

**Limits, stated:** Core Image's proposal has no general white-balance correction, so Auto is not a cast corrector;
intentional warm light and a cast cannot be told apart from the pixels; low-key vs underexposed is a heuristic.
Real underexposed or cast photos (not synthetic) and the iPhone's own Core Image are unverified. General Auto quality
is not claimed.
