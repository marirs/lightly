# Conservative gating: validation split only (tuning data, NOT an evaluation)

Run `photo_a_001`, 542 CC0REF validation photos, each scored clean (needs nothing) and with one synthetic degradation. Night-tagged 37, sunset-tagged 32 (machine captions; noisy). Metrics at 384 px long edge.

Predicted change (the already-good gate's input), clean vs degraded: AUC 0.6556; clean quantiles p10/25/50/75/90 [1.295, 1.742, 2.735, 4.621, 6.747], degraded [1.649, 2.515, 4.263, 6.789, 10.699].

| Gate | clean: mean dE00 to input | clean <= 1.5 | clean untouched | degraded: mean dE00 to clean (input 8.68) | recovery retained | degraded improved | night-tagged fail | night mean p50 dL | sunset-tagged fail |
|---|---|---|---|---|---|---|---|---|---|
| ungated model | 3.48 | 0.16 | 0.00 | 6.65 | 1.00 | 0.72 | 0.30 | +0.46 | 0.28 |
| deadzone_1 | 2.50 | 0.46 | 0.02 | 6.76 | 0.95 | 0.75 | 0.14 | +0.56 | 0.16 |
| deadzone_1.5 | 2.04 | 0.55 | 0.16 | 6.86 | 0.90 | 0.73 | 0.11 | +0.59 | 0.16 |
| deadzone_2 | 1.66 | 0.63 | 0.34 | 6.98 | 0.84 | 0.68 | 0.11 | +0.55 | 0.16 |
| deadzone_2.5 | 1.37 | 0.70 | 0.46 | 7.11 | 0.77 | 0.61 | 0.11 | +0.53 | 0.16 |
| deadzone_3 | 1.12 | 0.74 | 0.55 | 7.24 | 0.71 | 0.54 | 0.08 | +0.50 | 0.12 |
| deadzone_3.5 | 0.91 | 0.78 | 0.63 | 7.36 | 0.65 | 0.49 | 0.08 | +0.44 | 0.12 |
| deadzone_4 | 0.75 | 0.83 | 0.70 | 7.49 | 0.59 | 0.46 | 0.08 | +0.39 | 0.12 |
| deadzone_5 | 0.49 | 0.89 | 0.78 | 7.71 | 0.48 | 0.34 | 0.05 | +0.30 | 0.09 |
| scene_only | 2.43 | 0.43 | 0.02 | 7.04 | 0.81 | 0.74 | 0.00 | -0.37 | 0.03 |
| deadzone_1.5+scene | 1.50 | 0.67 | 0.20 | 7.24 | 0.71 | 0.72 | 0.00 | -0.05 | 0.03 |
| deadzone_2+scene | 1.25 | 0.73 | 0.38 | 7.34 | 0.66 | 0.67 | 0.00 | -0.01 | 0.03 |
| deadzone_2.5+scene | 1.04 | 0.79 | 0.50 | 7.45 | 0.61 | 0.60 | 0.00 | +0.01 | 0.03 |
| deadzone_3+scene | 0.86 | 0.82 | 0.58 | 7.55 | 0.56 | 0.53 | 0.00 | +0.05 | 0.03 |
| deadzone_3.5+scene | 0.71 | 0.85 | 0.66 | 7.65 | 0.51 | 0.48 | 0.00 | +0.07 | 0.03 |
| deadzone_4+scene | 0.60 | 0.88 | 0.72 | 7.74 | 0.46 | 0.43 | 0.00 | +0.08 | 0.03 |
| detector_0.4 | 2.28 | 0.55 | 0.53 | 6.72 | 0.97 | 0.61 | 0.08 | +0.31 | 0.28 |
| detector_0.5 | 1.59 | 0.73 | 0.73 | 6.84 | 0.91 | 0.53 | 0.08 | +0.46 | 0.19 |
| detector_0.6 | 0.98 | 0.84 | 0.84 | 7.02 | 0.82 | 0.44 | 0.08 | +0.46 | 0.12 |
| detector_0.7 | 0.57 | 0.92 | 0.92 | 7.32 | 0.67 | 0.32 | 0.08 | +0.46 | 0.06 |
| detector_0.5+scene | 1.19 | 0.79 | 0.73 | 7.22 | 0.72 | 0.55 | 0.00 | +0.08 | 0.03 |
| detector_0.6+scene | 0.78 | 0.87 | 0.84 | 7.40 | 0.63 | 0.46 | 0.00 | +0.08 | 0.03 |
| detector_0.7+scene | 0.49 | 0.93 | 0.92 | 7.64 | 0.51 | 0.33 | 0.00 | +0.08 | 0.03 |
| detector_0.5+deadzone_1+scene | 0.99 | 0.80 | 0.73 | 7.33 | 0.67 | 0.56 | 0.00 | +0.09 | 0.03 |
| detector_0.5+deadzone_1.5+scene | 0.90 | 0.82 | 0.73 | 7.40 | 0.63 | 0.55 | 0.00 | +0.11 | 0.03 |
| detector_0.5+deadzone_2+scene | 0.80 | 0.84 | 0.75 | 7.48 | 0.59 | 0.53 | 0.00 | +0.11 | 0.03 |
| detector_0.6+deadzone_1+scene | 0.65 | 0.89 | 0.84 | 7.49 | 0.59 | 0.46 | 0.00 | +0.09 | 0.03 |
| detector_0.6+deadzone_1.5+scene | 0.60 | 0.89 | 0.85 | 7.55 | 0.56 | 0.46 | 0.00 | +0.11 | 0.03 |
| detector_0.6+deadzone_2+scene | 0.54 | 0.90 | 0.86 | 7.62 | 0.52 | 0.43 | 0.00 | +0.11 | 0.03 |
