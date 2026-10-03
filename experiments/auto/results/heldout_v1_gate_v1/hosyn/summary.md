# HO-SYN: hosyn

**Held-out synthetic-degradation evaluation.** Photographer-disjoint CC0/PD photos, frozen per-image degradations. Measures inversion of synthetic global degradations, NOT the rubric and NOT preference.

Manifest `experiments/auto/manifests/cc0ref_manifest.csv` split `public_holdout_syn` rows hash 399e6b8e1dca, 300 images (230 degraded, 70 identity).

| Arm | degraded: mean dE00 to clean (95% CI) | median | p90 | share improved | share worse >1 | identity: mean dE00 to input (95% CI) | identity share <= 1.5 |
|---|---|---|---|---|---|---|---|
| (degraded input itself) | 8.71 | 7.32 | 15.78 | - | - | 0.00 | 1.00 |
| Stage (a) research candidate: self-supervised on CC0/PD reference photos - NOT released, NOT validated as AI Auto (ship gates S1-S5 not met) + conservative gate gate_v1 | 7.27 (6.77-7.82) | 6.47 | 12.25 | 0.46 | 0.06 | 1.18 (0.63-1.81) | 0.77 |
