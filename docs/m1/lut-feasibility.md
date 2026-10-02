# Image-Adaptive 3D LUT — Feasibility Report (M1)

Status: **for Codex review**. Experiment code: `experiments/lut3d/` (isolated from `ios/Lightly/`).
Reproduce: `experiments/lut3d/README.md`.

## Validated vs experimental (read first; added after Codex M1 review)

| Claim | Status | Evidence / caveat |
|---|---|---|
| Python port reproduces the upstream kernel and classifier | **Validated** (desktop) | `verify_port.py`, max 2.4e-7 |
| Core ML fp32 / ONNX conversions match PyTorch | **Validated** on desktop. iOS Core ML also on 2 phones | ONNX on an Android phone: **not run** |
| iOS on-device inference + fused LUT match golden | **Validated** on iPhone SE 3 and iPhone 11 Pro Max | Weights within 2e-6, LUT within 1.2e-7 |
| Android on-device inference | **Not validated** | Phones disconnected. The emulator hit SIGILL in ONNX Runtime; this cannot be dismissed as emulator-only until a phone runs |
| Cross-platform (iOS ↔ Android) inference parity | **Not validated** | Needs Android phone runs |
| Android GL LUT application within 1/255 | **Emulator only** | Must be re-measured on Adreno and Mali |
| iOS LUT application within contract tolerance | **Fails** with `CIColorCube*` (5/255) | A float-LUT Metal kernel is proposed but not built or measured |
| Timings in §6 | **Experimental pipeline only** | They do not cover the final Metal kernel, the proposed local-exposure pass, or a full export |
| 48 MP | LUT application timed (269–380 ms) | Full 48 MP decode → render → JPEG export memory and time **not measured** |
| Quality rubric results (§5) | **Experimental** | Heuristic metrics; no human study; already-edited web photos |
| Guardrails and local exposure | **Experimental** | Tuned and evaluated on the same 22 images |
| Canonical analysis input robustness | **Measured** on desktop (23 images) | Not yet measured end-to-end on devices |

## 0. Verdict

| Question | Answer | Evidence |
|---|---|---|
| Can the architecture be converted and run on iOS and Android? | **iOS: yes. Android: not yet validated.** Core ML fp32 and ONNX match PyTorch to ≤ 1/255 on desktop. On iOS devices the model matches within 2e-6. ONNX on an Android phone has not run (emulator SIGILL). LUT application via Core Image misses tolerance (5/255), so a float-LUT Metal kernel is required. Android GL meets it (≤ 1/255, emulator) | §3, §6 |
| Is low-res inference separable from full-res LUT application? | **Yes.** The model sees only 256×256. The LUT (33³) is applied on the GPU at any resolution | §2 |
| Is it fast and light enough on phones? | **iOS: yes.** Inference ~1 ms, LUT apply 4–9 ms at preview size and 18–39 ms at 12 MP, peak ~550 MB (iPhone SE 3, 11 Pro Max). **Android: phone timings blocked** (devices disconnected). Emulator correctness passes | §6 |
| Do the pretrained weights meet the Deep Color-style objective? | **No.** They behave like a mostly fixed "punchy" style: brightening, +20–50% chroma, crushed blacks, and they darken backlit subjects. Already-good photos change by mean ΔE00 ≈ 8 | §5 |
| Can the pretrained weights ship? | **No.** They are trained on MIT-Adobe FiveK, which is research-only | `docs/m1/licensing.md` |
| Is the approach still the right one? | **Yes, with retraining + two small additions.** A global LUT can express the global part of a "develop" (WB, exposure, tone curve, saturation). It cannot lift a backlit subject without also lifting the background | §5.3, §7 |

## 1. Upstream reference — exact identification

| Item | Value |
|---|---|
| Repository | https://github.com/HuiZeng/Image-Adaptive-3DLUT |
| Revision | `b491f6df64a588864739a157db271e5c848e1805` (2022-11-26) |
| Weights used | `pretrained_models/sRGB/classifier.pth` sha256 `bae98653…8021a`, `LUTs.pth` sha256 `c1bb2bc4…c121a` (paired, FiveK expert C). Verified by `reference/fetch_reference.sh` |
| Code licence | Apache-2.0 (LICENSE added 2021-09-23) |
| Dataset / weight terms | FiveK research-only. Weights: **treat as non-commercial** (see licensing doc) |
| Classifier | 270,083 params. Upsample→256×256 bilinear (aspect ignored), 5 stride-2 convs + LeakyReLU + InstanceNorm, dropout, 8×8 conv → 3 weights (raw, no softmax) |
| Basis LUTs | 3 × [3,33,33,33] float32, layout `LUT[c,b,g,r]`, flat `r + 33g + 33²b` (Core Image `CIColorCube` order) |
| Input normalisation | `torchvision.to_tensor`: 8-bit sRGB → [0,1]. **Gamma-encoded**, no mean/std |
| Colour-space assumption | Input = FiveK DNGs rendered to sRGB by Lightroom with neutral settings, i.e. **flat, unprocessed renders**. Output = expert C's sRGB retouch |
| Interpolation quirk | `binsize = 1.0001/(dim-1)`. Measured effect ≤ 0.02/255 → our contract uses exact-grid trilinear |
| Upstream preprocessing | Bilinear resize of the **full-resolution** image to 256 with no antialiasing, so results depend on source resolution |

### Port verification
- `reference/verify_port.py` compiles upstream `TriLinearForwardCpu` **verbatim** via ctypes and compares it with our NumPy port on the demo image. Max |Δ| = 2.4e-7, and 4 of 5.2M 8-bit values differ (rounding boundary).
- The classifier loads the upstream `state_dict` with `strict=True`.

## 2. Deployment pipeline (both platforms)

```
Original ─decode→ Proxy (display size, sRGB) ─antialiased resize→ 256×256 tensor ─model→ w[3]
w[3] × basis LUTs (3×33³) ─CPU fuse (~0.1M MACs)→ fused 33³ LUT ─(guardrails, strength)→ Auto LUT
Proxy ──GPU trilinear(Auto LUT ∘ Look LUT)──► preview          Full-res Original ──same──► export (JPEG once)
```

The model runs **once per photo**, on a 256×256 tensor derived from the proxy. Every subsequent preview or export is a GPU LUT pass. Slider movement never re-runs the model, never decodes at full resolution, and never encodes.

## 3. Conversion

| Artifact | Size | Tool | Parity vs PyTorch (desktop, all 23 images) |
|---|---|---|---|
| Core ML mlprogram fp32 | 1.09 MB | coremltools 8.3 | weights Δ ≤ 1e-5 (reported 0.0); pixels ≤ 1/255 on CPU, GPU and ANE |
| Core ML mlprogram fp16 | 0.55 MB | coremltools 8.3 | GPU/ANE: weights Δ 0.0038, pixels ≤ 1/255. **CPU: weights Δ 0.113 → pixels 7/255.** Reject fp16 |
| ONNX opset 17 | 1.08 MB | torch.onnx | weights Δ 1e-5, pixels ≤ 1/255 (onnxruntime 1.30 CPU) |
| Basis LUTs (RGBA f32) | 1.72 MB | `convert.py` | Exact (bit copy). Could be stored as fp16 RGB (0.65 MB) |

**Preprocessing sensitivity.** The upstream full-res bilinear path and our antialiased 256 path give weights up to 0.43 apart, which is up to **14/255** in output pixels (worst: `wellexposed_03`). The resize algorithm must therefore be identical on iOS and Android and pinned in the contract, with golden tensors (`golden/*/input256.f32`).

## 4. Test set

22 photos from Unsplash (Unsplash License; sources, photographers, hashes in `experiments/lut3d/photos/MANIFEST.csv`), plus the upstream demo image (FiveK, research licence, used only to verify the port).

| Class | n | Notes |
|---|---|---|
| Portrait — light / medium / deep skin | 2 / 2 / 3 | Deep set covers a neutral backdrop, outdoor daylight and low-key studio |
| Night | 3 | City street, cobblestone street, bar interior with mixed light |
| Backlit | 3 | Window, sun in frame, profile against sky |
| Sunset | 3 | |
| Landscape | 3 | One Display P3 |
| Already well-exposed | 3 | One Adobe RGB (1998) |

**Limitations of the set.**
- These are already-edited web photos, not straight phone camera output.
- 3000 px versions, not originals.
- There are no HEIC or HDR gain-map files.
- There are no Arsenal 2 captures.

Personal phone originals should be added (U9).

## 5. Quality against the Auto objective (Deep Color reference)

Scripts: `reference/compare.py` (sheets `experiments/lut3d/report/sheets/`) and `reference/evaluate.py` (rubric CSV `report/eval_rubric.csv`, sheets `report/eval_sheets/`).

Variants:
- **auto100** — upstream behaviour.
- **guard75** — endpoint guardrail + 75% strength.
- **guard75_hp** — + warm-hue (skin/sunset) protection, done in LUT space.
- **local_g75hp** — + low-frequency local exposure gain before the LUT.

All guardrails are experimental and our own, not part of the upstream method.

### 5.1 Rubric results (mean per class)

| Class | Criterion (target) | auto100 | guard75 | guard75_hp | local_g75hp |
|---|---|---|---|---|---|
| Portrait skin | hue shift ≤ 4° | +5.4° | +3.9° | **+3.1°** | +3.1° |
| | chroma ratio ≤ 1.12 | 1.38 | 1.27 | **1.07** | 1.07 |
| | skin ΔL* | +9.4 | +8.9 | +8.9 | +8.0 |
| Sunset | warm chroma ratio 0.95–1.10 | 1.05 | 1.02 | 1.01 | 1.00 |
| | warm hue shift ≤ 4° | +6.0° | +4.6° | **+3.6°** | +3.9° |
| | new black clipping | +3.5 pp | +0.5 pp | +0.5 pp | +0.1 pp |
| Night | median L* lift ≤ 3 | **+6.3** | +6.3 | +6.3 | +6.4 |
| | new black clipping | **+7.4 pp** | +0.1 pp | +0.1 pp | 0.0 pp |
| | overall chroma ratio | 1.45 | 1.34 | 1.12 | 1.14 |
| Backlit | subject ΔL* (> 0) | **−5.5** | −2.6 | −2.6 | **+2.7** |
| | face skin ΔL* (> 0) | −7.8 | −3.0 | −3.0 | **+5.7** |
| | skin hue shift ≤ 4° | −13.3° | −9.7° | −3.0° | −0.9° |
| | highlight ΔL* (no new clipping) | −1.5 | +1.2 | +1.2 | −3.3 |
| Already good | mean ΔE00 ≤ 3 | **8.4** | 7.2 | 7.0 | 7.0 |
| | overall chroma ratio | 1.34 | 1.25 | 1.21 | 1.27 |
| Landscape | mean ΔE00 | 6.5 | 5.3 | 5.2 | 5.9 |

Per-image values are in `report/eval_rubric.csv`. Per-image notes from visual review of the sheets:
- **portrait_deep_03** (low-key studio): auto100 brightens the face but shifts skin toward orange and crushes the backdrop (black clipping 2.8% → 21.5%). The guardrail removes the crush.
- **portrait_light_01**: auto100 adds a visible yellow cast to skin and hair.
- **landscape_01**: the white sky turns dull grey, because the fused LUT maps white to 249/255.
- **wellexposed_02**: white maps to 241/255.
- **night_01**: the sky crushes to black, and +4 L* lift.
- **backlit_01**: the subject gets **darker**.
- **sunset_02**: the sky shifts toward cyan-blue, and contrast and saturation become "HDR-ish".
- **wellexposed_01/02**: generic saturation and contrast punch on photos that needed nothing.

### 5.2 What the global LUT does well and badly

**Meets the objective (with guardrails):**
- Sunset warmth is preserved: chroma is stable and hue is within 4° after protection.
- With protection, skin hue stays within 4° and chroma within ×1.11 on all 7 portraits.
- Highlight clipping is reduced on blown skies, though see "dull whites" below.

**Falls short:**
1. **Already-good photos change a lot** (ΔE00 ≈ 7–8 even guarded). The model was trained to turn flat FiveK renders into an expert's edit, so it always adds contrast and saturation. Guardrails can't fix this; it is a **training-data** problem: inputs must include already-processed phone output, with near-identity targets when the photo is already good.
2. **Night mood is lifted** (+6 L* median). Again this is training-data driven. A small mitigation would be a strength cap tied to scene statistics, but that is a heuristic.
3. **Backlit subjects cannot be raised by any global transform** without raising equally bright background pixels. The upstream model darkens them. This is a **structural** limit of a global LUT.
4. **Skin hue/chroma drift** follows from expert C's warm taste. Unprotected, the drift differs by skin tone:
   - **Deep skin is oversaturated most:** chroma ×1.43–1.68 at auto100.
   - **Light skin shows the largest hue shift:** +7–8°.
   - **Intentional low-key portraits are brightened:** portrait_deep_03's face gains +22 L* even when guarded, which removes the intended mood. This is the same "always develop toward expert C" problem as item 1.

   LUT-space protection fixes the hue and chroma drift. LUT-space protection fixes it, but it is global, so wood or sand of the same hue is protected too.
5. **Black/white endpoints** fall outside [0,1] (black → −5…−20/255; white → 241–287/255). This causes crushed shadows or grey whites. The endpoint guardrail fixes it at zero runtime cost.

**Image adaptivity is real but narrow:**
- Weights vary across the set (w₀ 1.34–2.14, w₁ −2.86–0.96, w₂ −1.38–−0.11).
- The dominant behaviour is the same global style, scaled per image.
- Compared with Deep Color's description ("set of adjustments custom to each photo"), the pretrained model's adjustments are not custom enough.

### 5.3 Smallest necessary additions (recommended, not implemented beyond experiment)

| # | Addition | Fixes | Runtime cost | Scope |
|---|---|---|---|---|
| A1 | **Retrain** the same architecture on licensed data with phone-processed inputs, including already-good → near-identity pairs and night/backlit cases. Add a training loss term for endpoint and skin-hue constraints | Already-good over-processing, night lift, licence | None (same model size) | Required anyway for licence |
| A2 | **LUT-space guardrails** (endpoint renormalisation, warm-hue protection), versioned in `AutoResult` | Crushed blacks, grey whites, skin/sunset hue drift | ~0 (edits the 33³ LUT once per photo) | Small, shared Python reference + 2 ports |
| A3 | **One low-frequency local exposure pass** (smooth gain map from a ≤ 512 px edge-preserving base layer, applied in linear light before the LUT) | Backlit subjects (subject +2.7 L*, face +5.7 L* in the experiment). The backlit face chroma ratio rose to 1.39, so the gain needs chroma compensation | One extra full-image multiply plus a small low-res filter | One contract operator; gate on dynamic range |

**Not recommended now:** semantic segmentation (sky, skin, subject masks), face-specific edits, multi-frame or RAW processing. Each is a large scope increase. Revisit only if A1–A3 fail the rubric on real phone photos.

## 6. Platform measurements

Only development devices were used: iOS phones with Developer Mode on, and Android phones with USB debugging already authorised. Release builds. Raw data: `experiments/lut3d/results/<platform>/<device>/results.json`. Each run covers 23 images; the medians below are across those images.

### 6.1 iOS (Core ML + Core Image)

| | iPhone SE (3rd gen), A15, 4 GB, iOS 27.0 | iPhone 11 Pro Max, A13, 4 GB, iOS 27.0.1 |
|---|---|---|
| Model compile (first install) fp32 | 37 ms | 103 ms |
| Model load, cold / warm (fp32, CPU) | 26 / 1.0 ms | 156 / 1.1 ms |
| Inference fp32, CPU only (recommended) | 0.65 ms | 1.5 ms |
| Inference fp32, GPU / all units | 2.9 / 3.0 ms (+~1.3 s shader compile on first GPU use) | 4.7 / 4.7 ms (+~1.5–1.7 s first use) |
| Inference fp16, ANE | 0.51 ms (runs on ANE) | 1.95 ms (compute plan reports CPU) |
| Decode source PNG / resize to 256 | 193 / 17.6 ms | 235 / 24 ms |
| Full JPEG decode / 2048 px proxy decode | 81 / 106 ms | 105 / 139 ms |
| Fuse 3 basis LUTs (vDSP) | 0.05 ms | 0.09 ms |
| LUT apply, preview (2048 px long edge) | 4.1 ms | 9.2 ms |
| LUT apply, 12 MP (4032×3024) | 18 ms | 39 ms |
| LUT apply, 48 MP (8064×6048) | 269 ms | 380 ms |
| JPEG encode 12 MP, q 0.9, once | 64 ms | 77 ms |
| Peak phys_footprint (whole run) | 551 MB | 547 MB |
| Thermal start → end | nominal → fair | nominal → nominal |

**Parity on device** (identical on both phones):
- fp32 weights within 2e-6 of golden, and the fused LUT within 1.2e-7.
- fp16 is device-dependent: 3.4e-3 on the ANE, but 0.11–0.23 on CPU or GPU, so fp16 is rejected.
- **LUT application via `CIColorCubeWithColorSpace`: max 5/255, mean 0.15/255, 1.8% of pixels > 1/255, 0.4% > 2/255.** This fails the contract tolerance of max 2/255.
- Likely cause, inferred from the configurations tested (not a documented Core Image fact):
  - In those configurations, Core Image behaved as if it stored cube data clamped to [0,1] at 8-bit precision.
  - A CPU emulation of "clamp + 8-bit" reproduces its output to within 1 level, and the fused LUT spans −0.14…1.35.
  - Untested configurations: other cube data formats, and other context/working formats beyond RGBAf.
- **iOS must therefore apply LUTs with a custom Metal kernel (or `CIKernel`) on a float 3D texture.**
- Plain `CIColorCube` in Core Image's default linear working space is badly wrong (mean 30/255). The colour-space wrapper is mandatory.

**Preprocessing:**
- vImage Lanczos moves the weights by up to 0.145.
- A direct port of the reference antialiased resize matches to 2e-6.
- This confirms that the resize algorithm must be pinned in the contract.

**Not measured (iOS):**
- The 48 MP peak memory could not be separated from the per-image stage. It is ≤ 551 MB.
- iPhone 15/16/17-class (A17+) hardware: no development-enabled device of that class was available.

### 6.2 Android (ONNX Runtime + OpenGL ES 3.0) — **phone timings BLOCKED**

**Blocker:** both development phones disconnected from USB before the run. The Nothing A069 (SM7635, Android 16) failed at the first step with `adb: device '002843623001047' not found`. The motorola edge 60 (MT6878, Android 15) is also absent: `adb devices` lists nothing, and macOS shows no Android USB device. To resume, reconnect and unlock the phones, then run `SKIP_BUILD=1 experiments/lut3d/android/run_android.sh <serial>` (about 10–15 min each).

**Done without hardware:**
- Release APK (ONNX Runtime Android 1.30.0, arm64) builds.
- The harness implements every measurement in §6.1, plus NNAPI/XNNPACK backends and two GL variants.
- **Correctness smoke test on a local emulator (Pixel 9 Pro AVD; timings not valid):**

| Check | Result |
|---|---|
| Kotlin CPU reference vs `reference.png` | bit-exact (max 0) |
| GLES `RGBA16F` 3D texture, hardware linear filtering | max 1/255, mean 0.010, 0 px > 1 |
| GLES `RGBA32F` + manual trilinear (`texelFetch`) | max 1/255, mean 2.3e-5, 0 px > 1 |
| On-device 256×256 tensor vs golden | ≤ 2.4e-7 |
| Fused LUT vs golden | ≤ 2.4e-7 |
| 12 MP / 48 MP render (single tile; GL max texture 8192) | completed; peak 539 MB |
| ONNX Runtime inference | **SIGILL inside `libonnxruntime.so`** on the emulator. Cause unknown. It may be emulator-specific, but it **cannot be dismissed** until phones run, and it is an Android blocker until then |

Unlike Core Image, both GL variants meet the contract tolerance. `RGBA16F` hardware filtering suffices on this GPU emulation, but must be re-checked on Adreno (SM7635) and Mali (MT6878).

### 6.3 Cross-platform parity

From the golden comparisons:
- iOS (Core Image) is within 5/255 of the reference.
- Android GL is within 1/255 on the emulator.

**Cross-platform parity is NOT validated.** Once iOS moves to a float-LUT Metal kernel, both platforms are *expected* to be ≤ 1/255 from the same reference. That expectation is unverified until the Metal kernel exists and the Android phones have run inference and LUT application.

## 7. Limitations of this experiment

- Desktop timings (Apple M4) are **not** phone performance. Phone numbers are in §6 only.
- The quality rubric uses heuristics: face boxes from Apple Vision, warm-hue pixel sets, and luminance percentiles. There is no ground truth and no human preference study.
- Guardrails and the local-exposure prototype were tuned by eye on the same 22 images they are evaluated on. That is overfitting risk; validate on a held-out set.
- The local-exposure prototype uses OpenCV bilateral filtering in Python. Its device cost is not measured.
- There is no Arsenal 2 output to compare against directly (U9).
