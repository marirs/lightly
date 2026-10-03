# Rubric run: ph1_photo_a_001

**Data: PUBLIC HELD-OUT set (CC0/public-domain Commons photos, frozen before training, never tuned on). Held-out evaluation, but NOT the G0 frozen T1 set: no ship gate can be passed on it.**

Protocol 1.0.0 (lock e9dec2f5fda1), manifest `experiments/auto/manifests/ph1_manifest.csv` hash 241d0f13f47d, 370 images, analysis long edge 2048 px.

## original

**Original (unchanged) - NOT AI Auto**

| Class | n scorable | pass | pass rate | 95% CI bootstrap | 95% CI exact | S1 |
|---|---|---|---|---|---|---|
| portrait | 59 | 59 | 1.00 | 1.00-1.00 | 0.94-1.00 | PASS |
| sunset | 54 | 54 | 1.00 | 1.00-1.00 | 0.93-1.00 | PASS |
| night | 60 | 60 | 1.00 | 1.00-1.00 | 0.94-1.00 | PASS |
| backlit | 54 | 0 | 0.00 | 0.00-0.00 | 0.00-0.07 | FAIL |
| already_good | 60 | 60 | 1.00 | 1.00-1.00 | 0.94-1.00 | PASS |
| landscape | 39 | 39 | 1.00 | 1.00-1.00 | 0.91-1.00 | not gated |
| indoor_mixed | 44 | 44 | 1.00 | 1.00-1.00 | 0.92-1.00 | PASS |

| Class | Criterion | target | n | class mean | 95% CI | mean meets |
|---|---|---|---|---|---|---|
| portrait | skin_abs_dh_deg | <= 4.0 | 59 | +0.00 | +0.00 to +0.00 | yes |
| portrait | skin_chroma_ratio | <= 1.12 | 59 | +1.00 | +1.00 to +1.00 | yes |
| sunset | warm_abs_dh_deg | <= 4.0 | 54 | +0.00 | +0.00 to +0.00 | yes |
| sunset | warm_chroma_ratio | >= 0.95 and <= 1.1 | 54 | +1.00 | +1.00 to +1.00 | yes |
| night | clipLo_pp | <= 0.5 | 60 | +0.00 | +0.00 to +0.00 | yes |
| night | night_p50_dL | <= 3.0 | 60 | +0.00 | +0.00 to +0.00 | yes |
| backlit | clipHi_pp | <= 0.5 | 54 | +0.00 | +0.00 to +0.00 | yes |
| backlit | subject_dL | > 0.0 | 54 | +0.00 | +0.00 to +0.00 | no |
| already_good | dE00_mean | <= 3.0 | 60 | +0.00 | +0.00 to +0.00 | yes |
| indoor_mixed | skin_abs_dh_deg | <= 4.0 | 4 | +0.00 | +0.00 to +0.00 | yes |
| indoor_mixed | skin_chroma_ratio | <= 1.12 | 4 | +1.00 | +1.00 to +1.00 | yes |

## control_levels_greyworld

**Control: fixed auto-levels + grey-world WB (non-learned) - NOT AI Auto**

| Class | n scorable | pass | pass rate | 95% CI bootstrap | 95% CI exact | S1 |
|---|---|---|---|---|---|---|
| portrait | 59 | 28 | 0.47 | 0.36-0.61 | 0.34-0.61 | FAIL |
| sunset | 54 | 12 | 0.22 | 0.11-0.33 | 0.12-0.36 | FAIL |
| night | 60 | 46 | 0.77 | 0.65-0.87 | 0.64-0.87 | FAIL |
| backlit | 54 | 3 | 0.06 | 0.00-0.13 | 0.01-0.15 | FAIL |
| already_good | 60 | 21 | 0.35 | 0.23-0.47 | 0.23-0.48 | FAIL |
| landscape | 39 | 39 | 1.00 | 1.00-1.00 | 0.91-1.00 | not gated |
| indoor_mixed | 44 | 43 | 0.98 | 0.93-1.00 | 0.88-1.00 | PASS |

| Class | Criterion | target | n | class mean | 95% CI | mean meets |
|---|---|---|---|---|---|---|
| portrait | skin_abs_dh_deg | <= 4.0 | 59 | +4.82 | +3.58 to +6.23 | no |
| portrait | skin_chroma_ratio | <= 1.12 | 59 | +1.00 | +0.96 to +1.04 | yes |
| sunset | warm_abs_dh_deg | <= 4.0 | 54 | +6.27 | +4.79 to +8.08 | no |
| sunset | warm_chroma_ratio | >= 0.95 and <= 1.1 | 54 | +0.98 | +0.95 to +1.01 | yes |
| night | clipLo_pp | <= 0.5 | 60 | +0.41 | +0.23 to +0.65 | yes |
| night | night_p50_dL | <= 3.0 | 60 | -0.80 | -1.29 to -0.30 | yes |
| backlit | clipHi_pp | <= 0.5 | 54 | +0.90 | -0.14 to +2.10 | no |
| backlit | subject_dL | > 0.0 | 54 | -2.32 | -2.86 to -1.78 | no |
| already_good | dE00_mean | <= 3.0 | 60 | +3.40 | +3.14 to +3.65 | no |
| indoor_mixed | skin_abs_dh_deg | <= 4.0 | 4 | +1.75 | +0.24 to +4.03 | yes |
| indoor_mixed | skin_chroma_ratio | <= 1.12 | 4 | +0.97 | +0.90 to +1.03 | yes |

## candidate:photo_a_001

**Stage (a) research candidate: self-supervised on CC0/PD reference photos - NOT released, NOT validated as AI Auto (ship gates S1-S5 not met)**

| Class | n scorable | pass | pass rate | 95% CI bootstrap | 95% CI exact | S1 |
|---|---|---|---|---|---|---|
| portrait | 59 | 53 | 0.90 | 0.81-0.97 | 0.79-0.96 | PASS |
| sunset | 54 | 36 | 0.67 | 0.54-0.80 | 0.53-0.79 | FAIL |
| night | 60 | 43 | 0.72 | 0.60-0.83 | 0.59-0.83 | FAIL |
| backlit | 54 | 9 | 0.17 | 0.07-0.28 | 0.08-0.29 | FAIL |
| already_good | 60 | 32 | 0.53 | 0.40-0.67 | 0.40-0.66 | FAIL |
| landscape | 39 | 39 | 1.00 | 1.00-1.00 | 0.91-1.00 | not gated |
| indoor_mixed | 44 | 44 | 1.00 | 1.00-1.00 | 0.92-1.00 | PASS |

| Class | Criterion | target | n | class mean | 95% CI | mean meets |
|---|---|---|---|---|---|---|
| portrait | skin_abs_dh_deg | <= 4.0 | 59 | +2.07 | +1.78 to +2.37 | yes |
| portrait | skin_chroma_ratio | <= 1.12 | 59 | +0.99 | +0.97 to +1.01 | yes |
| sunset | warm_abs_dh_deg | <= 4.0 | 54 | +1.50 | +1.19 to +1.83 | yes |
| sunset | warm_chroma_ratio | >= 0.95 and <= 1.1 | 54 | +0.98 | +0.96 to +0.99 | yes |
| night | clipLo_pp | <= 0.5 | 60 | -2.12 | -4.40 to -0.38 | yes |
| night | night_p50_dL | <= 3.0 | 60 | -0.66 | -1.60 to +0.28 | yes |
| backlit | clipHi_pp | <= 0.5 | 54 | +0.20 | -0.77 to +1.00 | yes |
| backlit | subject_dL | > 0.0 | 54 | -0.86 | -1.71 to +0.04 | no |
| already_good | dE00_mean | <= 3.0 | 60 | +3.44 | +2.95 to +3.97 | no |
| indoor_mixed | skin_abs_dh_deg | <= 4.0 | 4 | +1.14 | +0.23 to +2.05 | yes |
| indoor_mixed | skin_chroma_ratio | <= 1.12 | 4 | +1.04 | +1.01 to +1.07 | yes |

