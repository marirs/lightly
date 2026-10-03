# Rubric run: dev22_pipeline_check

**Data: splits ['dev'] - NOT the frozen held-out set (DEV-22 is development data that M1 tuned on). Pipeline verification only; NOT an evaluation result and NOT evidence of quality.**

Protocol 1.0.0 (lock e9dec2f5fda1), manifest `experiments/auto/eval/dev22_manifest.csv` hash a7dae3151707, 22 images, analysis long edge 2048 px.

## original

**Original (unchanged) - NOT AI Auto**

| Class | n scorable | pass | pass rate | 95% CI bootstrap | 95% CI exact | S1 |
|---|---|---|---|---|---|---|
| portrait | 7 | 7 | 1.00 | 1.00-1.00 | 0.59-1.00 | PASS |
| sunset | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | PASS |
| night | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | PASS |
| backlit | 3 | 0 | 0.00 | 0.00-0.00 | 0.00-0.71 | FAIL |
| already_good | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | PASS |
| landscape | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | not gated |

| Class | Criterion | target | n | class mean | 95% CI | mean meets |
|---|---|---|---|---|---|---|
| portrait | skin_abs_dh_deg | <= 4.0 | 7 | +0.00 | +0.00 to +0.00 | yes |
| portrait | skin_chroma_ratio | <= 1.12 | 7 | +1.00 | +1.00 to +1.00 | yes |
| sunset | warm_abs_dh_deg | <= 4.0 | 3 | +0.00 | +0.00 to +0.00 | yes |
| sunset | warm_chroma_ratio | >= 0.95 and <= 1.1 | 3 | +1.00 | +1.00 to +1.00 | yes |
| night | clipLo_pp | <= 0.5 | 3 | +0.00 | +0.00 to +0.00 | yes |
| night | night_p50_dL | <= 3.0 | 3 | +0.00 | +0.00 to +0.00 | yes |
| backlit | clipHi_pp | <= 0.5 | 3 | +0.00 | +0.00 to +0.00 | yes |
| backlit | skin_abs_dh_deg | <= 4.0 | 1 | +0.00 | +0.00 to +0.00 | yes |
| backlit | skin_chroma_ratio | <= 1.12 | 1 | +1.00 | +1.00 to +1.00 | yes |
| backlit | subject_dL | > 0.0 | 3 | +0.00 | +0.00 to +0.00 | no |
| already_good | dE00_mean | <= 3.0 | 3 | +0.00 | +0.00 to +0.00 | yes |

## candidate:photo_a_001

**Stage (a) research candidate: self-supervised on CC0/PD reference photos - NOT released, NOT validated as AI Auto (ship gates S1-S5 not met)**

| Class | n scorable | pass | pass rate | 95% CI bootstrap | 95% CI exact | S1 |
|---|---|---|---|---|---|---|
| portrait | 7 | 6 | 0.86 | 0.57-1.00 | 0.42-1.00 | PASS |
| sunset | 3 | 1 | 0.33 | 0.00-1.00 | 0.01-0.91 | FAIL |
| night | 3 | 2 | 0.67 | 0.00-1.00 | 0.09-0.99 | FAIL |
| backlit | 3 | 0 | 0.00 | 0.00-0.00 | 0.00-0.71 | FAIL |
| already_good | 3 | 2 | 0.67 | 0.00-1.00 | 0.09-0.99 | FAIL |
| landscape | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | not gated |

| Class | Criterion | target | n | class mean | 95% CI | mean meets |
|---|---|---|---|---|---|---|
| portrait | skin_abs_dh_deg | <= 4.0 | 7 | +1.09 | +0.58 to +1.67 | yes |
| portrait | skin_chroma_ratio | <= 1.12 | 7 | +1.06 | +1.02 to +1.11 | yes |
| sunset | warm_abs_dh_deg | <= 4.0 | 3 | +1.01 | +0.35 to +1.94 | yes |
| sunset | warm_chroma_ratio | >= 0.95 and <= 1.1 | 3 | +0.91 | +0.85 to +1.02 | no |
| night | clipLo_pp | <= 0.5 | 3 | -0.36 | -0.56 to -0.00 | yes |
| night | night_p50_dL | <= 3.0 | 3 | +2.27 | +1.39 to +3.97 | yes |
| backlit | clipHi_pp | <= 0.5 | 3 | +0.47 | -0.01 to +1.42 | yes |
| backlit | skin_abs_dh_deg | <= 4.0 | 1 | +4.98 | +4.98 to +4.98 | no |
| backlit | skin_chroma_ratio | <= 1.12 | 1 | +0.83 | +0.83 to +0.83 | yes |
| backlit | subject_dL | > 0.0 | 3 | -3.78 | -6.90 to -1.78 | no |
| already_good | dE00_mean | <= 3.0 | 3 | +2.03 | +1.50 to +3.05 | yes |

## candidate:photo_a_001+gate:gate_v1

**Stage (a) research candidate: self-supervised on CC0/PD reference photos - NOT released, NOT validated as AI Auto (ship gates S1-S5 not met) + conservative gate gate_v1**

| Class | n scorable | pass | pass rate | 95% CI bootstrap | 95% CI exact | S1 |
|---|---|---|---|---|---|---|
| portrait | 7 | 7 | 1.00 | 1.00-1.00 | 0.59-1.00 | PASS |
| sunset | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | PASS |
| night | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | PASS |
| backlit | 3 | 0 | 0.00 | 0.00-0.00 | 0.00-0.71 | FAIL |
| already_good | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | PASS |
| landscape | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | not gated |

| Class | Criterion | target | n | class mean | 95% CI | mean meets |
|---|---|---|---|---|---|---|
| portrait | skin_abs_dh_deg | <= 4.0 | 7 | +0.19 | +0.00 to +0.58 | yes |
| portrait | skin_chroma_ratio | <= 1.12 | 7 | +1.02 | +1.00 to +1.05 | yes |
| sunset | warm_abs_dh_deg | <= 4.0 | 3 | +0.00 | +0.00 to +0.00 | yes |
| sunset | warm_chroma_ratio | >= 0.95 and <= 1.1 | 3 | +1.00 | +1.00 to +1.00 | yes |
| night | clipLo_pp | <= 0.5 | 3 | +0.00 | +0.00 to +0.00 | yes |
| night | night_p50_dL | <= 3.0 | 3 | +0.00 | +0.00 to +0.00 | yes |
| backlit | clipHi_pp | <= 0.5 | 3 | -0.01 | -0.01 to +0.00 | yes |
| backlit | skin_abs_dh_deg | <= 4.0 | 1 | +0.27 | +0.27 to +0.27 | yes |
| backlit | skin_chroma_ratio | <= 1.12 | 1 | +0.98 | +0.98 to +0.98 | yes |
| backlit | subject_dL | > 0.0 | 3 | -1.46 | -2.65 to +0.00 | no |
| already_good | dE00_mean | <= 3.0 | 3 | +0.00 | +0.00 to +0.00 | yes |

