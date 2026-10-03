# HO-SYN: hosyn_photo_a_001

**Held-out synthetic-degradation evaluation.** Photographer-disjoint CC0/PD photos, frozen per-image degradations. Measures inversion of synthetic global degradations, NOT the rubric and NOT preference.

Manifest `experiments/auto/manifests/cc0ref_manifest.csv` split `public_holdout_syn` rows hash 399e6b8e1dca, 300 images (230 degraded, 70 identity).

| Arm | degraded: mean dE00 to clean (95% CI) | median | p90 | share improved | share worse >1 | identity: mean dE00 to input (95% CI) | identity share <= 1.5 |
|---|---|---|---|---|---|---|---|
| (degraded input itself) | 8.71 | 7.32 | 15.78 | - | - | 0.00 | 1.00 |
| Original (unchanged) - NOT AI Auto | 8.71 (8.10-9.36) | 7.32 | 15.78 | 0.00 | 0.00 | 0.00 (0.00-0.00) | 1.0 |
| Control: fixed auto-levels + grey-world WB (non-learned) - NOT AI Auto | 9.09 (8.46-9.75) | 7.36 | 17.67 | 0.41 | 0.34 | 3.56 (3.37-3.76) | 0.03 |
| Stage (a) research candidate: self-supervised on CC0/PD reference photos - NOT released, NOT validated as AI Auto (ship gates S1-S5 not met) | 6.64 (6.26-7.05) | 6.16 | 10.74 | 0.69 | 0.16 | 3.31 (2.79-3.90) | 0.2 |
