# Rubric run: dev22_pipeline_check_v1.0.0

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

## control_levels_greyworld

**Control: fixed auto-levels + grey-world WB (non-learned) - NOT AI Auto**

| Class | n scorable | pass | pass rate | 95% CI bootstrap | 95% CI exact | S1 |
|---|---|---|---|---|---|---|
| portrait | 7 | 6 | 0.86 | 0.57-1.00 | 0.42-1.00 | PASS |
| sunset | 3 | 0 | 0.00 | 0.00-0.00 | 0.00-0.71 | FAIL |
| night | 3 | 2 | 0.67 | 0.00-1.00 | 0.09-0.99 | FAIL |
| backlit | 3 | 0 | 0.00 | 0.00-0.00 | 0.00-0.71 | FAIL |
| already_good | 3 | 0 | 0.00 | 0.00-0.00 | 0.00-0.71 | FAIL |
| landscape | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | not gated |

| Class | Criterion | target | n | class mean | 95% CI | mean meets |
|---|---|---|---|---|---|---|
| portrait | skin_abs_dh_deg | <= 4.0 | 7 | +3.09 | +1.18 to +6.13 | yes |
| portrait | skin_chroma_ratio | <= 1.12 | 7 | +0.93 | +0.85 to +1.01 | yes |
| sunset | warm_abs_dh_deg | <= 4.0 | 3 | +7.61 | +6.10 to +8.99 | no |
| sunset | warm_chroma_ratio | >= 0.95 and <= 1.1 | 3 | +0.95 | +0.93 to +0.98 | no |
| night | clipLo_pp | <= 0.5 | 3 | +3.91 | +0.03 to +11.56 | no |
| night | night_p50_dL | <= 3.0 | 3 | -0.68 | -3.03 to +0.80 | yes |
| backlit | clipHi_pp | <= 0.5 | 3 | +3.14 | +0.29 to +7.72 | no |
| backlit | skin_abs_dh_deg | <= 4.0 | 1 | +4.87 | +4.87 to +4.87 | no |
| backlit | skin_chroma_ratio | <= 1.12 | 1 | +0.84 | +0.84 to +0.84 | yes |
| backlit | subject_dL | > 0.0 | 3 | -4.00 | -5.43 to -2.17 | no |
| already_good | dE00_mean | <= 3.0 | 3 | +3.62 | +3.42 to +3.79 | no |

## research_auto100

**Research FiveK model, 100% - RESEARCH-ONLY, never ships, NOT AI Auto**

| Class | n scorable | pass | pass rate | 95% CI bootstrap | 95% CI exact | S1 |
|---|---|---|---|---|---|---|
| portrait | 7 | 1 | 0.14 | 0.00-0.43 | 0.00-0.58 | FAIL |
| sunset | 3 | 0 | 0.00 | 0.00-0.00 | 0.00-0.71 | FAIL |
| night | 3 | 0 | 0.00 | 0.00-0.00 | 0.00-0.71 | FAIL |
| backlit | 3 | 0 | 0.00 | 0.00-0.00 | 0.00-0.71 | FAIL |
| already_good | 3 | 0 | 0.00 | 0.00-0.00 | 0.00-0.71 | FAIL |
| landscape | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | not gated |

| Class | Criterion | target | n | class mean | 95% CI | mean meets |
|---|---|---|---|---|---|---|
| portrait | skin_abs_dh_deg | <= 4.0 | 7 | +5.39 | +4.18 to +6.62 | no |
| portrait | skin_chroma_ratio | <= 1.12 | 7 | +1.38 | +1.24 to +1.51 | no |
| sunset | warm_abs_dh_deg | <= 4.0 | 3 | +5.98 | +4.16 to +7.20 | no |
| sunset | warm_chroma_ratio | >= 0.95 and <= 1.1 | 3 | +1.05 | +1.04 to +1.06 | yes |
| night | clipLo_pp | <= 0.5 | 3 | +8.60 | +5.06 to +12.76 | no |
| night | night_p50_dL | <= 3.0 | 3 | +6.22 | +2.53 to +9.21 | no |
| backlit | clipHi_pp | <= 0.5 | 3 | -2.91 | -8.71 to -0.00 | yes |
| backlit | skin_abs_dh_deg | <= 4.0 | 1 | +13.20 | +13.20 to +13.20 | no |
| backlit | skin_chroma_ratio | <= 1.12 | 1 | +1.22 | +1.22 to +1.22 | no |
| backlit | subject_dL | > 0.0 | 3 | -5.38 | -6.70 to -4.34 | no |
| already_good | dE00_mean | <= 3.0 | 3 | +8.31 | +5.94 to +10.63 | no |

## research_guard75_hp

**Research FiveK model + endpoint / 75% / warm-hue guardrails - RESEARCH-ONLY, never ships, NOT AI Auto**

| Class | n scorable | pass | pass rate | 95% CI bootstrap | 95% CI exact | S1 |
|---|---|---|---|---|---|---|
| portrait | 7 | 7 | 1.00 | 1.00-1.00 | 0.59-1.00 | PASS |
| sunset | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | PASS |
| night | 3 | 0 | 0.00 | 0.00-0.00 | 0.00-0.71 | FAIL |
| backlit | 3 | 0 | 0.00 | 0.00-0.00 | 0.00-0.71 | FAIL |
| already_good | 3 | 0 | 0.00 | 0.00-0.00 | 0.00-0.71 | FAIL |
| landscape | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | not gated |

| Class | Criterion | target | n | class mean | 95% CI | mean meets |
|---|---|---|---|---|---|---|
| portrait | skin_abs_dh_deg | <= 4.0 | 7 | +3.07 | +2.47 to +3.57 | yes |
| portrait | skin_chroma_ratio | <= 1.12 | 7 | +1.08 | +1.05 to +1.10 | yes |
| sunset | warm_abs_dh_deg | <= 4.0 | 3 | +3.54 | +2.77 to +4.00 | yes |
| sunset | warm_chroma_ratio | >= 0.95 and <= 1.1 | 3 | +1.01 | +0.99 to +1.03 | yes |
| night | clipLo_pp | <= 0.5 | 3 | +0.15 | +0.01 to +0.38 | yes |
| night | night_p50_dL | <= 3.0 | 3 | +6.20 | +3.59 to +8.26 | no |
| backlit | clipHi_pp | <= 0.5 | 3 | -0.24 | -1.89 to +1.15 | yes |
| backlit | skin_abs_dh_deg | <= 4.0 | 1 | +3.17 | +3.17 to +3.17 | yes |
| backlit | skin_chroma_ratio | <= 1.12 | 1 | +1.12 | +1.12 to +1.12 | no |
| backlit | subject_dL | > 0.0 | 3 | -2.55 | -2.79 to -2.25 | no |
| already_good | dE00_mean | <= 3.0 | 3 | +6.88 | +5.65 to +8.60 | no |

## smoke:smoke_full_001

**Pipeline smoke model (procedural synthetic scenes) - plumbing only, NOT an AI Auto candidate**

| Class | n scorable | pass | pass rate | 95% CI bootstrap | 95% CI exact | S1 |
|---|---|---|---|---|---|---|
| portrait | 7 | 6 | 0.86 | 0.57-1.00 | 0.42-1.00 | PASS |
| sunset | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | PASS |
| night | 3 | 0 | 0.00 | 0.00-0.00 | 0.00-0.71 | FAIL |
| backlit | 3 | 1 | 0.33 | 0.00-1.00 | 0.01-0.91 | FAIL |
| already_good | 3 | 1 | 0.33 | 0.00-1.00 | 0.01-0.91 | FAIL |
| landscape | 3 | 3 | 1.00 | 1.00-1.00 | 0.29-1.00 | not gated |

| Class | Criterion | target | n | class mean | 95% CI | mean meets |
|---|---|---|---|---|---|---|
| portrait | skin_abs_dh_deg | <= 4.0 | 7 | +0.88 | +0.42 to +1.38 | yes |
| portrait | skin_chroma_ratio | <= 1.12 | 7 | +0.99 | +0.91 to +1.10 | yes |
| sunset | warm_abs_dh_deg | <= 4.0 | 3 | +1.86 | +0.70 to +3.41 | yes |
| sunset | warm_chroma_ratio | >= 0.95 and <= 1.1 | 3 | +1.04 | +1.01 to +1.06 | yes |
| night | clipLo_pp | <= 0.5 | 3 | -0.36 | -0.56 to -0.00 | yes |
| night | night_p50_dL | <= 3.0 | 3 | +11.80 | +5.52 to +17.31 | no |
| backlit | clipHi_pp | <= 0.5 | 3 | +0.74 | -0.01 to +2.25 | no |
| backlit | skin_abs_dh_deg | <= 4.0 | 1 | +2.53 | +2.53 to +2.53 | yes |
| backlit | skin_chroma_ratio | <= 1.12 | 1 | +0.94 | +0.94 to +0.94 | yes |
| backlit | subject_dL | > 0.0 | 3 | +0.19 | -5.22 to +4.73 | yes |
| already_good | dE00_mean | <= 3.0 | 3 | +5.48 | +2.09 to +7.32 | no |

