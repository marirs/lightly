# iOS Auto: Core Image auto enhancement, inspected (2026-10-06)

Engine: `CIImage.autoAdjustmentFilters` (options: enhance on, red-eye off, crop off, level off), run on the ≤1024 px
analysis proxy. Applied: CIFaceBalance, CIVibrance, CIToneCurve (per-pixel, baked into the stage-1 Auto LUT).
Omitted: CIHighlightShadowAdjust (spatial; cannot be a LUT and would seam across a tiled Save copy). This is Core Image
auto enhancement: not the Apple Photos algorithm and not a trained model.

`auto_sheet.swift` (macOS Core Image; the same filters the app keeps) on the approved photos; `auto-sheet.jpg`
(before | after pairs). Mean luma, clipped share (any channel ≥ 254), mean chroma:

| Photo | Luma | Clipped % | Chroma | Applied |
|---|---|---|---|---|
| portrait_light_01 | 104→107 | 0.08→0.54 | 33→37 | face balance, vibrance 0.10, tone curve |
| portrait_medium_02 | 158→155 | 1.54→2.49 | 27→29 | face balance, vibrance 0.08, tone curve |
| portrait_deep_03 | 25→30 | 0.00→0.01 | 15→25 | face balance, vibrance 0.09, tone curve (lifts shadows) |
| backlit_02 | 97→97 | 7.32→7.41 | 28→34 | vibrance 0.16, tone curve |
| sunset_02 | 83→86 | 1.63→5.02 | 57→61 | vibrance 0.04, tone curve (lifts upper mids) |
| night_03 | 47→47 | 0.01→0.13 | 29→36 | vibrance 0.16, tone curve (deeper blacks) |
| landscape_01 (already good) | 126→115 | 19.88→19.90 | 24→29 | vibrance 0.10, tone curve (black point 0.08→0) |
| landscape_02 (already good) | 120→105 | 0.23→0.68 | 30→38 | vibrance 0.05, tone curve (black point 0.12→0) |

Findings for the owner (not tuned: changing Core Image's parameters would no longer be Core Image Auto):
- **Skin:** face balance warms skin; visible orange shift on portrait_light_01; strong chroma gain on portrait_deep_03.
- **Highlights:** clipping grows on the sunset (sun area) and the white jacket.
- **Already-good photos** are darkened, not brightened (raised black point).
- Device check pending: iOS's Core Image may choose slightly different parameters than macOS.
