# Rubric run: ph1

**Data: PUBLIC HELD-OUT set (CC0/public-domain Commons photos, frozen before training, never tuned on). Held-out evaluation, but NOT the G0 frozen T1 set: no ship gate can be passed on it.**

Protocol 1.0.0 (lock e9dec2f5fda1), manifest `experiments/auto/manifests/ph1_manifest.csv` hash 241d0f13f47d, 370 images, analysis long edge 2048 px.

## candidate:photo_a_001+gate:gate_v1

**Stage (a) research candidate: self-supervised on CC0/PD reference photos - NOT released, NOT validated as AI Auto (ship gates S1-S5 not met) + conservative gate gate_v1**

| Class | n scorable | pass | pass rate | 95% CI bootstrap | 95% CI exact | S1 |
|---|---|---|---|---|---|---|
| portrait | 59 | 56 | 0.95 | 0.88-1.00 | 0.86-0.99 | PASS |
| sunset | 54 | 52 | 0.96 | 0.91-1.00 | 0.87-1.00 | PASS |
| night | 60 | 60 | 1.00 | 1.00-1.00 | 0.94-1.00 | PASS |
| backlit | 54 | 5 | 0.09 | 0.02-0.17 | 0.03-0.20 | FAIL |
| already_good | 60 | 55 | 0.92 | 0.83-0.98 | 0.82-0.97 | PASS |
| landscape | 39 | 39 | 1.00 | 1.00-1.00 | 0.91-1.00 | not gated |
| indoor_mixed | 44 | 44 | 1.00 | 1.00-1.00 | 0.92-1.00 | PASS |

| Class | Criterion | target | n | class mean | 95% CI | mean meets |
|---|---|---|---|---|---|---|
| portrait | skin_abs_dh_deg | <= 4.0 | 59 | +0.54 | +0.27 to +0.84 | yes |
| portrait | skin_chroma_ratio | <= 1.12 | 59 | +0.99 | +0.98 to +1.00 | yes |
| sunset | warm_abs_dh_deg | <= 4.0 | 54 | +0.23 | +0.06 to +0.47 | yes |
| sunset | warm_chroma_ratio | >= 0.95 and <= 1.1 | 54 | +1.00 | +0.99 to +1.00 | yes |
| night | clipLo_pp | <= 0.5 | 60 | -1.81 | -3.85 to -0.34 | yes |
| night | night_p50_dL | <= 3.0 | 60 | +0.14 | +0.03 to +0.26 | yes |
| backlit | clipHi_pp | <= 0.5 | 54 | -0.40 | -1.14 to -0.00 | yes |
| backlit | subject_dL | > 0.0 | 54 | -0.34 | -0.88 to +0.08 | no |
| already_good | dE00_mean | <= 3.0 | 60 | +0.62 | +0.23 to +1.09 | yes |
| indoor_mixed | skin_abs_dh_deg | <= 4.0 | 4 | +0.00 | +0.00 to +0.00 | yes |
| indoor_mixed | skin_chroma_ratio | <= 1.12 | 4 | +1.00 | +1.00 to +1.00 | yes |

