# Preset Conversion & Validation (M1)

Status: **for Codex review.** Code: `experiments/presets/` (isolated from `Lightly/`). Source collection: `~/Downloads/Presets - for lightly` (local only; not in git).

Distribution terms for these presets are tracked separately in `docs/m1/licensing.md` and are **not** part of the engineering acceptance below.

## 0. Verdict

| Question | Answer |
|---|---|
| Can every preset be read losslessly? | **Yes.** 11,078 files parsed (6,520 XMP, 2,966 DNG-embedded, 1,592 lrtemplate, incl. inside zips). 2 parse errors are reported with their exception text, never swallowed. Every `crs` key is kept |
| Is every parameter accounted for? | **Yes, with three separate statuses** (Codex M1 finding 1): **parsed** / **parameter coverage** / **validation**. "Modelled" now means *read by the renderer*. The set is derived at runtime from `lr_model.Preset`, not hand-listed. Coverage complete: 770 presets (136 without and 634 with approximated parameters); incomplete: 10,306. **Validated against Lightroom: 0** (§2) |
| Is the conversion faithful today? | **No.** On held-out preset families, the calibrated parametric approximation reaches median ΔE00 **4.8** against *candidate* Lightroom reference pairs (§3) (not applying the preset at all scores 7.8). 0% of held-out photos are within ΔE00 2, 2% within 3, 57% within 5, and 10% are *worse* than not applying the preset (§4) |
| What could make global colour faithful? | **Promising, not established:** extract each curated preset's global transform from a **Lightroom render of an identity (HALD) image**. Whether that LUT reproduces Lightroom on real photographs must be **measured** on photo exports (Codex M1 finding 4). The export kit does exactly this measurement (§6) |
| The existing app conversion (`scripts/ingest_presets.py`)? | Superseded. It silently drops 20+ parameter families, mis-scales exposure and white balance, and collapses curves (see spec §12) |

## 1. Inventory of the collection

`experiments/presets/inventory.py` produces `inventory.json`.

- **Process version:** PV 15.4 (5,595), 11.0 (4,660), 10.0 (409), and PV2010 "6.7" (408, legacy sliders).
- **Camera profile:** `Embedded` (7,534), `Default Color` (1,970), `Adobe Standard` (100), plus a few others.
- **White balance:**
  - Incremental temperature/tint: 6,852 presets. This is what Lightroom applies to JPEG/HEIC.
  - Absolute Kelvin: 2,030. Lightroom applies this to raw only.
- **Most common non-default parameters:**
  - Highlights/Shadows/Whites/Blacks: ~10,300 each.
  - Contrast: 10,137.
  - HSL: 7–10k per band.
  - Split toning / colour grading: ~8k.
  - Calibration primaries: 6–7k.
  - Clarity: 8,932.
  - Point curves: 9,965 (RGB) and ~7k (each of R/G/B).

## 2. Per-preset classification (`classify.py` → `conversion_summary.md`, `conversion_report.json`; tests `test_classify.py`)

Three statuses are kept separate (Codex M1 finding 1). Nothing is called "converted".
- **parsed:** read losslessly.
- **parameter coverage:** `complete` only if every non-default parameter is *read by the renderer* (modelled or approximated) or is not a look parameter.
- **validation:** `none` until a Lightroom reference comparison passes. Candidate DNG pairs are reported as candidate evidence, never as validation.

| Class | Meaning | Parameters |
|---|---|---|
| **modelled** | Read by `lr_model.render`. The key set is derived at runtime by recording what `Preset` reads | Exposure, Contrast, incremental WB, Vibrance, Saturation, parametric curve, point curves (RGB/R/G/B), HSL (8 × H/S/L), colour grading + legacy split toning, calibration primaries + shadow tint, grayscale + mixer |
| **approximated** | Read by the renderer, but local/adaptive in Lightroom (modelled as a global curve), or an unverified assumption | Highlights, Shadows, Whites, Blacks, Dehaze. Absolute Temperature/Tint are not applied to rendered photos, on the **unverified** assumption that Lightroom ignores them on JPEG/HEIC |
| **experimental** | Implemented as a spatial operator, unvalidated | Clarity, Texture (`lr_model.apply_local_contrast`) |
| **not-implemented** | Parsed and kept, not rendered | **CameraProfile other than Embedded** (the renderer never reads it), vignette, grain, local masks/brushes/gradients, creative-profile `Look` RGB tables, Point Color, PV2010 process, unrecognised keys |
| **not-a-look** | Detail or geometry, intentionally ignored | Sharpening, noise reduction, lens/CA/defringe, crop/perspective, and legacy PV2010 keys inactive under PV2012+ |

**Result over 11,076 parsed presets:**

| Coverage | Uses approximation | Presets |
|---|---|---|
| complete | no | 136 |
| complete | yes | 634 |
| incomplete | — | 10,306 |

Validated against Lightroom: **0**.

- 3,309 presets are incomplete *only* because of experimental Clarity/Texture.
- The largest not-implemented/experimental causes:

| Parameter | Presets |
|---|---|
| Clarity | 8,932 |
| Grain | ~2,700 |
| Texture | 2,095 |
| Vignette | ~1,800 |
| PV2010 process | 408 |
| Local masks | ~360 |
| Creative-profile `Look` | 192 |

The previous report's "177 converted" counted `CameraProfile = Adobe Standard` and vignette/grain as covered, although the renderer reads neither. That count is withdrawn.

## 3. Reference data used

**Candidate reference pairs extracted from the vendor DNG presets** (`dng_pairs.py`). They are *candidates*, not authoritative Lightroom-conversion accuracy (Codex M1 finding 7).

Each DNG was created by Lightroom from a JPEG/PNG. This is verified per file:
- `UniqueCameraModel` is JPEG/PNG.
- The profile is `Embedded`.
- The raw `LinearizationTable` equals the sRGB EOTF (max error 7.6e-6), so the stored bytes **are** the original sRGB pixels.
- The DNG's preview is Lightroom's own render with the embedded preset applied. This is now **checked per file**, and any failure rejects the pair:
  - `PreviewApplicationName` is Lightroom Classic (all are 15.2).
  - `PreviewColorSpace` = sRGB.
  - **Freshness:** the XMP `MetadataDate` is within 10 s of `PreviewDateTime` (max observed gap 1 s).
  - **Geometry:** orientation 1, no crop, preview aspect = raw default-crop aspect.
  - **Alignment:** the gradient structure of the resized original correlates ≥ 0.5 with the preview, and better than a rotated or mirrored copy does.
  - All 684 pass.
  - **Not verifiable:** `PreviewSettingsDigest` is Adobe-proprietary, so "the preview reflects exactly these settings" still rests on the freshness check.

Coverage:
- **684 valid pairs.** 548 are real photographs (all Huliluts, 47 families). 136 are near-uniform grey title cards (mostly WithLuke), which test tone and WB only.
- **40 rejected, with reasons:** 16-bit PNG-origin DNGs, not yet handled.

Limitations:
- The previews are 256 px JPEGs.
- The photo pairs come from one vendor.
- Grain and vignette are excluded from scoring: a 1 px blur is applied, and only the central 60% is scored when a vignette is set.

## 4. Accuracy of the parametric approximation

`calibrate.py` and `calibrate_spatial.py` fit about 150 free constants of `lr_model.py` (slider response curves and per-band/per-zone strengths) on 512 pairs. They then evaluate on **172 pairs from 12 preset families never seen in training**.

| Set | n | Not applying the preset (ΔE00 median) | Uncalibrated model | Calibrated model | p95 |
|---|---|---|---|---|---|
| Held-out photos | 98 | 7.76 | 5.55 | **4.76** | 10.4 |
| Held-out grey cards | 74 | 13.4 | 10.7 | 11.7 | 13.1 |
| Train photos | 450 | 7.50 | — | 4.16 | 8.0 |

- Adding the Clarity/Texture operator changes held-out photo ΔE from 4.96 to 4.92 for presets that use them. The effect is mostly spatial and small at 256 px.
- The grey-card failure is concentrated in one held-out family, "WithLuke Timeless" (54 pairs, ΔE ≈ 12.9). Lightroom brightens a mid-grey far more than our tone model predicts for Contrast +100 / Shadows +100. The cause is unconfirmed.

**Visual evidence:** `experiments/presets/heldout_quantiles.jpg` shows the 5th–98th percentile of held-out photos, each as original | Lightly | Lightroom. Per-pair sheets are in `experiments/presets/sheets/`.

**Systematic errors seen:**
1. Strong split-toning or colour-grading saturation is under-applied (Dark City Drone: Lightroom's strong orange highlights come out weak).
2. Strong teal/blue grades are under-applied (City Drone).
3. Some presets are over-contrasted. In 10% of held-out photos, our render is worse than not applying the preset at all.
4. Calibration primaries and shadow tint correlate most with residual error (r = 0.46).

**Conclusion:** re-deriving Adobe's undocumented operator maths from renders plateaus at a perceptible error. It is useful as a fallback and as a way to explain what each preset does, but **it does not meet a "faithful conversion" bar.**

## 5. Recommended path to faithful conversion

1. **Global colour/tone: HALD extraction (promising; fidelity to be measured, not assumed).**
   - Render a 33³ (or 64³) identity HALD image through Lightroom with each **curated** preset, and export it as 16-bit TIFF in sRGB.
   - Read the exported grid back as the Look LUT. This samples Lightroom's own output for colours *as they appear in the identity image*.
   - Whether that equals what Lightroom does to the same colours inside a photograph is **not established**. It holds only for purely global, pixel-independent operators, and is the hypothesis the photo-export comparison tests.
   - Caveat: local or adaptive operators (Highlights/Shadows/Whites/Blacks, Clarity, Dehaze) behave differently on a HALD image than on a photo. Neutralise them for the HALD render and handle them separately, as in point 2.
   - Cost: one export per curated preset (the launch set is ~25 Looks, not 11k).
2. **Local/adaptive operators:** keep them as named spatial operators in the rendering contract.
   - Clarity/Texture → local contrast.
   - Highlights/Shadows → the low-frequency local exposure operator already proposed for Auto (U10).
   - Calibrate their strength against Lightroom exports of real photos.
   - Report them as approximations per preset.
3. **Validation against reference exports (M4 acceptance):**
   - For each curated Look, export the 22 test photos from Lightroom at full resolution.
   - Compare against Lightly's export (ΔE00 mean/p95 per image, plus side-by-side sheets).
   - Proposed acceptance: mean ΔE00 ≤ 2 and p95 ≤ 5 per image. Anything else is listed with its reason.
4. **Parametric model (this experiment):** keep it as the fallback for presets without a HALD export, labelled with its measured error. Never present it as faithful.

## 6. Shortlist and Lightroom export kit (prepared)

- **Provisional shortlist:** 18 Looks across 5 categories, each with reasons and contact sheets. See `docs/m1/shortlist.md`; the code is `experiments/presets/shortlist.py`, and human decisions are in `shortlist_review.json`.
- **Export kit:** `experiments/presets/lr_kit/` (generated `kit/` is git-ignored, 51 MB). It contains:
  - a 16-bit sRGB identity HALD (64³)
  - the 22 test photos
  - the 18 original preset files, plus generated "global-only" XMPs with local/spatial sliders zeroed
  - Lightroom Classic instructions with exact export settings and naming
- **Ingest:** `ingest_kit.py` extracts 33³ LUTs from the HALD exports, applies them to the originals, and compares the result with Lightroom's photo exports.
  - Acceptance: per photo, mean ΔE00 ≤ 2 and p95 ≤ 5. A Look is "validated" only if all photos pass and Lightroom's neutral (no-preset) export reproduces the input.
  - Self-test without Lightroom (`test_kit_roundtrip.py`): a known LUT is recovered within 2/255, a correct export is reported validated, and a wrong export is reported failed.
  - **Not yet verified:** that Lightroom accepts the generated global-only XMPs. The README asks for this to be reported if not.
- **Remaining input:** running the kit in Lightroom (about 30–45 min). Nothing else blocks it.

## 7. Reproduce

```bash
cd experiments/presets
python inventory.py  "<preset root>"   # inventory.json
python classify.py   "<preset root>"   # conversion_report.json, conversion_summary.md
python dng_pairs.py  "<preset root>" pairs
python calibrate.py natural && python calibrate_spatial.py natural
```
