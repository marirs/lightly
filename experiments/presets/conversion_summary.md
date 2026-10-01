# Preset conversion classification

Files parsed: 11076 (+2 parse errors, listed in conversion_report.json)

| Status | Presets | Meaning |
|---|---|---|
| converted | 177 | every non-default parameter modelled (or spatial / not-a-look) |
| approximated | 1494 | modelled, but uses at least one approximated (local-in-Lightroom) parameter |
| partial | 9405 | at least one unsupported parameter; never marked converted |

Unsupported parameters (presets affected):

- `Clarity2012`: 8932
- `Texture`: 2095
- `ProcessVersion`: 408
- `CorrectionActive`: 358
- `CorrectionAmount`: 358
- `CorrectionMasks`: 358
- `CorrectionName`: 343
- `CorrectionSyncID`: 343
- `MaskGroupBasedCorrections`: 343
- `LocalExposure2012`: 210
- `Look`: 192
- `GradientBasedCorrections`: 189
- `CircularGradientBasedCorrections`: 180
- `Table_6938C31B6948CF8FBEB3F417D97F053B`: 120
- `LocalSaturation`: 84
- `LocalToningHue`: 79
- `LocalDehaze`: 72
- `LocalHighlights2012`: 49
- `LocalShadows2012`: 36
- `LocalTemperature`: 25
- `LocalSharpness`: 24
- `CurveRefineSaturation`: 24
- `LocalContrast2012`: 23
- `LocalClarity2012`: 22
- `LocalLuminanceNoise`: 18
- `LocalTint`: 17
- `Dabs`: 16
- `Flow`: 16
- `MaskActive`: 16
- `MaskName`: 16

Approximated parameters (presets affected):

- `Highlights2012`: 10616
- `Shadows2012`: 10499
- `Blacks2012`: 10306
- `Whites2012`: 10244
- `Dehaze`: 3664
- `Temperature`: 2030
- `Tint`: 1941
