# Contract fixes 2: stage order, perspective, light leak, watermark

Rendering contract v2 **revision 2** (2026-10-04). The iOS Edit/Effects implementation (`docs/v1/slice4-ios.md`, "Contract gaps") found four places where revision 1 was ambiguous or contradicted another approved document (C1–C4). The coordinator decided each one; this document records the decisions, the reasons, and what each platform must change. A fifth change corrects the watermark heights against the approved phone screens.

Changed files: `shared/contracts/{build_rendering_v2.py, rendering-v2.json, rendering-v2.md, make_rendering_goldens.py}`, `shared/contracts/tests/{test_contracts.py, test_rendering_goldens.py}`, `shared/look-pack/reference_model.py` (+ `tests/test_reference_model.py`), `shared/fixtures/rendering/{index.json, README.md, leak-*.f32}` (new light-leak goldens; every earlier golden array is byte-identical).

`developModel.constantsSha256` is unchanged, so **every `lookVersion` and the look pack are unchanged**. The change is versioned by `rendering-v2.json` `"revision": 2` and the change log in `rendering-v2.md`. Stage ids are unchanged; stage `order` numbers 1–9 changed.

## New stage order

| # | Stage | Frame | Revision 1 # |
|---|---|---|---|
| 1 | `edit.remove` | source (full resolution) | 6 (frame) |
| 2 | `auto` | source | 1 |
| 3 | `develop.global` | source | 2 |
| 4 | `develop.spatial` | source | 3 |
| 5 | `edit.adjust` | source | 5 (frame) |
| 6 | `background.replace` | source | 7 (frame) |
| 7 | `background.focus` | source | 8 (frame) |
| 8 | `portrait` | source | 9 (frame) |
| 9 | `edit.geometry` | source → frame | 4 |
| 10 | `effects` | frame | 10 |
| 11 | `border` | frame → canvas | 11 |
| 12 | `watermark` | canvas | 12 |

## 1. C1: Remove runs first, on the source

**Decision.** `edit.remove` is stage 1. Each applied stroke's stored patch (rect, RGB, feathered alpha, at the full source resolution) is composited onto the source pixels in stroke order, before `auto` and every tone or colour stage. Export composites it 1:1; preview composites the same patch scaled to the render's source size.

**Reason.** `docs/v1/remove-evaluation.md` §7 (the approved Remove recommendation) requires Remove to run "on the full-resolution source pixels, before tone and colour adjustments", as heal does in Lightroom. Revision 1 put it at stage 6, in the frame after Adjust, which contradicted §7: a patch computed there depends on the Look, Auto and Adjust, so any later tone or colour change would invalidate it and re-run a model that takes seconds per stroke. On the source, a patch depends only on the source and the strokes, so it is computed once and replayed exactly.

## 2. C2: Adjust, Background and Portrait in source coordinates; geometry after them

**Decision.** `edit.adjust` (5), `background.replace` (6), `background.focus` (7) and `portrait` (8) run in source coordinates. `edit.geometry` (9) then maps source → frame. `effects` (10) stays in the frame, after geometry.

**Reasons.**
- Scene mattes, depth maps and face landmarks are computed on the source. Running the layered stages there uses them without resampling them through the crop, rotation and keystone, and a crop change never invalidates them.
- Colour is per pixel, so Adjust's colour is identical in either place. The only visible difference is that **resolution-relative radii** (Detail's noise reduction, clarity and sharpening in `edit.adjust`; Focus & Blur's R_max, kernels, focus window and guided filter) are fractions of the **uncropped source long edge**. A tight crop therefore shows a slightly larger blur relative to the frame than revision 1 implied. That is the accepted cost.
- The replacement background is placed in the source frame (x, y, scale) and turned, straightened and cropped with the photo, as the prototype does (its background layer sits inside the transformed photo element).
- Effects stays after geometry for the reasons rendering-v2 §1 already gives: vignettes are post-crop, and grain must not be resampled by rotation or blurred by Focus & Blur.

## 3. C3: Perspective

**Decision** (rendering-v2 §7.2). Perspective runs in the frame produced by quarter turns and flips. Positive vertical narrows the **top** edge, negative vertical the bottom edge; positive horizontal narrows the **right** edge, negative horizontal the left edge. The narrowed edge is scaled about the centre line by `1 − 0.3·|value|/100`; the opposite edge is unchanged. The keystone is the homography taking the frame's corners to those trapezoid corners. It is then zoomed about the centre by the smallest z ≥ 1 that leaves no empty area (the same rule as straighten). The JSON carries `edgeScalePerUnit: 0.3`.

**Reason.** Revision 1 said "±100 scales the far edge by 1 ∓ 0.3" without saying which edge is far for each sign or how the empty area is removed. This is the convention iOS already implements (`GeometryStage.swift`, `keystone`), so it costs nothing on iOS and gives Android a definition.

**Note.** The approved prototype does not warp the photo for perspective; that is deviation E2, an owner decision. This section defines the native behaviour only.

## 4. C4: Light-leak geometry

**Decision** (rendering-v2 §6, "Light leak"). Follow the approved prototype's CSS exactly (`docs/ui/app/app.js`, `photoHTML`, `fx.leak`):

```
radial-gradient(circle at x% y%, rgba(core, intensity/130), rgba(ring, intensity/400) 30%, transparent 55%)
mix-blend-mode: screen;  transform: rotate(rotation deg)
```

- A CSS `circle` with no size is `farthest-corner`. The stop positions are fractions of R, the distance from the leak centre (x·W/100, y·H/100) to the farthest frame corner, **not of the long edge**.
- The rotation is a CSS transform of the frame-sized overlay about the frame centre, clockwise positive. Frame pixel p samples the gradient at `q = c + Rot(−θ)(p − c)`. Where q falls outside the frame rectangle, the rotated overlay does not cover p and **there is no leak**.
- Between stops the colour is interpolated premultiplied, as CSS gradients are; the blend is screen on sRGB-encoded values: `out = base + P·(1 − base)`.
- The JSON carries the shape, ray, stops, interpolation, rotation, blend and style colours under `stages[effects].operators[lightLeak].constants`.

**Reason.** Revision 1 said "fades to 0 at 55 % of the long edge", which is not what the prototype draws. At the default position (18, 14) on a 3:2 frame, R is 1.0006 × the long edge, so the two rules agree there by chance (iOS measured 0.05 %). At other positions they do not. With the leak at the centre of a 3:2 frame, R is 0.60 × the long edge, so the revision-1 leak was 1.66 × too large. On a 2:3 portrait frame at the default position, R is 1.019 × the long edge.

**Reference and goldens.** `reference_model.light_leak_farthest_corner`, `light_leak_premultiplied` and `apply_light_leak` implement the rule. `shared/fixtures/rendering/index.json` → `lightLeak` has four cases on the grain ramp: the default warm leak; a centred leak, where the ray differs most from the long edge; the edit-recipe example (amber, intensity 60, (80, 10), rotation −30°, portrait frame); and rose at intensity 100 rotated 90°, which leaves the frame's sides uncovered. Each stores R, the premultiplied overlay and the blended output. Tolerances: R within 1e-4 px, arrays within 2e-4. Prism has no golden: its hue sweep is still provisional.

**Observed, not changed (for the coordinator).** The prototype's `photoHTML` ignores `fx.leak.style`: every style draws the warm colours. The contract's amber, rose and prism colours are therefore not visible in any approved screen. Separately, the prototype layers the overlays as leak → grain → vignette, while the contract evaluates vignette before grain (rendering-v2 §1, reason 3). Neither is part of this revision.

## 5. Watermark heights

**Decision** (rendering-v2 §7, JSON `stages[watermark].operators[0].constants`). At size 34, as a fraction of the photo's short edge, linear in size/34:

| | Revision 1 | Revision 2 |
|---|---|---|
| Text font size | 0.047 | **0.06225** |
| Signature height | 0.068 | **0.08995** |
| Logo height | 0.079 | **0.09415** |

**Reason.** The prototype draws the watermark in fixed CSS px (text 18 px, signature 26 px, logo 30 px, × size/34), so its ratio to the photo depends on how large the photo is displayed. Revision 1's values were about 0.75–0.84 × what the approved phone screens show. Revision 2 takes the median over the four phone references, measured with Playwright on the prototype's own `layoutFor`/`stateFor` with fonts loaded. As fractions of the photo they are resolution independent, so preview and export match.

| Phone reference | Text | Signature | Logo |
|---|---|---|---|
| iphone17 | 0.0671 | 0.0970 | 0.1166 |
| iphone17promax | 0.0613 | 0.0886 | 0.0961 |
| pixel9pro | 0.0632 | 0.0913 | 0.0922 |
| pixel10proxl | 0.0603 | 0.0870 | 0.0844 |
| **Median** | **0.06225** | **0.08995** | **0.09415** |

**Tablets: deviation W1.** On tablets the prototype draws the same CSS px over a much larger photo, so the ratios are about half the phone ratios. Native keeps the phone ratios on every device. This is a recorded deviation, the same trade-off as the Focus & Blur strength (`docs/v1/contract-fixes-1.md` §1, conflict 1): a resolution-independent renderer cannot reproduce every device.

| Tablet reference | Text | Signature | Logo |
|---|---|---|---|
| ipadpro11 | 0.032–0.035 | 0.047–0.051 | 0.058–0.061 |
| ipadpro13 | 0.026–0.030 | 0.038–0.044 | 0.048 |
| pixeltablet | 0.032–0.034 | 0.047–0.049 | 0.054–0.065 |

## 6. Porting notes

### Both platforms
- Require `rendering-v2.json` `"revision": 2`.
- Load the light-leak goldens from `shared/fixtures/rendering/index.json` → `lightLeak` (the arrays are `leak-*.f32`) and compare R, the premultiplied overlay and the output.
- Read the watermark heights from the JSON constants (`textFontSize`, `signatureHeight`, `logoHeight`) rather than hard-coding them.
- Every earlier golden (focus, grain, kernels, pull-push) is byte-identical; only `index.json`'s revision and the new `lightLeak` section changed.

### iOS
iOS already follows C1–C3 (Remove patches replayed on the source before stage 1; Adjust and stages 7–9 in source coordinates with geometry after them; top/right keystone with the no-empty-area zoom). The `CONTRACT GAP` markers for C1–C3 can now cite revision 2 instead. Code changes:
1. **Light-leak radius** in `ios/Lightly/ImageEngine/Effects/EffectsStage.swift`, `LightLeakEvaluator`. Replace `longEdge = max(frameWidth, frameHeight)` with the farthest-corner distance from `centre` to the four frame corners, and divide by it in `apply`. Update the doc comment ("fading to 0 at 55 % of the long edge").
2. **Uncovered corners**, also in `LightLeakEvaluator.apply`. When `q` is outside `[0, W] × [0, H]`, return `rgb` unchanged. The current code samples the gradient there, which paints leak where the prototype's rotated overlay does not reach. This only matters when `rotation ≠ 0`. It goes slightly beyond the "radius only" expectation, but it is the same C4 rule (the CSS rotation of the overlay), and the `rose-full-rotated-landscape` golden checks it.
3. **Revision check** in `ios/Lightly/ImageEngine/Develop/DevelopModel.swift`: `requiredContractRevision` 1 → 2, and its comment ("contract fixes 1") → "contract fixes 2".
4. **Watermark heights** (section 5) in the watermark stage: text 0.06225, signature 0.08995, logo 0.09415 of the short edge at size 34.

### Android (slice 4 not built yet): the full rule set
1. **Order.** Remove (1) → auto (2) → develop.global (3) → develop.spatial (4) → edit.adjust (5) → background.replace (6) → background.focus (7) → portrait (8) → edit.geometry (9) → effects (10) → border (11) → watermark (12).
2. **Remove (C1).** Composite each applied stroke's stored patch onto the full-resolution source, in stroke order, before `auto`. Export 1:1; preview scales the same patch to the render's source size. Never re-run the model because a tone, colour, crop or effect changed.
3. **Source-coordinate stages (C2).** Adjust, Background replacement, Focus & Blur and Portrait read mattes, depth, faces and strokes in source coordinates, without mapping them through geometry. Every resolution-relative radius in stages 1–8 (Detail's S1–S3 radii, R_max = blur/100 · 0.06 · long edge, the focus window, the guided-filter radius) uses the **uncropped source long edge**. The replacement background is placed (x, y, scale) in the source frame.
4. **Geometry (stage 9).** One projective map, resampled once (bilinear): quarter turns (clockwise) → flips (in the turned frame) → perspective → straighten (rotate about the centre, clockwise positive, zoom `max(cos + H/W·sin, cos + W/H·sin)`) → crop (`rect` in the straightened frame). Map marks and touches through the same transform; store content points in source coordinates.
5. **Perspective (C3, rendering-v2 §7.2).** In the turned and flipped W × H frame: `top = 1 − 0.3·v/100` if v > 0, `bottom = 1 − 0.3·|v|/100` if v < 0, `right = 1 − 0.3·h/100` if h > 0, `left = 1 − 0.3·|h|/100` if h < 0, else 1. Corner (sx, sy) ∈ {±1}² maps to `(cx + sx·cx·(sy < 0 ? top : bottom), cy + sy·cy·(sx < 0 ? left : right))`. K is the homography from the frame's corners to those corners. Then zoom about the centre by the smallest z ≥ 1 for which the zoomed quad contains `[0, W] × [0, H]` (closed form or bisection, to within 1e-6). iOS's `GeometryTransform.keystone` is a working reference.
6. **Effects (stage 10, frame).** Light leak → preset vignette → user vignette → preset grain → user grain, as rendering-v2 §6.
7. **Light leak (C4).** `o = (x·W/100, y·H/100)`, `c = (W/2, H/2)`, θ = rotation in radians. R is the largest distance from o to the four frame corners. For each pixel centre p: `d = p − c`, `q = c + (cosθ·d.x + sinθ·d.y, −sinθ·d.x + cosθ·d.y)`; no leak if q is outside `[0, W] × [0, H]`. `t = |q − o|/R`. The premultiplied colour P is `lerp(α·core, β·ring, t/0.30)` for t ≤ 0.30, `lerp(β·ring, 0, (t − 0.30)/0.25)` for t < 0.55, else 0, with α = intensity/130, β = intensity/400 and colours in [0, 1]. Output: `base + P·(1 − base)` on sRGB-encoded values. Check it against the `lightLeak` goldens.
8. **Watermark** (section 5): text 0.06225, signature 0.08995, logo 0.09415 of the photo's short edge at size 34, linear in size/34, on every device (tablets: deviation W1).
9. **Revision check:** require `"revision": 2`.
