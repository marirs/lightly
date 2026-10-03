# Rendering parity goldens (rendering-v2 revision 1)

The iOS and Android tests share these files and must load them from here. `shared/contracts/make_rendering_goldens.py` generates them; do not edit them by hand. Regenerate them after any change to `experiments/depth/refocus.py` or to `reference_model.apply_grain`; `shared/contracts/tests/test_rendering_goldens.py` fails until you do.

Every array is a little-endian float32 file, row-major. `index.json` records each file's shape and SHA-256, the case parameters and the tolerances.

| Section of `index.json` | What a port checks |
|---|---|
| `backgroundFocus.constants` | The constants it uses equal these (the same block as `rendering-v2.json`) |
| `backgroundFocus.scalars.signedCoc` | Half-width, defocus range S, R_max and the signed CoC of 21 disparities, for four focal planes |
| `backgroundFocus.scalars.highlights` | §R1 highlight expansion and its inverse |
| `backgroundFocus.kernels` | Round, hex, heart and star at radius 2.5 and 6, the Soft Gaussian, and a Motion streak |
| `backgroundFocus.pullPush` | Pull-push on a large hole (only a 3 px border covered) and on partial coverage with an empty quadrant |
| `backgroundFocus.renders` | Whole renders of the synthetic scene (`scene-image`, `scene-disparity`, `scene-matte`, `scene-replacement`): every style and bokeh, focus on the subject, on the background and depth-only, and a replaced background. The disparity is already at the working size, so no guided filter runs |
| `grain` | `grain_noise` and `apply_grain` on a generated ramp (formula in the generator's `grain_input`), including the supersampled cases. Large cases store a 64×64 window given by `crop` |

Tolerances are in `index.json`: whole renders are compared perceptually (ΔE00 mean ≤ 1.0, p99 ≤ 4, as depth-evaluation.md §R9), everything else numerically.
