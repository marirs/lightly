# Depth for Background › Focus & Blur — evaluation and rendering specification

Status: evaluation complete, recommendation below. Scope: refocus (tap to choose the focal plane),
depth of field, the Lens / Soft / Swirl / Motion styles, bokeh shapes, and Focus & Blur after
background replacement, on iOS and Android. This answers dependency **D5** in `docs/v1/plan.md`.

Product owner instructions this follows: use embedded depth when available; evaluate on-device depth
estimation for ordinary photos; a subject mask alone does not demonstrate depth-based refocusing;
test focus selection and the depth-of-field styles, including after background replacement; no
photo leaves the device (nothing here calls a cloud service — every model runs locally).

Everything is reproducible from `experiments/depth/` (layout at the end). Model weights, converted
models, caches and fixtures are git-ignored; sources, revisions and SHA-256 are in
`experiments/depth/MODEL_SOURCES.csv`.

## Summary

* **Embedded depth:** iOS reads the disparity/depth auxiliary image via ImageIO + `AVDepthData`
  (Portrait photos on all iPhones with Portrait mode; on iPhone 15 and later also ordinary photos with
  a person or pet). Android reads Dynamic Depth 1.0 / GDepth XMP containers (Pixel Portrait,
  `DEPTH_JPEG`); Samsung's proprietary format is not supported. Reference readers are written and
  verified on spec-conformant fixtures. When embedded depth is present it is used and the model is skipped.
* **Ordinary photos:** neither platform has a public single-image depth API. The best model usable
  for a commercial product is **Depth Anything V2 Small** (code and weights Apache-2.0, 24.8 M params).
  It beats Depth Anything V1 Small and MiDaS v3.1 / v2.1 on fine structure and edges here (sheet 00),
  and in the paper's DA-2K benchmark (95.3 % vs 88.5 %). Not usable: DA-V2 Base/Large (CC-BY-NC),
  Apple Depth Pro (research-only), Metric3D (no weights licence), Distill-Any-Depth (non-commercial
  teacher).
* **On device:** iOS uses Apple's own Neural-Engine-tuned Core ML package of the same weights,
  8-bit palettised (24.1 MB, ~31–34 ms on iPhone 12/15 Pro Max per Apple). Android uses our LiteRT
  conversion (26.4 MB, int8 weights; Qualcomm publishes 17–68 ms on Snapdragon 8-series NPUs). Both
  match PyTorch at r ≥ 0.9999. Two traps were found and avoided: Apple's `INT8` package returns
  garbage on the Neural Engine, and a straightforward coremltools conversion does not compile for the
  Neural Engine.
* **Refocus actually uses depth:** the reference renderer turns disparity into a thin-lens circle of
  confusion around the tapped focal plane, with a depth-of-field band and 17 signed layers. Layers
  behind the focus are normalised; focal and in-front layers are summed. The subject matte only
  separates the subject plane so outlines stay clean. Demonstrated on 7 photos × near/far focus × 7
  looks (3 photos have no subject at all), plus background replacement placed at a chosen depth and
  then blurred by the same depth of field. Halo leak at outlines: 0.04–0.18 vs 7.7–10.9 for a
  naive per-pixel blur.
* **Spec:** §6 is the rendering algorithm for the shared contract (constants, formulas, compositing
  order, parity tolerance). `experiments/depth/refocus.py` is its executable reference.
* **Decisions needed:** T1 training-data provenance (recommend accept with legal sign-off), T2 bundle
  the model (recommend bundle), T3 meaning of the "Focus depth" slider (recommend depth of field).
  No paid commitments are involved.

## 1. Embedded depth

### E1. iOS

| What | API | Notes |
|---|---|---|
| Disparity / depth map | `CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeDisparity)` then `…TypeDepth` → `AVDepthData(fromDictionaryRepresentation:)` | Convert with `converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)`; the renderer always consumes disparity (larger = nearer). Typical size is a few hundred px on the long side (Portrait captures are commonly 768×576 or smaller; the size is read from the file, never assumed). |
| Orientation | `depthData.applyingExifOrientation(_:)` with the primary image's EXIF orientation | Auxiliary images are stored in sensor orientation. |
| Quality flags | `depthDataQuality`, `depthDataAccuracy` (`.relative` / `.absolute`), `isDepthDataFiltered` | Relative accuracy is fine: the renderer normalises disparity by percentiles (§R2.1). |
| Portrait Effects Matte | `kCGImageAuxiliaryDataTypePortraitEffectsMatte` → `AVPortraitEffectsMatte` | A high-quality person matte (hair-level). When present, use it as the subject matte instead of running Vision; it is still a matte, not depth. |
| Semantic mattes | `kCGImageAuxiliaryDataTypeSemanticSegmentation{Hair,Skin,Teeth,Glasses,Sky}Matte` | Not needed for Focus & Blur; Sky matte could later force sky to "far". |

Which iPhones write it (Apple documentation and long-standing camera behaviour; not re-verified on
devices in this evaluation, because no device was used):
* **Portrait mode**: every iPhone with Portrait mode — dual-camera models from iPhone 7 Plus, the
  TrueDepth front camera from iPhone X, and single-camera models (iPhone XR, SE 2nd/3rd gen) for
  people only. Portrait captures also carry the Portrait Effects Matte.
* **Photo mode, iPhone 15 and later**: depth is captured automatically when the camera detects a
  person, dog or cat (or the user taps to focus on a subject), which is what lets Photos turn the
  picture into a Portrait later.
* LiDAR models (Pro, from iPhone 12 Pro) improve the depth in low light; the format is the same.
* Photos from other cameras, screenshots, downloads, edited exports and most shared images carry no
  depth → the monocular model is the normal path, not the exception.

Verified here: `experiments/depth/embedded/read_depth.swift` contains the exact read path above and a
fixture writer. A HEIC written with a `DisparityFloat16` auxiliary image round-trips through
`AVDepthData` (stored as `kCGImageAuxiliaryDataTypeDisparity`, accuracy relative, 518×392).
**Open item (needs a dev device or a user-supplied Portrait HEIC):** confirm that the photo picker path
the app uses hands over the original HEIC with its auxiliary images and an un-rendered primary image
(Photos applies the Portrait blur as an adjustment; an export of the *rendered* version may have the
blur baked in or the depth stripped). If it does not, embedded depth is simply absent and the
monocular path runs — nothing breaks.

### E2. Android

| Format | Where it appears | How to read |
|---|---|---|
| **Dynamic Depth 1.0** (`ImageFormat.DEPTH_JPEG`, Android 10+) | Camera2 devices that expose depth JPEG; Google Camera Portrait photos on Pixel | XMP `Device:Container/Container:Directory` lists `Container:Item`s (Mime, Length, Padding, DataURI). Item 0 is the primary JPEG (Length 0); the others are concatenated after the primary image's EOI (+ Padding) in directory order. `Camera:DepthMap` gives `Format` (RangeInverse / RangeLinear), `Near`, `Far`, `Units`, `DepthURI`, optional `ConfidenceURI`. Spec: <https://developer.android.com/static/training/camera2/Dynamic-depth-v1.0.pdf> |
| **GDepth** (legacy XMP) | Google Camera "Lens Blur" and early Pixel Portrait photos | `GDepth:Format/Near/Far/Mime`, `GDepth:Data` = base64 PNG/JPEG, usually in extended XMP (`http://ns.adobe.com/xmp/extension/`, GUID-addressed chunks). |
| **Ultra HDR** (`JPEG_R`, Android 14+) | Many recent phones | A gain map, **not depth**. It uses the same container directory, so the reader must skip `GainMap` items and only follow `DepthMap:DepthURI`. |
| Samsung Portrait / Live focus | Galaxy phones | Proprietary trailer (SEF), undocumented — **not supported**; those photos take the monocular path. |

Decoding (both formats), with `v` the stored value normalised to [0,1]:
`RangeLinear: d = near + v·(far − near)`; `RangeInverse: d = far·near / (far − v·(far − near))`;
disparity = 1/d.

Verified here: `experiments/depth/embedded/dynamic_depth.py` is the reference reader (JPEG segment
walk, progressive-safe primary-length scan, standard + extended XMP, both formats) with a fixture
writer; Dynamic Depth and GDepth fixtures round-trip with correlation 1.0000 to the source map, and
the primary JPEG still decodes normally. **Open item:** a real Pixel Portrait JPEG (dev device or
user-supplied) to confirm the reader against Google Camera's actual XMP layout; and confirm that the
Android Photo Picker returns original bytes (it can redact location, which must not drop the
appended items).

### E3. How Lightly uses embedded depth

1. On open, look for embedded depth (iOS: disparity, then depth; Android: Dynamic Depth, then
   GDepth). If found, it is the depth source; the model is not run.
2. Embedded depth goes through exactly the same pipeline as model depth (§R2): orientation applied,
   converted to disparity, percentile-normalised, edge-aware upsampled, then split into the
   subject/background planes using the subject matte. On iOS the Portrait Effects Matte, when present,
   is the subject matte.
3. Edits that change geometry (crop, rotate, perspective) transform the depth map with the image, as
   any other per-pixel layer.
4. The depth source is recorded in the edit state (`embedded` / `estimated`) so a re-render on another
   platform uses the same source, and Export metadata policy is unaffected (depth is an input, it is
   never written to exported files).

## 2. Monocular depth candidates

System APIs: **neither platform has a public single-image depth API.** Apple Vision's request list
(iOS 26 / macOS 26 SDK documentation index) has segmentation, saliency and optical flow requests but
no depth request; RealityKit's `ImagePresentationComponent.Spatial3DImage` (visionOS 26) builds a
spatial scene from a 2D photo but exposes no depth map and is visionOS-only. On Android, ARCore's
Depth API needs a live camera session with motion, ML Kit and MediaPipe have no depth task. So a
bundled model is required for ordinary photos.

### Licences (code, weights, training data)

| Candidate | Params | Code licence | Weights licence | Training data | Commercial verdict |
|---|---|---|---|---|---|
| **Depth Anything V2 Small** ([HF](https://huggingface.co/depth-anything/Depth-Anything-V2-Small-hf), [code](https://github.com/DepthAnything/Depth-Anything-V2)) | 24.8 M | Apache-2.0 | **Apache-2.0** (model card) | Student trained only on pseudo-labels of 62 M real images (BDD100K, Google Landmarks, ImageNet-21K, LSUN, Objects365, Open Images V7, Places365, SA-1B) produced by a teacher trained on 595 K synthetic images (BlendedMVS, Hypersim, IRS, TartanAir, VKITTI 2) — paper Table 7 | **Usable** — see the training-data trade-off (T1) |
| Depth Anything V2 Base / Large ([HF](https://huggingface.co/depth-anything/Depth-Anything-V2-Large)) | 97 M / 335 M | Apache-2.0 | **CC-BY-NC-4.0** | as above | **Not usable** (non-commercial); not downloaded |
| Depth Anything V1 Small ([HF](https://huggingface.co/LiheYoung/depth-anything-small-hf), [code](https://github.com/LiheYoung/Depth-Anything)) | 24.8 M | Apache-2.0 | Apache-2.0 | 1.5 M labelled + 62 M unlabelled images | Usable; superseded by V2 |
| MiDaS v3.1 DPT SwinV2-Tiny-256 ([HF](https://huggingface.co/Intel/dpt-swinv2-tiny-256), [code](https://github.com/isl-org/MiDaS)) | 41 M | MIT | MIT | MiDaS mix of 12 datasets incl. frames from 3D movies | Usable; weaker and larger than DA-V2 S |
| MiDaS v2.1 small 256 ([release](https://github.com/isl-org/MiDaS/releases/tag/v2_1)) | 21 M | MIT | MIT (repository) | MiDaS mix incl. 3D movies | Usable; clearly weakest |
| DPT-Hybrid (MiDaS v3.0) ([HF](https://huggingface.co/Intel/dpt-hybrid-midas)) | 123 M | MIT | Apache-2.0 (model card) | MiDaS mix | Licence fine; **too large** (~490 MB fp32); not downloaded |
| Apple Depth Pro ([HF](https://huggingface.co/apple/DepthPro), [code](https://github.com/apple/ml-depth-pro)) | ~950 M | Apple sample-code licence | **Apple Machine Learning Research Model licence** — "exclusively for Research Purposes", which "does not include any commercial exploitation, product development or use in any commercial product" | — | **Not usable**; also far too large; not downloaded |
| Metric3D v2 ViT-S ([HF](https://huggingface.co/JUGGHM/Metric3D), [code](https://github.com/YvanYin/Metric3D)) | ~37 M | BSD-2-Clause | **none stated**; README directs commercial enquiries to the authors | 16 M images, many datasets | **Unclear → treat as not usable**; would need written permission; not downloaded |
| Distill-Any-Depth Small ([HF](https://huggingface.co/xingyang1/Distill-Any-Depth-Small-hf)) | 24.8 M | MIT | MIT (model card) | Distilled from multiple teachers including Depth Anything V2 Large (CC-BY-NC) | **Provenance risk → not used**; not downloaded |

Apple redistributes the Depth Anything V2 Small weights as Core ML packages under Apache-2.0
([apple/coreml-depth-anything-v2-small](https://huggingface.co/apple/coreml-depth-anything-v2-small)),
and Qualcomm publishes LiteRT/ONNX/QNN exports of the same model on AI Hub. That is not legal advice,
but it is strong evidence that major vendors treat these weights as commercially redistributable.

Published accuracy (Depth Anything V2 paper, arXiv:2406.09414): on the DA-2K relative-depth benchmark
V2 ViT-S scores 95.3 % against 88.5 % for V1 and 85.8–88.1 % for diffusion-based models; on the
classic zero-shot benchmarks V2-S and V1-S are on par (e.g. KITTI AbsRel 0.078 vs 0.080, NYU-D
0.053 vs 0.053). DA-2K measures exactly what refocus needs (which of two points is nearer, on
in-the-wild photos with fine structures).

### Measured here

All commercially usable candidates were downloaded (pinned revisions, SHA-256 in
`MODEL_SOURCES.csv`) and run on the 9 demonstration photos (`estimate_depth.py`,
`compare_depth.py`; sheet `00_depth_candidates.jpg`). Desktop = Apple M4, 4 threads, PyTorch 2.5.1 /
ONNX Runtime 1.30 / Core ML on macOS 26.5. These are relative timings between candidates, not
phone timings (those are in §3).

| Candidate | Input | Desktop median latency | Subject in front (4 subject photos, margin) | Edge alignment ¹ | Visual (sheet 00) |
|---|---|---|---|---|---|
| **DA-V2 Small** (PyTorch) | 518×392 / 392×518 | 226 ms (CPU) | 4/4 (0.46–0.77) | 37.1 | Sharpest structure: individual branches (backlit_02, landscape_02), signposts (wellexposed_02), hair outline; correct ordering everywhere |
| DA-V2 Small (Apple Core ML F16) | 518×392 fixed | **27 ms** (Neural Engine) | 4/4 (0.47–0.77) | 37.5 | Same model; portrait photos have to be rotated into its landscape input, which costs accuracy (see §3) |
| DA-V1 Small | 518×392 / 392×518 | 221 ms (CPU) | 4/4 (0.51–0.87) | 38.0 | Plausible but blobby: foliage merges into one mass, thin structures lost |
| MiDaS v3.1 SwinV2-T | 256×256 | 176 ms (CPU) | 4/4 (0.42–0.89) | 28.3 | Soft edges, background haze; 1.65× the weights of DA-V2 S |
| MiDaS v2.1 small | 256×256 | 68 ms (ORT CPU) | 4/4 (0.36–0.80) | 8.3 | Very soft, edges smeared by ~10 px at working resolution — would need the subject plane to hide every edge |

¹ mean |∇disparity| on the subject outline ÷ elsewhere; higher = depth edges coincide with the
outline. All candidates get the ordering right on these photos (the subject-in-front check is a
sanity gate, not a ranking); the difference is edge quality and fine structure, which is exactly
what decides whether a refocused photo has halos or fringes. DA-V2 Small is the best usable
candidate, consistent with the published DA-2K result above.

## 3. Conversion and on-device cost of the recommended model

Model: Depth Anything V2 Small, 24.79 M parameters, ~33 G MACs at 518×392 (LiteRT converter count).
Scripts: `convert.py` (Core ML, ONNX), `convert_tflite.py` (LiteRT, separate venv with
`litert_torch 0.9.4` / torch 2.13), `orientation_check.py`. Results: `results/conversion.json`,
`results/conversion_tflite.json`, `results/orientation_check.json`.

**Measurement caveat.** Other agents were running heavy jobs on this Mac during the conversion runs
(load average 15–500, recorded in the JSON files). Parity numbers are exact; desktop latencies are
indicative only and inflated, sometimes several-fold. Phone latency comes from the vendors' published
device benchmarks below. Nothing was installed on a phone. Simulator and emulator timings would
measure the Mac's CPU through a translation layer, with no Neural Engine, NPU or real mobile GPU, so
they would say nothing about phones and were not taken.

#### Sizes and parity (vs PyTorch fp32 on the same 8-bit input)

| Artefact | Size | Parity (corr / mean abs. diff. of normalised disparity) | Notes |
|---|---|---|---|
| Apple `DepthAnythingV2SmallF16` (518×392) | 47.5 MB | 0.99999 / 0.0012 | Apache-2.0, Apple-tuned for the Neural Engine |
| **Apple `DepthAnythingV2SmallF16P8`** (518×392, 8-bit palettised) | **24.1 MB** | 0.99997 / 0.0030 | correct on ANE, GPU and CPU |
| Apple `DepthAnythingV2SmallF16INT8` (518×392) | 24.2 MB | **−0.011 / 0.41 on the Neural Engine** (0.99996 on GPU) | **Broken on the ANE** (macOS 26.5, M4) — do not use |
| Ours, Core ML fp16 518×392 / 518×518 | 50.7 / 51.8 MB | 1.00000 / 0.0005 | **does not fully compile for the ANE** (`ANECCompile() FAILED`, Core ML silently falls back to GPU/CPU) |
| Ours, Core ML linear-int8 weights 518×392 | 27.1 MB | 0.99998 / 0.0019 | **aborts the process on the GPU** (`MPSGraph … MLIR pass manager failed`) |
| Ours, Core ML 8-bit palettised 518×518 | 28.2 MB | 0.99998 / 0.0020 | works on GPU/CPU; ANE compile fails as above |
| LiteRT fp32 518×392 / 518×518 | 94.8 MB | 1.00000 | `litert_torch` conversion, one shot |
| **LiteRT int8 weights, fp32 activations** 518×392 / 518×518 | **26.4 MB** | 0.99996 | `ai_edge_quantizer` dynamic_wi8_afp32 |
| ONNX fp32 / int8-dynamic 518×392 | 94.6 / 26.1 MB | 1.00000 / 0.9997 | ONNX Runtime Mobile fallback; fp16 pass of onnxconverter-common fails on this graph |

#### Speed and memory

| Where | Configuration | Latency | Peak memory | Source |
|---|---|---|---|---|
| iPhone 12 Pro Max (iOS 18) | Apple F16, Neural Engine, 518×392 | 31.1 ms | — | Apple model card |
| iPhone 15 Pro Max (iOS 17.4) | Apple F16, Neural Engine, 518×392 | 33.9 ms | — | Apple model card |
| Snapdragon 8 Elite (Galaxy) | TFLite float, NPU, 518×518 | 21.5 ms | 0–364 MB | Qualcomm AI Hub (`qualcomm/Depth-Anything-V2`, v0.63.0) |
| Snapdragon 8 Gen 3 | TFLite float, NPU, 518×518 | 30.9 ms | 1–469 MB | Qualcomm AI Hub |
| Snapdragon 8 Gen 1 | TFLite float, NPU, 518×518 | 68.1 ms | 0–467 MB | Qualcomm AI Hub |
| Snapdragon 7 Gen 4 | ONNX w8a16, NPU, 518×518 | 33.7 ms | 3–463 MB | Qualcomm AI Hub |
| Mac M4 (loaded) | Apple F16P8, `.all` (Neural Engine) | 45–50 ms (first load 13 s, compile) | ~400 MB process RSS | measured here |
| Mac M4 (loaded) | Apple F16, `.cpuAndNeuralEngine` | 25 ms | ~360 MB process RSS | measured here |
| Mac M4 (loaded) | ours 518×518 P8, `.cpuAndGPU` | 102–104 ms | ~440–490 MB process RSS | measured here |
| Mac M4 (loaded) | LiteRT 518×392 fp32 / wi8, XNNPACK 4 threads | 746 / 811 ms | — | measured here |
| Mac M4 (loaded) | ONNX Runtime fp32 / int8, 4 threads | 422 ms (idle-ish run) – 1.6 s (loaded) | +294 / +235 MB RSS | measured here |

Estimates for the phones Lightly targets, which still need confirmation on a dev device:
* **iOS** (A13 and later, iOS 17): ~30–60 ms on the Neural Engine with Apple's package. The first
  load compiles for the ANE and takes seconds; Core ML caches the result per device and OS. So load the
  model off the main thread when the editor opens, not on the first tap. Peak memory is about
  100–150 MB above the app's baseline (weights, activations, and the 518×392 input and output).
* **Android with a capable NPU/GPU** (Snapdragon 8-series, Tensor, recent Dimensity): ~20–70 ms on the
  NPU, or roughly 100–400 ms on the LiteRT GPU delegate.
* **Android CPU-only fallback** (XNNPACK, 33 G MACs): roughly 0.7–2 s on a mid-range phone. That is
  acceptable once per photo behind the existing cancellable "Finding the subject…" state.
* **Renderer** (§6, GPU): at a 1080 px preview with Blur 100, about 10 M layer-pixels × 64 taps,
  i.e. ~0.7 G texture fetches per full re-render. Estimated 15–40 ms on an A15/Adreno 7xx-class GPU,
  and half that with the `K = 4` preview. Changing the tap or Blur only re-runs the renderer;
  depth and matte are cached.

#### Orientation (fixed-shape models)

The fastest iOS package has a fixed **landscape** input. Measured against the model run at the
photo's own aspect ratio (`results/orientation_check.json`, 6 portrait photos):

| Portrait photo enters the model by… | Disparity correlation with native aspect (min / median) |
|---|---|
| rotating 90° into the landscape model (and back) | 0.921 / 0.96 — gravity prior breaks; visibly different landscapes |
| **stretching** (resize without crop) to 518×392 | 0.965 / 0.993 |
| stretching to a square 518×518 | 0.982 / 0.997 (all 9 photos ≥ 0.982) |

**Decision for 1.0 (engineering, no product trade-off):** every photo is stretched to 518×392 on
both platforms. iOS uses Apple's `DepthAnythingV2SmallF16P8`; Android uses our LiteRT 518×392
int8-weights conversion. The input geometry is identical on both platforms, which matters for parity.
Follow-up improvement: make our own conversion ANE-clean. Apple's package shows that the same
weights compile for the ANE, so the failing op in our export needs finding. With that done, iOS can
move to the square or native-portrait input and recover the last bit of portrait accuracy.

## 4. Demonstration

Sheets (JPEG) in `~/.codex/artifacts/lightly/v1/depth/`:

| Sheet | What it shows |
|---|---|
| `00_depth_candidates.jpg` | All 5 usable candidates on 9 photos, with the Vision matte |
| `01_portrait_deep_02.jpg` … `07_landscape_01.jpg` | **7 photos × focus NEAR and FAR × 7 looks** (Lens round, hex, heart, star; Soft; Swirl; Motion), plus the depth, the matte and the signed CoC maps for both focus points. The ring marks the tap. Photos 05–07 (night street, alley, meadow) **have no subject at all**, so the refocus there comes from depth alone. In 01–04, focus FAR makes the person dissolve into a blur in front of a sharp background, with no rim. |
| `08_replacement_then_blur.jpg` | Two subjects on replaced backgrounds (mountain lake, tree-lined street): replacement with no blur; focus on the subject with Lens and Swirl; focus on the background, where the subject blurs in front of the sharp new background; the replacement placed at its **own** estimated depth, so the street keeps a near-to-far blur gradient; and the composited depth |
| `09_depth_vs_mask_and_halo_ablation.jpg` | Row 1: subject-mask-only blur next to depth (backlit_02). With the mask, the ground she stands on blurs as much as the far field; with depth, it stays sharp. Rows 2–3: outline crops at Blur 90 for a naive per-pixel blend, layered with no subject plane, and the spec. **Halo leak** (mean abs. sRGB difference ×255 in a band 0.4–3 % of the long side outside the subject, against the background blurred on its own): naive 10.89 / 7.71, layered-depth-only 3.14 / 4.26, **spec 0.04 / 0.18** (`results/halo_leak.json`) |
| `10_dof_controls.jpg` | Focus depth 0/25/50/100 and Blur 20/45/70/100 on the alley, with the band half-width and R_max printed |
| `11_bokeh_highlights.jpg` | Round, hex, heart and star bokeh on the night street's point lights, with and without highlight expansion |

What the sheets show (by eye, at full resolution):
* Depth-based focus selection works in both directions. Tapping near keeps the near plane sharp and
  blurs progressively with distance. Tapping far sharpens the background and blurs the near road or
  the person in front.
* No halos or dark rims at subject outlines (measured above). Hair edges stay crisp when the subject
  is in focus.
* Swirl and Motion read as intended. Soft is gentler than Lens and glows in highlights.
* Limits seen: (a) where the Vision matte itself includes background (between curls in
  portrait_medium_02), that background colour travels with the subject — Refine edges is the tool for
  it; (b) monocular depth is relative, so a portrait's whole background sits near disparity 0 and
  blurs almost uniformly, which is physically right but means depth adds most in scenes with
  receding geometry (sheets 03, 05–07, 10); (c) the 1.0 limitation in §R6.3.

## 5. Recommended 1.0 approach

1. **Depth source, in order:** embedded depth (iOS disparity/depth auxiliary image; Android Dynamic
   Depth, then GDepth) → otherwise **Depth Anything V2 Small** run on-device, the photo stretched
   (no crop, no rotation) to 518×392 whatever its orientation (§3 "Orientation"). Never a cloud
   service. Never "mask-only" pretending to be depth: if depth fails, show the approved failure state.
2. **Model packaging:**
   * iOS: Apple's `DepthAnythingV2SmallF16P8.mlpackage` (Apache-2.0, 24.1 MB, from
     `apple/coreml-depth-anything-v2-small@cfef6f6`), compute units `.all`, compiled once at editor
     open on a background queue. **Do not use the `INT8` variant** (wrong output on the Neural Engine)
     and do not use our own linear-int8 conversion (aborts on the GPU). Keep the Apache-2.0 NOTICE
     in the app's acknowledgements.
   * Android: our LiteRT conversion `da2_small_518x392_wi8.tflite` (26.4 MB, int8 weights / fp32
     activations). Try in order: NPU (vendor delegate via LiteRT `CompiledModel` accelerator
     selection), GPU delegate, XNNPACK CPU. ONNX Runtime Mobile with the int8 ONNX file (26.1 MB)
     is the fallback if a delegate rejects the graph. Both exports are produced and parity-checked.
   * Bundled with the app: no download-on-demand, no account, no paid service. Adds ~24 MB (iOS) and
     ~26 MB (Android) before store compression.
3. **Subject matte:** iOS Vision foreground instance mask (or Portrait Effects Matte when embedded);
   Android ML Kit Subject Segmentation (dependency D3). The matte splits the scene into planes and keeps
   edges clean; depth decides how much everything is blurred.
4. **Renderer:** the layered, disparity-linear CoC renderer in §6, GPU on both platforms, reduced
   resolution per layer for preview, full `K = 8` for export.
5. **Replacement:** replacement goes into the background plane at the original background's depth by
   default; for photo backgrounds, estimate their depth once with the same model and place them with
   their own depth (§R2.4) — this is what makes "Focus & Blur still works on the new background" true
   in depth, not just as a uniform blur.
6. **Run time budget:** depth inference once per photo (+ once per replacement photo), cached with the
   edit; it runs while "Finding the subject…" is shown, cancellable, alongside the matte request.

## 6. Rendering specification (for the shared rendering contract)

This is what both platforms implement. `experiments/depth/refocus.py` is its executable reference
(section markers §R1–§R9 appear in its comments). Constants marked **[contract]** are part of the
shared rendering contract and must match exactly; everything else is an implementation choice
within the parity tolerance (§R9).

**Position in the operator order** (plan.md): Background (replacement, then focus/blur) runs after
Edit/Remove and before Portrait/Effects. Depth and the subject matte are computed on the image as it
enters the Background operator (i.e. after geometry), and cached per source + geometry.

#### R0. Parameters (edit state)

| Field | Range | Default | Meaning |
|---|---|---|---|
| `target` | (x, y) ∈ [0,1]², origin top-left | subject centre (else image centre) | tap point; selects the focal plane |
| `blur` | 0–100 | 0 (prototype screens use 55) | maximum circle-of-confusion radius |
| `focusDepth` | 0–100 | 40 | depth of field = width of the sharp band (see T3) |
| `style` | lens · soft · swirl · motion | lens | kernel family |
| `bokeh` | round · hex · heart · star | round | Lens only |
| `styleAmount` | 0–100 | 50 | Soft: Glow; Swirl: Swirl; Motion: Direction = `styleAmount·3.6 − 180` degrees |
| `depthSource` | embedded · estimated | — | recorded so every platform renders from the same depth |
| replacement | image/colour/gradient + scale + position | none | §R2.4 |

#### R1. Colour

1. Decode to linear-light RGB (sRGB EOTF). All blurring and compositing is in linear light
   (blurring gamma-encoded values darkens highlights and is the main reason synthetic bokeh looks fake).
2. Highlight expansion (Lens, Swirl, Motion only) **[contract]**: let `m = max(r,g,b)`, `t = 0.70`,
   `k = 0.85`. For `m > t`: `u = (m − t)/(1 − t)`, `m' = t + (1 − t)·u/(1 − k·u)`; scale the pixel by
   `m'/m`. Identity below `t`, hue-preserving, maps 1.0 to 6.7. After compositing apply the exact
   inverse (`v = (m' − t)/(1 − t)`, `m = t + (1 − t)·v/(1 + k·v)`), so unblurred pixels round-trip
   unchanged and only defocused light gets the bright, defined bokeh discs (sheet 11).
3. Encode back to the working colour space at the end of the operator.

#### R2. Scene model: two planes with disparity

**R2.1 Disparity.** Source is embedded depth (converted to disparity) or the model output
(already relative disparity). Model input contract **[contract]**: the image entering the Background
operator, 8-bit sRGB, resized with a bicubic or area filter to exactly 518 × 392 (w × h) regardless
of orientation (stretch, no crop, no rotation), RGB / 255, then ImageNet mean (0.485, 0.456, 0.406)
and std (0.229, 0.224, 0.225). Apple's package does the normalisation inside the model; the LiteRT
model expects normalised NCHW float32. The output (392 × 518 relative disparity) is resized back to
the photo's aspect ratio as part of the upsampling below. Normalise **[contract]**: `D = clamp((raw − p1)/(p99 − p1), 0, 1)`
with p1/p99 the 1st/99th percentiles of the map. Upsample to the working resolution bilinearly, then
apply a guided filter (He et al.) with the grey image as guide, radius `0.006 × longSide` px,
ε = 1e-3, clamp to [0,1]. Larger D = nearer.

**R2.2 Background plane** (opaque, α = 1 everywhere):
* colour `B`: the photo, with pixels inside `dilate(M > 0.02, 0.004·longSide)` replaced by a
  normalised pull-push fill from the remaining pixels (§R6.3 fill);
* disparity `D_B`: `D`, with pixels inside `dilate(M > 0.02, 0.015·longSide)` replaced by a pull-push
  fill. The wider band is deliberate: a model's depth bleeds a few model pixels across the outline,
  and that bleed is what produces halos if it is kept.

**R2.3 Subject plane** (only if a subject matte `M` exists; Vision `VNGenerateForegroundInstanceMaskRequest`
on iOS, the platform's subject segmentation on Android, or the iOS Portrait Effects Matte):
* alpha = `M` (soft);
* disparity `D_S`: sample `D` only in `erode(M > 0.5, 0.01·longSide)`, pull-push fill outward, then
  compress toward the subject's median **[contract]**: `D_S = med + 0.5·(D_S − med)`. This keeps a
  face and its ears/hair in one band while still letting a long subject (arm towards camera) fall off;
* colour `F` (de-contaminated, needed so the old background does not show as a fringe, especially
  after replacement): where `M ≥ 0.7`, `F = (I − (1 − M)·B)/M`; where `M ≤ 0.3`, `F` = pull-push fill
  from `M > 0.95`; linear blend in between; clamp ≥ 0.

**R2.4 Background replacement.** `B` becomes the replacement (aspect-fill, then user scale/position;
colours and gradients are images). Its disparity — "placed at a chosen depth behind the subject":
* nearest allowed disparity `d_max = max(0, med_S − 0.10)` **[contract]** (always behind the subject);
* default (**plane**): `D_B = min(median of the original D_B, d_max)` — the replacement sits where the
  old background was, so swapping backgrounds keeps the blur the user already chose;
* **own depth** (recommended when the replacement is a photo): run the same depth model on the
  replacement once, normalise (§R2.1), `D_B = D_rep · d_max`. A street or landscape then keeps its
  own near-to-far blur gradient behind the subject (sheet 08, columns 5–6).
Focus & Blur then runs unchanged; the subject plane is already separated, so no fill is needed
behind it.

Without a subject matte there is only the background plane with `D_B = D` (depth-only refocus;
sheets 05–07 have no subject at all).

#### R3. Focus selection

`d_f` = median of the disparity of the **topmost plane at the tap** (subject if `M(tap) ≥ 0.5`, else
background) over a square window of half-size `0.01 × longSide` around the tap **[contract]**.
Default target: subject matte centroid when a subject exists, else the image centre.

#### R4. Circle of confusion and layers

For a thin lens the blur radius is proportional to `|1/z − 1/z_f|`, i.e. linear in disparity, so:
* `R_max = blur/100 × 0.035 × longSide` px **[contract]** (relative to the long side, so preview and
  export match at any resolution);
* `h = 0.30 × (focusDepth/100)^1.5` (half-width of the sharp band, disparity units) **[contract]**;
* signed CoC per plane pixel: `c = sign(D − d_f) · clamp((|D − d_f| − h)/(1 − h), 0, 1) · R_max`
  (positive = in front of the focal band, negative = behind) **[contract]**;
* quantise into `2K + 1` layers, `K = 8` **[contract]**: layer `j ∈ [−K, K]` has radius `|j|·R_max/K`.
  Membership is a tent: `w_j = max(0, 1 − |c·K/R_max − j|) · α_plane` (each pixel belongs to at most
  two adjacent layers → no visible steps).

#### R5. Kernels (all normalised to sum 1, anti-aliased, circumscribed radius = layer radius r)

1. **Lens**: aperture shape scaled to radius r — round (disc), hex (regular hexagon, vertices at
   0°, 60°, …), heart (implicit `(x²+y²−1)³ − x²y³ ≤ 0` with `x = 1.25u`, `y = 1.25v + 0.15`, y up),
   star (5 points, point up, inner radius 0.45). Highlight expansion on.
2. **Soft**: Gaussian, σ = r/2 (truncated at 1.5r). No highlight expansion. Glow (`styleAmount`):
   after compositing, `G = GaussianBlur(result · clamp((Y − 0.35)/0.65, 0, 1), σ = 0.6·R_max)`,
   weighted by the defocus map `|c|/R_max` (blurred with σ = 0.25·R_max) and `0.9·amount`, added with
   a screen blend. The sharp subject therefore gets no glow.
3. **Swirl**: disc of radius `r·(1 − 0.5·s)` followed by a rotational blur about the image centre
   with half-angle `θ = 6·r·s / diagonal` radians (`s = styleAmount/100`). The angular extent is
   constant, so streaks are tangential and lengthen linearly toward the frame edge (Helios-44 style
   swirly bokeh). Highlight expansion on.
4. **Motion**: 1 px wide anti-aliased line of total length 3r at the Direction angle. Highlight
   expansion on.

#### R6. Compositing (the part that prevents halos)

For each plane (background first, then subject) and each layer `j`: premultiplied layer
`L_j = (colour·w_j, w_j)`, blurred with the style kernel of radius `|j|·R_max/K` (radius < 0.5 px =
no blur). Then:
1. **Behind the focal band** (`j < 0`), ordered `j = −K … −1`, background before subject within a
   layer: `acc = L_j + (1 − α(L_j))·acc` ("over").
2. **Normalise** what lies behind: `Behind = pull_push(acc)` — divide by the accumulated alpha, and
   where it is ~0 take the colour from coarser pyramid levels (Kraus & Strengert 2007). This fills the
   region hidden by nearer content with colour **from the same depth**, instead of mixing the nearer
   content into it — which is exactly the halo that a single-pass per-pixel blur produces (sheet 09).
3. **Focal and in-front layers** (`j = 0 … K`) are **summed per plane**:
   `S_p = Σ_{j≥0} L_j` (premultiplied colour and alpha); where `α(S_p) > 1`, divide colour and alpha by
   `α(S_p)`. Then layer the planes over what lies behind, background first, subject last:
   `out = S_bg + (1 − α(S_bg))·Behind`, `out = S_subj + (1 − α(S_subj))·out`.
   Why a sum and not "over": the tent (§R4) splits one surface across two adjacent layers; "over"
   would let `(1 − a)(1 − b)` (25 % for an even split) of the content behind leak through that
   surface, which showed up as ghost contours inside blurred foliage in the first version of the
   reference (backlit_02). The sum keeps a split surface opaque, while a defocused foreground still
   spreads and turns semi-transparent at its edges, revealing what is behind it (focus FAR rows in
   sheets 01–04: the subject dissolves over a sharp background without a dark rim).
   *Known 1.0 limitation:* background content that is nearer than the subject (e.g. a branch in front
   of a person that the matte does not include) blurs *under* the subject's outline instead of over
   it. It is rare and mild (the subject is usually the nearest thing); a per-layer interleave of the
   two planes would fix it at ~2× the compositing cost.
4. Inverse highlight expansion (§R1.2), Soft glow (§R5.2), encode.

Pull-push fill **[contract algorithm]**: pull — repeatedly 2× area-downsample premultiplied colour and
alpha, setting `α' = min(4α, 1)` and scaling colour by `α'/α`, until the short side ≤ 4 px; push —
from coarsest to finest, `C_l = C_l + (1 − clamp(α_l))·upsample_bilinear(C_{l+1})`.

#### R7. Implementation latitude (GPU)

* Each layer may be blurred at a reduced resolution: render at scale `1/2^n` with `n` the largest
  integer such that `r/2^n ≥ 6 px`, then bilinear upsample. Layers with no pixels are skipped.
* Kernels may be evaluated by gather with a fixed sample set inside the shape (≥ 64 samples for
  r ≥ 6 px at the reduced resolution, stratified, same pattern every frame — no temporal noise), or by
  FFT on CPU. Hexagon may use three skewed 1-D passes.
* Interactive preview may use `K = 4` and the reduced-resolution path; export uses `K = 8`.
* iOS: Metal compute (or Core Image kernels); Android: Vulkan/GLES compute or AGSL `RuntimeShader`
  with the CPU path as fallback.

#### R8. Edge cases

* `blur = 0` → operator is the identity (after replacement compositing if any).
* No subject → background plane only; "Change background" disabled as already designed.
* Depth unavailable (model failed / cancelled) → the approved "couldn't separate" state; never fake
  depth with a mask-only blur.
* Tiny or very thin subjects: if `erode` leaves < 50 px, use `M > 0.5` unchanged.
* Refine edges (brush) edits `M`; both planes are rebuilt from the edited matte.

#### R9. Parity

Golden test images: the reference renderer's output for fixed inputs (photo, disparity, matte,
params). Renderer goldens take the disparity map as an *input*, so they do not depend on the depth
model. The model is checked separately: each platform's output on the golden photos must correlate
≥ 0.999 with the PyTorch reference at 518×392 (measured: Apple P8 0.99997, LiteRT int8-weights
0.99996). Platforms must match within ΔE00 mean ≤ 1.0 / p99 ≤ 4 at the working resolution; the
reduced-resolution GPU path is expected to differ mostly inside large bokeh discs, which is why the
tolerance is perceptual rather than bit-exact. The disparity normalisation, focus selection, CoC,
layer assignment and the contract constants are exact.

## 7. Trade-offs that need a decision

Only three items need a product-owner decision. Everything else above is decided and justified.

**T1 — Training-data provenance of the depth model (licence risk).**
Evidence: Depth Anything V2 Small's code and weights are Apache-2.0 (model card, repository), and
Apple and Qualcomm both redistribute these weights for commercial platforms. But the model was
trained on pseudo-labels of 62 M images, and some of those datasets carry research-only or
non-commercial terms (e.g. SA-1B, ImageNet-21K). No usable alternative is cleaner: the MiDaS models
(MIT) were trained on a mix that includes frames from 3D movies, are clearly worse (sheet 00), and
everything better is non-commercial (DA-V2 Base/Large, Depth Pro) or unlicensed (Metric3D).
**Recommendation:** accept DA-V2 Small under its Apache-2.0 weights licence, record the training-data
note in the acknowledgements/licence file, and get a one-line legal sign-off. Rejecting it means
shipping 1.0 without depth for ordinary photos: embedded depth only, with every other photo showing
the failure state.

**T2 — Bundle the model (+24 MB iOS / +26 MB Android) or download it on first use.**
Evidence: §3 sizes. Download-on-demand (Apple On-Demand Resources / Background Assets, Play Feature
or Asset Delivery) keeps the base install smaller. But Focus & Blur would then need the network the
first time, and that adds a new failure state that is not in the approved design.
**Recommendation:** bundle it. It is free, works offline, needs no extra UI state, and matches "no photo or
feature depends on a service".

**T3 — Meaning of the "Focus depth" slider.**
The prototype has both a tap target and a "Focus depth" slider (default 40). This evaluation treats
the slider as **depth of field** (how deep the sharp zone is), because the tap already chooses the
focal distance. A second control for the same thing would conflict with the tap.
**Recommendation:** keep it as depth of field (sheet 10, row 1). If the intent was "focal distance",
the alternative is to make the slider move the focal plane and drop the tap. That is not
recommended: tapping the thing you want sharp is the expected gesture.

## Layout of `experiments/depth/`

| Path | Committed | Purpose |
|---|---|---|
| `fetch_models.py` | yes | Downloads the commercially usable candidates (pinned revisions) → `models/` + `models/MANIFEST.json` (SHA-256) |
| `MODEL_SOURCES.csv` | yes | Every candidate: URL, revision, SHA-256, code/weights licence, verdict |
| `subject_mask.swift` | yes | Apple Vision foreground matte (`VNGenerateForegroundInstanceMaskRequest`) → `cache/masks/` |
| `estimate_depth.py` | yes | Runs all candidates → `cache/depth/<candidate>/`, `results/desktop_inference.json` |
| `compare_depth.py` | yes | Candidate sheet + subject-in-front / edge-alignment check → `results/depth_ordinal_check.json` |
| `refocus.py` | yes | **Reference renderer** (executable form of §6) |
| `make_sheets.py` | yes | All demonstration sheets |
| `convert.py` | yes | Core ML (fp16, linear 8-bit, 8-bit palettised; `--square`) + ONNX (fp32, int8) conversion; crash-safe per-compute-unit probes of ours and Apple's packages (parity, latency, load/compile time, RSS) → `results/conversion.json` |
| `convert_tflite.py` | yes | LiteRT conversion and parity (separate venv; `--square` for 518×518) → `results/conversion_tflite.json` |
| `orientation_check.py` | yes | Rotate vs stretch vs square input for portrait photos → `results/orientation_check.json` |
| `embedded/read_depth.swift` | yes | iOS embedded depth reader + HEIC fixture writer |
| `embedded/dynamic_depth.py` | yes | Android Dynamic Depth / GDepth reader + fixture writer |
| `results/*.json` | yes | Measurements quoted in this document |
| `models/`, `cache/`, `embedded/fixtures/` | no | Weights, converted models, depth/matte caches, fixtures |

Photos: the 22 Unsplash-licensed test photos listed in `experiments/lut3d/photos/MANIFEST.csv`
(same images as `docs/ui/assets/photos/`).
