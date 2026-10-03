# Look pack parity fixtures (recipe → LUT)

The iOS and Android tests share these files and must load them from here. `shared/look-pack/make_golden.py` generates them from a built pack; do not edit them by hand. Regenerate them whenever `developModel.constantsSha256` in `shared/contracts/rendering-v2.json` changes.

| File | What it is |
|---|---|
| `manifest-parity.json` | The pack manifest format (formatVersion 3), restricted to the 40 parity presets. Categories keep their order. Stops are the full catalogue's stops, so they are not contiguous. |
| `golden.json` | Probe colours, tolerances, portable-random vectors, and for each case: `lutFile`, `lutSha256`, `probesDirect`, `probesViaLut33` and `lookVersion` |
| `luts/<presetId>.lut17.f16` | The expected 17³ global LUT: float16 little-endian, layout `[b][g][r][rgb]` (red fastest), grid `linspace(0, 1, 17)` |

How the cases were chosen: deterministically, with no hand-picked ids.
1. The first preset of every category.
2. Then, greedily, the preset that covers the most features still uncovered. The features are every operator, every coverage code, every completeness class, every process version (including 6.7), vignette lighten and darken, 2-point and spline curves on each channel, each colour-grading zone, grayscale, and Saturation −100.

## What a port must do (each case)

1. Read the preset's `recipe` from `manifest-parity.json`.
2. Bake the develop.global stage on a 17³ grid. Every node must be within `tolerances.lutNode` (1e-3) of the golden LUT.
3. Evaluate develop.global directly on each of the `probes`. Each result must be within `tolerances.probeDirect` (5e-4) of `probesDirect`.
4. Bake 33³, then look up each probe by trilinear interpolation. Each result must be within `tolerances.probeViaLut33` (1e-3) of `probesViaLut33`.
5. Recompute `lookVersion` from the recipe (rendering-v2.md §4.3). It must be equal.

Also check `portableRandom`: the `lowbias32` pairs must match exactly, and the `gaussianField` values must be within 1e-6.

The expected values come from `shared/look-pack/reference_model.py` in float64. `agreementWithLrModel` records how closely the calibrated source of truth (`experiments/presets/lr_model.py`) agrees on the same probes.
