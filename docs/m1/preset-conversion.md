# Preset Conversion & Validation (M1)

Status: **for Codex review.** Code: `experiments/presets/` (isolated from `Lightly/`). Source collection: `~/Downloads/Presets - for lightly` (local only; not in git).

Distribution terms for these presets are tracked separately in `docs/m1/licensing.md` and are **not** part of the engineering acceptance below.

## 0. Verdict

| Question | Answer |
|---|---|
| Can every preset be read losslessly? | **Yes.** 11,078 files parsed (6,520 XMP, 2,966 DNG-embedded, 1,592 lrtemplate, incl. inside zips). 2 parse errors are reported with their exception text, never swallowed. Every `crs` key is kept |
| Is every parameter accounted for? | **Yes.** Each non-default parameter of each preset is classified (§2). A preset with any unsupported parameter is `partial` and is never marked converted |
| Is the conversion faithful today? | **No.** On held-out preset families, the calibrated parametric approximation reaches median ΔE00 **4.8** against Lightroom's own renders (not applying the preset at all scores 7.8). 0% of held-out photos are within ΔE00 2, 2% within 3, 57% within 5, and 10% are *worse* than not applying the preset (§4) |
| What would make global colour faithful? | Extract each curated preset's global transform from a **Lightroom render of an identity (HALD) image** instead of re-deriving Adobe's maths (§5). This needs Lightroom exports (blocker B1) |
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

## 2. Per-preset classification (`classify.py` → `conversion_summary.md`, `conversion_report.json`)

| Class | Meaning | Parameters |
|---|---|---|
| **modelled** | Global op implemented in the Lightly renderer; accuracy measured in §4 | Exposure, Contrast, incremental WB, Vibrance, Saturation, parametric curve, point curves (RGB/R/G/B), HSL (8 bands × H/S/L), colour grading + legacy split toning, calibration primaries + shadow tint, grayscale + mixer |
| **approximated** | Local or adaptive in Lightroom, but modelled as a global curve | Highlights, Shadows, Whites, Blacks, Dehaze. Absolute Temperature/Tint are ignored on rendered photos, matching Lightroom's behaviour on JPEG |
| **spatial** | Not a colour transform; carried as Look parameters outside the LUT | Post-crop vignette (amount, midpoint, feather, roundness, style, highlight contrast), grain |
| **unsupported** | Not converted; listed per preset | Clarity, Texture, local masks/brushes/gradients, creative-profile `Look` RGB tables, Point Color, PV2010 process, unrecognised keys |
| **not-a-look** | Detail or geometry, intentionally ignored | Sharpening, noise reduction, lens/CA/defringe, crop/perspective, and legacy PV2010 keys that are inactive under PV2012+ |

**Result over 11,076 parsed presets:**

| Status | Presets |
|---|---|
| converted (all parameters modelled/spatial/not-a-look) | 177 |
| approximated (≥ 1 approximated parameter, nothing unsupported) | 1,494 |
| partial (≥ 1 unsupported parameter) | 9,405 |

Of the 9,405 partial presets, **8,155 are partial only because of Clarity and/or Texture.** Unsupported parameters by number of presets affected:

| Parameter | Presets |
|---|---|
| Clarity | 8,932 |
| Texture | 2,095 |
| PV2010 process | 408 |
| Local masks | ~360 |
| Creative-profile `Look` | 192 |

## 3. Reference data used

**Lightroom-rendered pairs extracted from the vendor DNG presets** (`dng_pairs.py`).

Each DNG was created by Lightroom from a JPEG/PNG. This is verified per file:
- `UniqueCameraModel` is JPEG/PNG.
- The profile is `Embedded`.
- The raw `LinearizationTable` equals the sRGB EOTF (max error 7.6e-6), so the stored bytes **are** the original sRGB pixels.
- The DNG's preview is Lightroom's own render with the embedded preset applied.

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

1. **Global colour/tone, exact: HALD extraction.**
   - Render a 33³ (or 64³) identity HALD image through Lightroom with each **curated** preset, and export it as 16-bit TIFF in sRGB.
   - Read the exported grid back directly as the Look LUT. This captures Adobe's real maths for every global operator: curves, HSL, grading, calibration, profiles, and creative-profile RGB tables.
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

## 6. Blockers and inputs needed

- **B1, Lightroom exports.** Lightroom isn't installed on this machine. Needed: (a) HALD renders for the curated presets; (b) full-resolution exports of the test photos with those presets. A ready-to-run export kit (HALD image, folder layout, settings) can be prepared in a few minutes once the curated list exists.
- **B2, curated list.** Which ~25 presets make up V1 (5 categories × 4–6 stops). Validation effort should go there, not into all 11k.

## 7. Reproduce

```bash
cd experiments/presets
python inventory.py  "<preset root>"   # inventory.json
python classify.py   "<preset root>"   # conversion_report.json, conversion_summary.md
python dng_pairs.py  "<preset root>" pairs
python calibrate.py natural && python calibrate_spatial.py natural
```
