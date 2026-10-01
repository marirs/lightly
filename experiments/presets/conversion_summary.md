# Preset parameter coverage

Parsed: 11076 presets (+2 parse errors, listed in conversion_report.json). Validated against Lightroom: 0.

| Coverage | Uses approximation | Presets |
|---|---|---|
| complete | no | 136 |
| complete | yes | 634 |
| incomplete | - | 10306 |

'complete' = every non-default parameter is read by the renderer (modelled or approximated) or is not a look parameter. It is NOT a fidelity claim.
Incomplete only because of experimental Clarity/Texture: 3309

Not-implemented / experimental parameters (presets affected):

- `Clarity2012`: 8932
- `GrainSize`: 2771
- `GrainFrequency`: 2692
- `GrainAmount`: 2453
- `Texture`: 2095
- `CameraProfile`: 2084
- `PostCropVignetteMidpoint`: 1887
- `PostCropVignetteAmount`: 1797
- `PostCropVignetteFeather`: 1779
- `PostCropVignetteRoundness`: 1316
- `PostCropVignetteHighlightContrast`: 930
- `GrainSeed`: 834
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
- `PostCropVignetteStyle`: 100
- `LocalSaturation`: 84
- `LocalToningHue`: 79
- `LocalDehaze`: 72
- `LocalHighlights2012`: 49
- `LocalShadows2012`: 36

Approximated parameters (presets affected):

- `Highlights2012`: 10616
- `Shadows2012`: 10499
- `Blacks2012`: 10306
- `Whites2012`: 10244
- `Dehaze`: 3664
- `Temperature`: 2030
- `Tint`: 1941
