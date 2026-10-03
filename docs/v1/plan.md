# Lightly 1.0: implementation plan, dependencies and conflicts

The approved UX is `docs/ui/app/` at revision **ff5c5ae**, now canonical under `docs/ui/` (0352972; content identical apart from photo paths). A read-only copy and SHA-256 hashes are in `~/.codex/artifacts/lightly/approved-design-ff5c5ae/`. Every screen and behaviour is tracked in `docs/v1/implementation-checklist.md`.

To render any approved screen at a reference device size, theme and text size for a side-by-side comparison:

```bash
NODE_PATH=<playwright-core node_modules> node docs/ui/tools/shot.js <screenId> <deviceId> <orientation> <theme> <text> out.png
```

## Architecture decisions (engineering, within the approved UX)

1. **Shared preset pack v2 = recipes, not LUTs.**
   - 2,591 presets × a 33³ float LUT would be about 1.5 GB, which is too large to ship.
   - The pack instead stores each preset's converted parameters, using Lightly's operators and a fixed operator order, plus provenance and validation status.
   - Both apps bake the global colour LUT on the device from the recipe, then apply the spatial operators.
   - A Lightroom reference LUT (HALD) can override the global stage for a preset only when its evidence matches the shipped recipe. This uses the existing evidence binding.
   - One generator in the repo reads `presets/` and writes `shared/look-pack/`. Both apps consume that same pack.
2. **One edit recipe** (shared JSON schema, versioned) covers every tool. Preview and export evaluate the same committed recipe. Undo and Redo store whole recipes.
3. **Operator order** (shared contract): Auto → Develop global → Develop spatial (clarity, texture, dehaze, sharpening, noise reduction) → Edit (geometry, adjust) → Remove → Background (replacement, focus/blur) → Portrait → Effects (light leaks, grain, vignette) → Border → Watermark. This order is checked against the prototype's behaviour before it is frozen in the contract.

## Preset feature coverage (measured over the 2,591 selected presets)

| Feature | Presets | Plan |
|---|---|---|
| Tone curve, basic tone, HSL, colour grading, calibration, white balance | almost all | Global stage (ported calibrated model) |
| Clarity | 2,055 | Spatial operator |
| Sharpening / noise reduction | 1,852 / 1,675 | Spatial operators |
| Dehaze | 898 | Spatial operator (global approximation recorded until local is implemented) |
| Point Color | 786 | Global stage (it is a colour-range operation) |
| Grain | 618 | Spatial operator |
| Texture | 548 | Spatial operator |
| Vignette | 451 | Spatial operator |
| Process version 2010 (PV 6.7) | 215 | Convert PV2010 tone keys, recorded as approximated |
| Local masks | 117 | **Cannot be converted.** Recorded per preset as unsupported. The rest of the preset renders |
| Creative profiles (`Look`) | 57 | Convert the embedded table if present; otherwise recorded as unsupported |

Every preset records its source hash, converted operators, approximations, unsupported features and validation status. Nothing is labelled validated without matching Lightroom evidence.

## Dependencies needed from the product owner

| # | Dependency | Blocks | Meanwhile |
|---|---|---|---|
| D1 | **Auto model**: rights-cleared training/evaluation photos (see docs/m3/auto-progress.md) | Real Auto | Approved "Automatic correction unavailable" state |
| D2 | **Release text**: Privacy Policy, Terms of Use, Support destination, version/build scheme | Release; no placeholders may ship | Screens and navigation built; text loaded from a content file left empty |
| D3 | **On-device vision on Android**: subject segmentation and face detection need a third-party SDK (e.g. ML Kit bundled models or MediaPipe), which means downloading and bundling it | Background and Portrait on Android | iOS uses built-in Vision (no download) |
| D4 | **Object removal (inpainting) model**: neither platform has a public on-device inpainting API | Edit › Remove on both | Remove shows the approved unavailable/failed state |
| D5 | **Depth for Focus depth**: only photos with embedded depth have it; a monocular depth model is otherwise needed | Focus depth on photos without depth | Depth from embedded depth data; otherwise subject-based focus, clearly limited |
| D6 | **Watermark fonts**: Allura, Cormorant Garamond, Inter, Caveat (all SIL OFL) must be downloaded and bundled | Watermark text | System font fallback in development builds only |
| D7 | **Licensed multi-person photograph** for multi-face testing | Multi-face verification | Implemented and unit-tested with synthetic face data |
| D8 | **Lightroom reference exports** for validation | Promoting presets to validated | All presets ship as approximate with recorded coverage |

## Product points, already decided by the approved prototype

- **Preset grain/vignette plus Effects:** the approved prototype composes them ("added on top, not replaced") and shows a notice. That is what will be implemented. Which presets carry grain or vignette now comes from their real settings, not a stand-in rule.
- **Metadata:** two independent switches (Keep photo metadata on, Include location off). The same policy applies to Save and Share.
