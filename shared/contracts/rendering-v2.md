# Rendering contract v2

This contract defines the ordered pipeline that renders a whole Lightly edit. It covers every tool in the approved UX (`docs/ui/app/`). The parameters, ranges, units and calibrated constants are in `rendering-v2.json`, which `build_rendering_v2.py` generates; do not edit the JSON by hand. This file gives the equations and the reasons behind them.

**Revision:** 2 (contract fixes 2, 2026-10-04). See the [change log](#change-log) at the end and the porting notes in `docs/v1/contract-fixes-1.md` and `docs/v1/contract-fixes-2.md`.

**Status:** Develop is specified exactly enough to port.
- The global stage is the calibrated model, ported as `shared/look-pack/reference_model.py`. Per preset, it reproduces `experiments/presets/lr_model.py` within 3.7e-4 over the 2,591 catalogue presets.
- The other stages are specified at the level of parameters, coordinate spaces and order.
- Operators marked *provisional* have uncalibrated constants. Nothing here is validated against Lightroom yet.

## 1. Stage order

| # | Stage | Frame | Recipe source |
|---|---|---|---|
| 1 | `edit.remove` | source (full resolution) | `tools.edit.remove` |
| 2 | `auto` | source | `editState.auto` (ia3dlut LUT, strength) |
| 3 | `develop.global` | source | preset `recipe.global` × `look.strength` |
| 4 | `develop.spatial` | source | preset `recipe.spatial` × `look.strength` |
| 5 | `edit.adjust` | source | `tools.edit.adjust` |
| 6 | `background.replace` | source | `tools.background.replacement` |
| 7 | `background.focus` | source | `tools.background.focus` |
| 8 | `portrait` | source | `tools.portrait.faces` |
| 9 | `edit.geometry` | source → frame | `tools.edit.geometry` |
| 10 | `effects` | frame | `tools.effects` + preset `recipe.finishing` |
| 11 | `border` | frame → canvas | `tools.border` |
| 12 | `watermark` | canvas | `tools.watermark` |

Preview and export run the same stages on the same committed recipe. Only the resolution differs, and every spatial quantity is resolution independent (§2).

**Revision 2 order (contract fixes 2).** Stage ids are unchanged; their order numbers changed.
- **Remove runs first (C1),** on the full-resolution source pixels, before `auto` and every tone or colour stage (`docs/v1/remove-evaluation.md` §7, as heal works in Lightroom). Its stored patches are therefore independent of every later setting: a tone or colour change never re-runs the model, and preview and export composite the same patch.
- **Adjust, Background and Portrait run in source coordinates (C2),** before `edit.geometry`. Scene mattes, depth maps and face landmarks are computed on the source, so these stages use them without resampling. Colour is per pixel and unaffected; the visible consequence is that resolution-relative radii (Detail in `edit.adjust`, Focus & Blur's R_max and kernels, portrait regions) are fractions of the **uncropped source** long edge, not of the cropped frame.
- **Geometry then maps source → frame (stage 9),** and Effects stays in the frame after it, for the reasons below.

**Departure from the order sketched in plan.md decision 3, on purpose.** The preset's own **vignette and grain** are carried in the preset (`recipe.finishing`) but evaluated in stage 10, `effects`, rather than in `develop.spatial`. They run in the order: light leak → preset vignette → user vignette → preset grain → user grain. There are three reasons:
1. Lightroom's vignette is *post-crop*: it follows the final frame. If it were evaluated before `edit.geometry`, a crop would cut it off-centre.
2. Grain applied before geometry would be resampled by rotation and straightening, and blurred by Focus & Blur.
3. Grain is applied last because it belongs to the medium (the emulsion), while vignettes and light leaks are optical. This is also Lightroom's order: vignette before grain.

The approved "added on top, not replaced" notice is unchanged: user effects compose with the preset's. This order should be confirmed against the prototype screenshots before it is frozen.

**Replaced backgrounds get the photo's colour.** In the approved prototype, the new background receives the Look's grade along with the photo. Stage 6 therefore passes the replacement through the photo's global colour stages before compositing it: `auto`, `develop.global` at strength, and `edit.adjust` colour. Spatial operators are not applied to the replacement.

## 2. Conventions

- **Pixels:** pixels between stages are sRGB-encoded floats in [0, 1], ordered R, G, B. An operator linearises internally where an equation says so.
- **sRGB transfer:**
  - `lin(e) = e/12.92` if e ≤ 0.04045, else `((max(e,0.04045)+0.055)/1.055)^2.4`.
  - `enc(l) = 12.92·l` if l ≤ 0.0031308, else `1.055·max(l,0.0031308)^(1/2.4) − 0.055`, with l first clamped to ≥ 0.
- **OKLab:** Ottosson's matrices M1 and M2, as in `reference_model.py`.
  - `lms = max(lin·M1ᵀ, 1e-7)^(1/3)` and `lab = lms·M2ᵀ`.
  - The inverse uses the exact inverse matrices: `lin = (lab·M2⁻ᵀ)³·M1⁻ᵀ`.
  - Keep the 1e-7 floor. It makes the neutral recipe lift near-black by at most 1e-4, exactly as the model does.
- **Luma:** Y = 0.2126 R + 0.7152 G + 0.0722 B on linear values.
- **Resolution independence:** a radius is a fraction of the stage input's **long edge**: the uncropped source's for stages 1–8, the frame's for stage 10 (revision 2). A Lightroom radius given in pixels (sharpening) is defined at `referenceLongEdgePx` = 3000.
- **Coordinates:** normalised [0, 1], origin top-left.
  - *Source*: the oriented original.
  - *Frame*: after `edit.geometry`.
  - *Canvas*: frame plus border.
  - Points that belong to photo content are stored in source coordinates, so they survive a change of crop: Remove strokes, refine strokes, the focus target and face boxes. Stages 1–8 use them directly; only drawing them over the frame (and storing a touch) maps them through the geometry.
  - Effects positions (the light leak's x, y) are in frame coordinates.
- **smoothstep(a, b, x):** `t = clamp((x−a)/(b−a), 0, 1)`, then `t²(3−2t)`.

## 3. The preset recipe (pack manifest `recipe`, recipeVersion 1)

`recipe = {global: {...}, spatial: {...}, finishing: {...}}`. An operator is present only when it changes pixels, and when it is present every one of its parameters is written explicitly. `operators` lists the present operators in pipeline order.

What the recipe cannot carry is recorded per preset: `approximated`, `unsupported` and `notApplied`, each as `{code, keys}` with reasons in the manifest's `coverageCodes`. The settings themselves are kept verbatim in `unconverted.json`. `completeness` is `complete`, `approximate` or `incomplete`, and it is separate from validation.

## 4. Develop

### 4.1 Global stage: `develop.global` (calibrated model)

Let C be `developModel.constants`. Every slider value v is in Lightroom units, and `v/100` is written `v̂`. An absent operator has neutral values. The steps run in this order on each pixel.

#### G1 Calibration
Applies to each primary i ∈ {R, G, B}, with the next primary n = (i+1) mod 3 and the previous one p = (i−1) mod 3:
```
h  = hue_i^ · k_cal_hue · cal_hue[i]
e  = unit_i + max(h,0)·unit_n + max(−h,0)·unit_p
s  = 1 + sat_i^ · k_cal_sat · cal_sat[i]
col_i = mean(e)·1 + s·(e − mean(e)·1)          # mean(e) = sum(e)/3
M = [col_R col_G col_B] (columns); each ROW divided by its sum
lin = max(lin(rgb)·Mᵀ, 0)
```

#### G2 White balance
```
t = temperature·k_temp,  u = tint·k_tint
g = (exp(t), exp(−u), exp(−t));   g /= g·luma
lin *= g
```
Only the incremental values are used. The absolute Temperature and Tint are `notApplied` (code `absolute-white-balance`).

#### G3 Exposure
`lin *= 2^ev`

#### G4 Shadow tint
```
Y = max(lin·luma, 1e-6)                 # computed BEFORE this step's multiply; reused by G5
w = 1 − smoothstep(0, 0.25, Y)
lin.G *= exp(−shadowTint·k_shadow_tint·10)^w
```

#### G5 Basic tone
This step covers toneSliders and dehaze, using the global approximation of Lightroom's adaptive operators.
```
e  = enc(Y)                              # Y from G4 (before the shadow-tint multiply)
d  = k_contrast·contrast^·(e−0.5)·4e(1−e)
   + k_hi·highlights^·exp(−((e−c_hi)/w_hi)²)·e
   + k_sh·shadows^·exp(−((e−c_sh)/w_sh)²)·(1−e)
   + k_wh·whites^·e⁴ + k_bl·blacks^·(1−e)⁴
   + 0.1·Σ_rows s≠0 Σ_j (tone_A[row][j]·s + tone_B[row][j]·s²)·hat_j(e)
       rows: contrast, highlights, shadows, whites, blacks, dehaze;  s = slider^
       hat_j(e) = max(1 − |e − j/11|·11, 0),  j = 0…11
lin = applyLuminance(lin, lin(max(e + d, 0)))
veil = k_dehaze·dehaze^·dehaze_air·0.05
lin = (lin − veil)/(1 − veil)
```
`applyLuminance(lin, T)` works as follows:
1. Compute `Y' = max(lin·luma, 1e-6)` and `scaled = lin·T/Y'`.
2. If max(scaled) ≤ 1, the result is `scaled`.
3. Otherwise, compute `k = max((1−T)/max(peak−Y', 1e-9), 0)`, where peak is the largest channel, and the result is `lin·k + (T − k·Y')`.

The result is continuous at the switch between steps 2 and 3.

#### G6 Parametric curve
This step works per channel on `x = enc(lin)`. The splits are s1, s2, s3, each = split/100.
```
bump(x, lo, hi) = sin(π·clamp((x−lo)/max(hi−lo, 1e-3), 0, 1))²
x += k_param·0.25/100·( shadows·bump(x, −s1, 2s1) + darks·bump(x, 2s1−s2, s2)
                      + lights·bump(x, s2, 2s3−s2) + highlights·bump(x, 2s3−1, 2−s3) )
```
x is not clamped here.

#### G7 Point curves
Each curve is `[[x, y], …]` in 0…255, sorted with unique x. The generator normalises it the way Lightroom reads it: sorted, and the last duplicate x wins.
- **2 points:** the curve is linear.
- **3 or more points:** the curve is a natural cubic spline, with second derivative 0 at both ends. It is evaluated on `clamp(t, x0, xN)` and holds y0 or yN outside that range.

Sample each curve at `t = i/255`, i = 0…255. Clamp the samples to [0, 1] and store them as float32. Lookup then works like this:
```
p = clamp(x,0,1)·255;  i = clamp(floor(p), 0, 254);  f = p − i;  y = T[i]·(1−f) + T[i+1]·f
```
The master curve applies to all three channels, followed by red, green and blue on their own channels. An absent channel is the identity. Note that lookup clamps x, but an absent curve does not.

#### G8 HSL
```
lab = OKLab(lin(clamp(x,0,1))); L, a, b
C = sqrt(a²+b²+1e-9);  H = deg(atan2(b, a+1e-9)) mod 360
w = bandWeights(H)                       # piecewise-linear partition of unity, centres
                                         # 29, 55, 105, 142, 195, 264, 300, 328 (red…magenta), circular
colourful = clamp(C/0.08, 0, 1)
H += k_hue·(w·(hue^ ∘ hue_band))·colourful
C *= max(1 + k_hsl_sat·(w·(sat^ ∘ sat_band)), 0)
L += k_hsl_lum·(w·(lum^ ∘ lum_band))·colourful·L
```
`bandWeights` works per band i, with centre c_i and neighbours c_{i−1} and c_{i+1}:
```
o = ((H − c_i + 180) mod 360) − 180
w_i = o < 0 ? clamp(1 + o/((c_i − c_{i−1}) mod 360), 0, 1) : clamp(1 − o/((c_{i+1} − c_i) mod 360), 0, 1)
```
Then normalise by the sum, with the sum floored at 1e-6. Here `mod` is floored, with the result taking the sign of the divisor.

#### G9 Vibrance, saturation
```
C *= max(1 + k_vib·vibrance^·(1 − clamp(C/0.25, 0, 1)), 0)
C *= max(1 + k_sat·saturation^, 0)
```

#### G10 Colour grading
The generator has already folded legacy Split Toning into these values.
```
a = C·cos(H°), b = C·sin(H°)
bal = balance/100;  bl = 0.15 + 0.35·blending/100
w_hi = smoothstep(0.5+0.25bal−bl, 0.5+0.25bal+bl, L);  w_sh = 1 − w_hi;  w_mid = 1 − |w_sh − w_hi|
for zone z in (shadows w_sh, midtones w_mid, highlights w_hi, global 1), z = 0…3, if sat_z ≠ 0 or lum_z ≠ 0:
    θ = rad(hue_z + 25)
    a += k_grade·grade_zone[z]·sat_z/100·cos θ·w_z
    b += k_grade·grade_zone[z]·sat_z/100·sin θ·w_z
    L += k_grade_lum·lum_z/100·w_z·0.5
```
The weights are computed once, before the loop, from the L that G8 produced.

#### G11 Grayscale
`L *= 1 + 0.3·(w·mix^)·colourful`, then a = b = 0. Here w and colourful are the G8 values computed before the HSL edits.

**Output:** `clamp(enc(OKLab⁻¹(L, a, b)), 0, 1)`.

### 4.2 Baking and Amount
- **Bake:** the device samples the global stage on a 33³ grid, using `linspace(0,1,33)` for each axis. The layout is `[b][g][r][rgb]` with red fastest. The bake is then applied by trilinear interpolation.
- **Amount:** the Develop Amount is `look.strength` in [0, 1].
  - Global stage: `out = in + strength·(LUT(in) − in)`.
  - `develop.spatial` and `finishing`: amount-like parameters are multiplied by strength. These are noise reduction luminance and colour, clarity, texture, sharpening amount, vignette amount and grain amount.

### 4.3 Look version
`lookVersion` is the first 12 hex digits of the sha256 of the canonical JSON (sorted keys, no spaces) of `{recipeVersion, recipe, developModel: {id, version, constantsSha256}, globalOverrideSha256}`.

A change to the recipe, the model constants or an override changes the version. Saved edits then resolve as *changed*, under the EditState schema 2 rules: never substitute.

### 4.4 Lightroom HALD override
A preset may ship `globalOverride` (`luts/<id>.f32`: 33³ RGBA float32, red fastest). It does so only when `ingest_kit` reports global-colour **validated** with evidence digests that match what ships:
- the LUT bytes;
- the original settings' recipe digest;
- for the full recipe, the renderer digest, as defined in `experiments/presets/evidence.py`.

When an override is present, `develop.global` changes:
1. Apply the model restricted to highlights, shadows, whites, blacks and dehaze. Contrast is not among them; it stays inside the HALD.
2. Then apply the override LUT.

`reference_model.develop_global_with_override` implements this. No override exists today.

### 4.5 Process versions
- **10, 11, 15:** rendered by the model, which was calibrated on these.
- **6.7:** this is PV2012, not PV2010. It is rendered by the same model and recorded as `process-version-2012` (approximated).
  - Its legacy keys (`ToneCurve`, `ToneCurveName`) are inactive under PV2012 in Lightroom and are recorded as `notApplied`.
- **Before 6.7 (PV2010 or older):** recorded `unsupported` (`process-version-2010`). The catalogue has none.

Point Color: the 786 presets that carry `PointColors` hold only the −1 placeholder, so none is active. An active Point Color would be recorded as `unsupported` (`point-color`).

## 5. Develop spatial: `develop.spatial`

These operators run in this order: noise reduction → clarity → texture → (local dehaze, reserved) → sharpening. Lightroom also removes noise before sharpening, and `ingest_kit.full_recipe` applies local contrast after the global stage.

`G_σ` is a separable Gaussian with reflect padding. Its radius is `min(max(3, ceil(3σ)), floor(max(H,W)/2) − 1)`, and σ is floored at 0.3 px. A port may approximate large Gaussians, for example with a pyramid, provided the result stays within the full-recipe tolerance once one is set.

### S1 Noise reduction
This operator is *provisional* and uncalibrated. `scale = longEdge / referenceLongEdgePx`.
```
OKLab (L, a, b)
if luminance: S = G_{nrLumaRadiusPx·scale}(L); keep = smoothstep(0, nrDetailScale·(1.01 − luminanceDetail/100), |L − S|)
              L += (S − L)·luminance/100·(1 − keep)·(1 − 0.5·luminanceContrast/100)
if color:     r = nrColourRadiusPx·scale·(0.5 + colorSmoothness/100);  a += (G_r(a) − a)·color/100;  b likewise
```
`colorDetail` is carried in the recipe but not used yet. It is reserved for the calibrated operator.

### S2 Clarity and texture
These use the calibrated `spatialConstants`.
```
L += k_clarity·clarity/100·4L(1−L)·(L − G_{r_clarity·longEdge}(L)) + k_texture·texture/100·(L − G_{r_texture·longEdge}(L))
```
L is clamped to [0, 1]. a and b are kept.

### S3 Sharpening
This operator is *provisional*. σ = `radius·longEdge/referenceLongEdgePx`.
```
D = L − G_σ(L);  t = (1 − detail/100)·sharpenDetailThreshold;  D *= |D|/(|D| + t)
if edgeMasking: E = |∇G_σ(L)|·longEdge/referenceLongEdgePx;  D *= smoothstep(0, edgeMasking/100·sharpenEdgeScale, E)
L += k_sharpen·amount/100·D
```

## 6. Effects and the preset's finishing operators

### F1 Vignette
This operator is *experimental* and uncalibrated: `VIGNETTE_K` is a first guess. It is lr_model's `apply_vignette`, evaluated on the frame.

Pixel centres are `x_j = −1 + 2j/(W−1)` and `y_i = −1 + 2i/(H−1)`.
```
a = amount/100; if roundness > 0: x *= 1 + roundness^·(W/H − 1)
p = 2 + max(0, −roundness^)·6;  r = (|x|^p + |y|^p)^(1/p) / 2^(1/p)
t = smoothstep(c − w/2, c + w/2, r),  c = 0.25 + 0.65·midpoint/100,  w = 0.05 + 0.6·feather/100
style 3 (paint overlay): rgb = mix(rgb, a<0 ? 0 : 1, clamp(|a|·K·t, 0, 1))
style 2 (colour priority): L *= max(1 + K·a·t, 0)^(1/3)   (OKLab, a/b kept)
style 1 (highlight priority): g = 1 + K·a·t; if a < 0: g = 1 + (g−1)·(1 − hc·smoothstep(0.35, 0.9, Y)); lin *= max(g, 0)
```
Here hc = highlightContrast/100. The user Effects vignette maps onto this operator: `amount = −amount`, `midpoint = size`, `feather = softness`, roundness 0, style 1.

### F2 Grain
This operator is *experimental* and uncalibrated. **v2 differs from lr_model on purpose** in four ways:
- The random field is portable, where lr_model uses `torch.randn`.
- It is normalised analytically, where lr_model normalises it per image.
- *(revision 1)* Only lightness changes; the pixel's chromaticity is kept (below).
- *(revision 1)* A render with fewer than 2 pixels per grain cell is supersampled and box-averaged (below).

As a result, preview and export get the same grain on every platform, and a small preview shows what the export shows once downscaled.
```
cells = max(8, round(GRAIN_REF_LONG/(1 + 4·size/100)));  rows = max(2, round(cells·H/longEdge)), cols likewise
s = max(1, ceil(2·cells/longEdge))                       # supersampling factor, integer
fine   = bilinear(N(seed, 0, rows, cols) → s·H × s·W) / (2/3)
coarse = bilinear(N(seed, 1, max(2, rows div 3), max(2, cols div 3)) → s·H × s·W) / (2/3)
n = boxMean_s( ((1−r)·fine + r·coarse)/sqrt((1−r)² + r²) ),  r = roughness/100     # mean of each s×s block
(L, a, b) = OKLab(lin(rgb))
L' = clamp(L + GRAIN_K·amount/100·n·(4L(1−L) + 0.2), 0, 1)
out = clamp(enc(OKLab⁻¹(L', a·L'/L, b·L'/L)), 0, 1)      # L ≥ ~0.0046 because of the 1e-7 LMS floor
```
- `bilinear` uses half-pixel centres: `src = clamp((dst + 0.5)·in/out − 0.5, 0, in − 1)`.
- **Why a and b scale with L (revision 1).** Scaling (L, a, b) by one factor scales linear RGB by its cube, so the pixel only gets lighter or darker. The first version kept a and b fixed, which raises OKLab saturation (C/L) wherever the grain darkens and lowers it where it lightens. On skin at grain 55 ("5 - (Portrait) - Glow") that was a 12.7 % saturation noise (std): the "coloured grain" in iOS M9 and Android S8. Gamut clipping added little: 5.8 % of the photo's pixels clipped, and hue noise on skin was 0.8° (std). With the fix the saturation noise on skin is 1.3 % and the hue noise 0.4°, both from the remaining clipping at white and black (3.4 % of pixels).
- **Why supersample (revision 1).** With fewer pixels than cells, the bilinear "upsample" is a point sample: every pixel gets an independent value at 1.5× the intended amplitude (the 2/3 normalisation assumes interpolation). For 600 cells (size 25), that happens below 1,200 px on the long edge; for size 0, below 2,400 px. With s, a 300×400 preview equals the 900×1200 export averaged over 3×3 blocks, exactly.
- **What GRAIN_K means.** The midtone weight 4L(1−L) + 0.2 is 1.2 at L = 0.5, so the OKLab L standard deviation at amount 100 is 0.144 at mid-grey (0.2·K at black and white), not the 0.12 that lr_model's comment states. Neither GRAIN_K nor GRAIN_REF_LONG is calibrated against anything: they are lr_model's first guesses. Calibrating them needs Lightroom exports (D8; `docs/v1/contract-fixes-1.md` §3 lists the minimum set).
- `N(seed, layer, i, j)` is defined below. All arithmetic is uint32, modulo 2³²:
  ```
  lowbias32(x): x ^= x>>16; x *= 0x7FEB352D; x ^= x>>15; x *= 0x846CA68B; x ^= x>>16
  base = lowbias32(seed ^ lowbias32(layer))
  h1 = lowbias32(base ^ lowbias32((i·0x9E3779B1) ^ lowbias32(j)));  h2 = lowbias32(h1 ^ 0x85EBCA6B)
  u_k = ((h_k >> 8) + 0.5)/2²⁴;  N = sqrt(−2 ln u1)·cos(2π u2)
  ```
  `shared/fixtures/look-pack/golden.json` gives exact vectors under `portableRandom`; `shared/fixtures/rendering/` gives whole-operator vectors (`grain`).
- **Seed:** the preset seed comes from `GrainSeed` when the preset has one. Otherwise it is the first 32 bits of sha256(preset id). The user grain seed is fixed when the edit is created.
- **User grain styles:** `fine`, `film` and `coarse` scale size by 0.7, 1.0 and 1.5 respectively, capped at 100.

### Light leak
Colours and opacities are *provisional* design values from the approved prototype. The geometry (revision 2, C4) is the prototype's CSS, exactly: a frame-sized overlay with
`background: radial-gradient(circle at x% y%, core α, ring β 30%, transparent 55%)`, `mix-blend-mode: screen` and `transform: rotate(rotation deg)`, where α = intensity/130 and β = intensity/400.

A CSS `circle` with no size is `farthest-corner`, so the stop positions are fractions of the distance from the leak centre to the **farthest frame corner**, not of the long edge. On a W × H frame (pixels, pixel centres at +0.5):
```
o  = (x·W/100, y·H/100);   c = (W/2, H/2);   θ = rad(rotation)          # clockwise positive, as CSS
R  = max(|o − (0,0)|, |o − (W,0)|, |o − (0,H)|, |o − (W,H)|)
d  = p − c;   q = c + (cosθ·d.x + sinθ·d.y, −sinθ·d.x + cosθ·d.y)       # undo the overlay's rotation
if q.x < 0 or q.x > W or q.y < 0 or q.y > H: out = base                  # the rotated overlay does not cover p
t  = |q − o| / R
P  = t ≤ 0.30: lerp(α·core, β·ring, t/0.30)                               # premultiplied, colours in [0, 1]
     t < 0.55: lerp(β·ring, 0, (t − 0.30)/0.25)
     else:     0
out = base + P·(1 − base)                                                 # screen, on sRGB-encoded values
```
The gradient interpolates premultiplied colour, as CSS gradients do; α and β are at most 100/130 < 1. At the default position (18, 14) on a 3:2 frame R is 1.0006 × the long edge, so revision 1's long-edge rule agreed there by chance; at the centre R is 0.60 × the long edge, and the long-edge rule drew a leak 1.66 × too large. Style colours:
- warm: (255, 150, 70) → (255, 90, 60)
- amber: (255, 176, 64) → (230, 120, 40)
- rose: (255, 140, 160) → (220, 90, 120)
- prism: a hue sweep, using the same opacities

## 7. Other stages (parameters in rendering-v2.json)

- **`edit.geometry`** (stage 9) maps the source to the frame after the layered stages, each step in the frame the previous one produced (what the person sees): quarter turns → flips → perspective (§7.2) → straighten (rotate about the centre and zoom by the smallest factor that leaves no empty corner) → crop (`rect` in the straightened frame; a fixed aspect holds w/h in pixels). The whole chain is one projective map, resampled once.
- **`edit.adjust`** maps onto the Develop model: `ev = exposure/50`, with contrast, highlights, shadows, temp, tint, saturation and vibrance passed through. Detail maps onto S1–S3; see `maps` in the JSON. It runs in source coordinates, so Detail radii follow the uncropped source long edge. *Provisional mapping.*
- **`edit.remove`** (stage 1) composites each applied stroke's stored patch (`derivedRef`: rect, RGB and feathered alpha at the full source resolution) onto the source pixels, in stroke order, before any other stage. Export composites it 1:1; preview composites the same patch scaled to the render's source size. A patch is never recomputed silently (`docs/v1/remove-evaluation.md` §7).
- **`background.replace`:** the subject matte composites the subject over an image (x, y, scale), a colour or a gradient. The replacement receives the photo's global colour (§1). It runs in source coordinates: x, y and scale place the replacement in the source frame, and `edit.geometry` then turns, straightens and crops it with the photo.
- **`background.focus`** is a depth-aware blur, specified in §7.1. It runs in source coordinates.
- **`portrait`** works per face, inside landmark-derived regions. It never changes eye colour, eye shape or skin-tone colour.
- **`border`** insets are fractions of the image width:
  - solid: [w, w, w]
  - frame: (w + s) on all sides, with a mat band s inside the frame band w
  - polaroid: side 0.055, top 0.055, bottom 0.24
- **`watermark`** height at size 34, as a fraction of the photo's short edge *(revision 2)*: text font size 0.06225, signature 0.08995, logo 0.09415 (revision 1: 0.047, 0.068, 0.079). It scales linearly with size/34. Anchors sit at 6/50/94 % of the frame.
  - **Why these values.** The prototype draws the watermark in fixed CSS px (text 18, signature 26, logo 30, × size/34), so its ratio to the photo depends on how large the photo is displayed. The values are the medians over the four phone references (iphone17, iphone17promax, pixel9pro, pixel10proxl), measured on the prototype's own layout with fonts loaded. As fractions of the photo they are resolution independent, so preview and export match. Revision 1's values were about 0.75–0.84 × what the phone screens show.
  - **Tablets (deviation W1).** On tablets the prototype's ratios are about half the phone ratios (ipadpro11, ipadpro13, pixeltablet: `docs/v1/contract-fixes-2.md` §5). Native keeps the phone ratios on every device, a recorded deviation like the Focus & Blur strength.
  - On a border, the watermark is centred in the bottom margin: 6 % from the bottom for polaroid, 1 % otherwise.
  - On a polaroid margin, the ink is #222222.

### 7.1 `background.focus` (revision 1)

The full algorithm is `docs/v1/depth-evaluation.md` §6 (§R1–§R9); `experiments/depth/refocus.py` is its executable reference and `rendering-v2.json` (`stages[background.focus].operators[0].constants`) carries the constants. This section fixes what the first contract left inconsistent with that specification.

**Depth source** (`tools.background.focus.depth.source`):
- `embedded` or `estimated`: a normalised depth map, stored as depth (0 near, 1 far). The renderer works in disparity, `D = 1 − depth`, normalised as §R2.1 and guided-filtered at the working size.
- `subject-matte`: **no depth.** The operator must not blur from a matte alone (§R8). The edit-recipe reader rejects `blur > 0` with this source; the panel shows the approved failure state instead of offering Blur.

**Focal plane.** `d_f = 1 − depth.focusDepth` when it is stored (it is resolved when the target is set). When it is null, `d_f` is the §R3 median under the target, or under the default target (subject matte centroid, else the image centre) when the target is null too.

**Circle of confusion** (per plane pixel, px):
```
R_max = blur/100 · 0.06 · longEdge
h     = 0.5 · depthOfField/100                      # 'Focus depth' slider: half-width of the sharp band
S     = max(d_f, 1 − d_f)                           # distance to the farther end of the depth range
c     = sign(D − d_f) · clamp((|D − d_f| − h)/max(S − h, 1e-6), 0, 1) · R_max
c     = 0 on the subject plane when the focus is on the subject (M(target) ≥ 0.5, or a null target with a subject)
```
The farthest content from the focal plane gets R_max, which is what the prototype's Blur slider shows; between the sharp band and that point, blur stays linear in real disparity (never a flat mask blur). The constants were measured against the approved bg-* screens (`docs/v1/contract-fixes-1.md` §1).

**Layers, kernels, compositing:** §R4 (K = 8 for export, 4 allowed for interactive preview), §R5, §R6. Pull-push pulls to a 1×1 level with exact 2×2 box means (odd rows and columns repeated) and pushes back with half-pixel bilinear upsampling (§R6).

**Long edge (revision 2).** The stage runs on the source, so `longEdge` in R_max, in the focus window and in the guided-filter radius is the uncropped source long edge.

**Replaced background.** Placed by §R2.4 "plane": `D_B = min(median of the original background disparity, max(0, median_subject − 0.10))`. It is recomputed from the stored depth map and matte; `depth.replacementDepth` is not read.

### 7.2 Perspective (revision 2)

Perspective runs in the frame produced by quarter turns and flips, W × H pixels, centre c = (W/2, H/2). With k = 0.3, v = vertical and h = horizontal:
```
top    = v > 0 ? 1 − k·v/100 : 1;     bottom = v < 0 ? 1 − k·|v|/100 : 1
right  = h > 0 ? 1 − k·h/100 : 1;     left   = h < 0 ? 1 − k·|h|/100 : 1
corner(sx, sy) = (c.x + sx·c.x·(sy < 0 ? top : bottom),  c.y + sy·c.y·(sx < 0 ? left : right)),   sx, sy ∈ {−1, +1}
K = the homography taking (0,0), (W,0), (W,H), (0,H) to corner(−1,−1), corner(1,−1), corner(1,1), corner(−1,1)
z = the smallest z ≥ 1 such that the quad z·(corner − c) + c contains the rectangle [0,W] × [0,H]
perspective = Zoom(z about c) · K
```
Positive vertical narrows the **top** edge; positive horizontal narrows the **right** edge. Each edge is scaled about the centre line, and the opposite edge is unchanged before the zoom. z leaves no empty area, the same rule as straighten; a port may solve it in closed form or numerically to within 1e-6.

The approved prototype does not warp the photo for perspective (deviation E2, an owner decision); this section defines the native behaviour.

## 8. Tolerances (native parity)

See `docs/v1/preset-pack.md` §Parity. In short, against `shared/fixtures/look-pack/golden.json`:
- each 17³ LUT node within 1e-3;
- each direct probe within 5e-4;
- each probe through a 33³ bake and trilinear lookup within 1e-3;
- the random vectors exact (field values within 1e-6).

Against `shared/fixtures/rendering/index.json` (revision 2): grain noise within 1e-4 and output within 2e-4; light leak farthest-corner ray within 1e-4 px, premultiplied overlay and output within 2e-4; background.focus scalars (CoC, half-width, R_max, focal disparity, highlight curve) within 1e-4, kernels within 1e-5, pull-push within 1e-4, and whole renders ΔE00 mean ≤ 1.0 / p99 ≤ 4 (§R9).

## Change log

| Revision | Date | Change | Affects lookVersion |
|---|---|---|---|
| 0 | — | Contract version 2 as first published (`e96349c`) | — |
| 1 | 2026-10-03 | Contract fixes 1 (`docs/v1/contract-fixes-1.md`). **background.focus:** maxBlurRadius 0.03 → 0.06 of the long edge; CoC normalised by S − h with S = max(d_f, 1 − d_f) instead of 1 − h; the subject plane stays sharp when the focus is on the subject; depth-of-field half-width stays 0.5·depthOfField/100 (depth-evaluation §R4 changed to match); pull-push pulls to 1×1 (G7); `subject-matte` means no depth and cannot blur (G3); depth direction and stored focus depth defined (G4); replacement placement by §R2.4, `replacementDepth` not read (G6); renderer goldens (G5). **Grain (F2):** chromaticity kept; supersampling below 2 px per cell. Develop constants and their digest are unchanged. | No: `developModel.constantsSha256` is unchanged, so every `lookVersion` is unchanged. No saved edit exists outside development devices; the revision number versions the rendering change instead |
| 2 | 2026-10-04 | Contract fixes 2 (`docs/v1/contract-fixes-2.md`). **Order (C1, C2):** `edit.remove` is stage 1, on the full-resolution source before `auto`; `edit.adjust`, `background.replace`, `background.focus` and `portrait` run in source coordinates (stages 5–8) and `edit.geometry` maps source → frame after them (stage 9); stage ids unchanged, order numbers 1–9 changed; resolution-relative radii in stages 1–8 are fractions of the uncropped source long edge. **Perspective (C3):** positive vertical narrows the top edge, positive horizontal the right edge, by 1 − 0.3·\|v\|/100, then the smallest no-empty-area zoom (§7.2). **Light leak (C4):** stops along the CSS farthest-corner ray instead of the long edge; the rotated overlay leaves uncovered frame areas untouched; constants in the JSON; goldens `lightLeak`. **Watermark:** heights at size 34 text 0.06225, signature 0.08995, logo 0.09415 of the short edge (phone medians; tablets deviation W1). Develop constants and their digest are unchanged. | No: `developModel.constantsSha256` is unchanged |
| 3 | 2026-10-04 | **background.focus, subject colour:** the de-contaminated subject colour F = (I − (1 − M)·B)/M is used, clipped to [0, 1], wherever the matte M > 0.02; the interior fill only below that. Revisions 1–2 used the interior fill below M = 0.3, which painted the subject's colour into a soft matte tail that extends past the subject (measured on a 12 MP portrait: a red glow 10–20 px wide beside a red shirt over a dark wall; red excess 18.8 → 0.1 levels; hair edge closer to the original). |
