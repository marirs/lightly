# Edit › Remove: on-device inpainting evaluation

Status: evaluation complete. One trade-off needs a product decision (§8) and one item needs legal sign-off (§8). Date: 2026-10-03.
Code: `experiments/inpaint/` (reproduction steps in §10). Weights and exported models are git-ignored under `experiments/inpaint/models/`.
Contact sheets: `~/.codex/artifacts/lightly/v1/remove/` (outside the repo; files listed in §5.1).

## 1. Bottom line

- **Recommendation for 1.0: one engine, LaMa (big-lama), for every Remove stroke on both platforms.**
  - Code and weights are both Apache-2.0.
  - It runs on a 512×512 crop around each stroke. Only the brushed pixels are pasted back into the untouched full-resolution photo.
  - It was the only candidate that removed all six real-photo cases cleanly.
  - On the 66-mask hold-out test it had the best perceptual score in 57 of 66 masks, and it was best for spots, strokes and blobs alike.
- **Classical fill is not needed.**
  - OpenCV Telea is the obvious classical choice for blemishes, but LaMa also beats it on blemish-sized dabs (median LPIPS 0.040 vs 0.203). Telea leaves flat, pore-less discs on skin.
  - We therefore do not ship a classical route in 1.0. Nothing is swapped in silently, and the feature is never declared unavailable.
- **MI-GAN (MIT) is the size and speed fallback.**
  - It is 14 MB in Core ML fp16, about 15× less compute than LaMa, and about 40 ms on the Mac's Neural Engine.
  - It left visible ghosting or smears on 3 of the 6 real cases, so it is not recommended as the primary engine.
- **No public OS API does object removal** on iOS 17–26 or Android 10–16. See §3.
- **Exports are verified.** Core ML (iOS) plus LiteRT and ONNX (Android) are produced from one graph. Exact parity with PyTorch: fp32 PSNR ≥ 130 dB, fp16 ≥ 64 dB.
- **Phones were not measured.** This task did not allow installs on phones. On-device figures are estimates built from M4 Core ML / LiteRT measurements (§6).

## 2. Candidates, licences and verdicts

Licence verdicts check three layers: the **code** licence, the **weights** licence, and the **training data** terms. A "Yes" means both the code and the weights grants allow commercial use. The training-data note is a separate risk; §8 covers it.

| Candidate | Code licence | Weights licence | Training data (terms) | Commercial use? | Downloaded? | Size | Input |
|---|---|---|---|---|---|---|---|
| **LaMa big-lama** ([advimman/lama](https://github.com/advimman/lama) @ `786f593`) | Apache License 2.0 | Apache-2.0: the repo LICENSE, plus the HF card of the README-linked mirror [`smartywu/big-lama`](https://huggingface.co/smartywu/big-lama) (`license: apache-2.0`). There is no separate weights licence upstream. | Places-Challenge / Places2 (non-commercial research terms on the *images*; see note) | **Yes** (code + weights) | Yes | 51.0 M params; Core ML fp16 **103 MB**, fp32 205 MB, ONNX 211 MB, LiteRT fp32 206 MB | Any multiple of 8 (trained at 256, robust to ~2k); **fixed 512 used** |
| LaMa CelebA-HQ / Qualcomm "LaMa-Dilated" ([qualcomm/LaMa-Dilated](https://huggingface.co/qualcomm/LaMa-Dilated)) | Apache-2.0 | Card says apache-2.0, but the card states *"Model checkpoint: Dilated CelebAHQ"* | CelebA-HQ ("non-commercial research purposes only"); also a face-only domain | **No** (data terms + wrong domain) | No | 45.6 M params, 174 MB | 512 |
| **MI-GAN 512 Places2** ([Picsart-AI-Research/MI-GAN](https://github.com/Picsart-AI-Research/MI-GAN) @ `2b793c5`) | MIT License | MIT: [`LICENSE-WEIGHTS`](https://github.com/Picsart-AI-Research/MI-GAN/blob/main/LICENSE-WEIGHTS), added upstream 2026-09-14 in commit `680b0c6`; HF card [`andraniksargsyan/migan`](https://huggingface.co/andraniksargsyan/migan) `license: mit` | Places2 (same note). Distilled from a Co-Mod-GAN teacher. The training scripts include NVIDIA StyleGAN2-ADA `torch_utils`/`dnnlib` (proprietary NVIDIA header). The inference module `migan_inference.py` is plain PyTorch, and only that ships, as a converted graph. | **Yes** (code + weights) | Yes (Places2 only) | 5.97 M params; Core ML fp16 **14 MB**, fp32/ONNX/LiteRT 28 MB | **Fixed** 512 (a 256 model also exists) |
| MI-GAN FFHQ 256 | MIT | MIT | FFHQ (images under BY-NC-SA 4.0 as a collection; faces) | **No** | Fetched as part of the Drive folder, **deleted immediately**, never used | 24 MB | 256 |
| MAT ([fenglinglwb/MAT](https://github.com/fenglinglwb/MAT)) | "Attribution-NonCommercial 4.0 International" (CC BY-NC 4.0) | Same, NC (and built on StyleGAN2-ADA) | Places2 / CelebA-HQ | **No** | No | ~62 M params | 512 |
| Co-Mod-GAN ([zsyzzsoft/co-mod-gan](https://github.com/zsyzzsoft/co-mod-gan)) | BSD-style, but the bundled `stylegan2` part is under "Nvidia Source Code License-NC" | Same | Places2 / FFHQ | **No** | No | ~100 M+ | 512 |
| Stable Diffusion inpainting (SD 1.5 / 2 inpainting; Apple `ml-stable-diffusion` for Core ML) | CreativeML Open RAIL-M / RAIL++-M (commercial use allowed, with use-based restrictions) | Same | LAION-5B (web-scraped, unresolved rights) | Licence-wise yes, with restrictions | No: fails the size/latency budget before quality matters | UNet 865 M params, about 1.3–2.5 GB fp16 even with 6-bit palettisation around 1 GB; 20+ denoise steps; multi-second to tens of seconds and 2–4 GB RAM on A15-class phones; hallucinates content | 512 latent |
| Classical: OpenCV `cv::inpaint` Telea / NS | Apache-2.0 (OpenCV ≥ 4.5) | n/a | n/a | **Yes** | (pip) | ~0 MB model (code only) | Any |
| Classical exemplar: OpenCV-contrib `xphoto` ShiftMap (He & Sun 2012) | Apache-2.0 | n/a | n/a | **Yes** | (pip) | ~0 MB | Any (slow) |
| Classical exemplar: PatchMatch / Criminisi | Algorithms; Adobe holds PatchMatch-family content-aware-fill patents (filed around 2009–2010). **Not checked; would need a patent search before we implement one.** | n/a | n/a | Unverified | No | — | — |

**Note on Places2 training data.** The [Places2 download page](http://places2.csail.mit.edu/download.html) (archived 2019 terms) says: *"You will use the data only for non-commercial research and educational purposes. You will NOT distribute the above images."*

- These terms bind whoever downloaded the images, i.e. the model authors. They say nothing about trained models.
- The authors released the weights under Apache-2.0 (LaMa) and MIT (MI-GAN).
- This is the same provenance situation as essentially every public inpainting model. It does not separate the two commercially usable candidates. It is listed for legal sign-off in §8.

**Weight downloads.** Exact URLs and SHA-256 hashes are pinned in `experiments/inpaint/fetch_models.sh`:

| File | URL (pinned revision) | SHA-256 |
|---|---|---|
| `big-lama.zip` | `huggingface.co/smartywu/big-lama/resolve/05cb2be7…/big-lama.zip` | `f1b358ca24093b93a106183b98a3dea6e8ed09f3b43ea7251eb2c81e7b4575f6` |
| `big-lama/models/best.ckpt` (in the zip) | — | `fccb7adffd53ec0974ee5503c3731c2c2f1e7e07856fd9228cdcc0b46fd5d423` |
| `migan_512_places2.pt` | Google Drive folder `1xNtvN2lto0p5yFKOEEg9RioMjGrYM74w` (linked from the MI-GAN README) | `1d6087eee0aac8923ad2606be5d8caeb4824d3e4de331995e420c74e124a466a` |
| `migan_256_places2.pt` | same folder | `8b82b2e82fc8e5a2e1f06827594aac1a5d66a9ca41e24199ddd969847788097f` |
| `migan_pipeline_v2.onnx` | `huggingface.co/andraniksargsyan/migan/resolve/406830d0…/migan_pipeline_v2.onnx` | `6f1f3530a1a2324b19752018ce756088b07973cda8d7d890034ace5c8a48c40b` |
| `migan.onnx` | same revision | `593eba0b7e04730f1b61c0a3cbca68d97d8d6a7ff5c6a44a7b9d7fcd880fc5ae` |

## 3. System APIs (iOS 17–26, Android 10–16)

**iOS: no public API.**
- Photos' **Clean Up** (iOS 18.1+, Apple Intelligence devices) exists only inside the Photos app. It is not exposed through PhotoKit, Vision, Core Image or Image Playground.
- `ImageCreator` (iOS 18.4+) does prompt-based generation, not masked removal.
- The Foundation Models framework is text-only.
- iOS 17 has nothing comparable.

**Android: no public API.**
- Google Photos **Magic Eraser** and Samsung **Object Eraser** are app features with no public API.
- The [ML Kit GenAI APIs](https://developers.google.com/ml-kit/genai) are Summarization, Proofreading, Rewriting, Image description, Speech recognition and Prompt. None does image editing or inpainting, and they need recent Gemini Nano devices anyway.
- Android 10–16 has no platform API for this.

**Conclusion:** we must bundle a model.

## 4. Method

**Pipeline.** The same pipeline was used for every candidate, and the apps would implement it natively (`inpaint_lib.py`):

1. Split the brush into strokes (connected components, 24 px merge gap).
2. Route each stroke by size. The route changes only *how* the same engine is fed, never *which* engine runs:
   - **native**: context window (2.2 × stroke extent) ≤ 512 px. Inpaint a 512 crop at native resolution with no resampling. Covers blemishes and small objects.
   - **tiled-native**: thin strokes (≤ 64 px thick) whose window exceeds 512. Walk 512 tiles with 128 px overlap along the stroke at native resolution, each tile seeing earlier fills as context. Covers wires and cracks.
   - **downscaled**: everything else. Resize a square context window (2.2 × extent) to 512, inpaint, then resize back. Covers people, signs and large objects.
3. Paste back *only* the brushed pixels, with a 3 px feather that lies outside the brush. Every run was checked to leave pixels more than 12 px outside the brush bit-identical (`pixels_outside_brush_unchanged: true` in `results/*.json`).

**Cases.** Six real-photo cases from the licensed Unsplash sets (`experiments/lut3d/photos/MANIFEST.csv`). Brush shapes are in `experiments/inpaint/cases.json`.

| Case | Photo | Category | Mask | Route |
|---|---|---|---|---|
| c1_blemish | portrait_medium_01 | small blemish / spot | 2 dabs, ⌀ 40–44 px | native ×2 |
| c2_distant_person | wellexposed_01 | distant person | 89×244 px lasso | downscaled (×1.05) |
| c3_sign_pole | wellexposed_02 | sign / pole | 2 signs + pole, 216×623 px | downscaled (×2.7) |
| c4_power_line | wellexposed_02 | power line | 3 wire strokes, 24–46 px wide, up to 745 px long | tiled-native (1+2+3 tiles) |
| c5_large_object | backlit_02 | large object | person, 629×1164 px (9.8 % of frame) | downscaled (×3.9) |
| c6_textured_background | wellexposed_01 | object on textured background | traffic light over a gridded facade, 154×431 px | downscaled (×1.85) |

**Hold-out quality test** (`holdout_eval.py`). Object removal has no ground truth, so this test hides *real background* behind synthetic brushes and scores the fill against the hidden pixels.

- 22 photos × 3 shapes:
  - spot: ⌀ 48 px
  - stroke: about 700 px long, 28 px wide
  - blob: about 360 px lasso
- Each shape exercises one route.
- Metrics, computed on a crop around the mask:
  - LPIPS (AlexNet; lower is better; it tracks visible artefacts much better than PSNR)
  - PSNR on the masked pixels

**Host caveat.** The Mac (Apple M4, 32 GB) was shared with other agents and an Android emulator during this run. Load average reached 50–980, and 27 GB of swap was in use. Desktop wall-clock times are therefore inflated and noisy:

- Every result records its load average.
- Tables report the *minimum* of the repeats.
- Multiply-accumulates are reported as the load-independent cost measure.
- **Peak memory and quality numbers are unaffected by the load.**

## 5. Results

### 5.1 Contact sheets

All sheets are in `~/.codex/artifacts/lightly/v1/remove/`:

| Sheet | Content |
|---|---|
| `sheet_lama.jpg`, `sheet_migan.jpg`, `sheet_telea.jpg`, `sheet_shiftmap.jpg`, `sheet_lama_flex1024.jpg` | Per candidate: before / brush / after, one row per case, zoomed to the edit |
| `compare_<case>.jpg` | One case, all candidates side by side (zoomed) |
| `detail_<case>.jpg` | **1:1 pixels**, no resampling, around the largest stroke, all candidates. Best for judging |
| `fullframe_<case>.jpg` | Whole photo, all candidates. Shows the rest of the frame is untouched |
| `compare_all.jpg` | Overview: 6 cases × all candidates |

Full-resolution outputs are in `experiments/inpaint/out/<candidate>/<case>.png` (git-ignored).

### 5.2 Real-photo cases: visual verdicts (judged at 1:1 on `detail_*.jpg`)

| Case | LaMa @512 | MI-GAN @512 | Telea | ShiftMap |
|---|---|---|---|---|
| c1 blemish | ✅ clean; pores continue | ✅ clean | ⚠️ flat pore-less disc visible at 1:1 | ✅ clean |
| c2 distant person | ✅ clean; cart and pavement continued | ⚠️ faint translucent ghost of the person and pole | ❌ grey smear | ⚠️ clean but duplicates a pole |
| c3 sign + pole | ✅ clean; foliage, roof and fence continued | ⚠️ blocky dark smudge at the pole base | ❌ green smear | ✅ mostly clean, slight grid repeat |
| c4 power lines | ✅ wires gone over sky and foliage | ✅ wires gone | ❌ blurred bands across foliage | ✅ wires gone |
| c5 large person | ✅ plausible grass and fence; soft (fill is upscaled 3.9×) | ⚠️ plausible but blurrier; dark blotches | ❌ large flat smear | ❌ leaves part of the person and striped artefacts |
| c6 traffic light on facade | ✅ facade continued, with slight vertical streaking | ❌ dark ghost of the light and a bright blob | ❌ diamond-shaped smear | ⚠️ windows copied but misaligned |
| **Clean / 6** | **6** | **3** | **0–1** | **3** |

LaMa at ≤ 1024 px (the resolution-flexible variant) adds nothing on small strokes. It is *worse* on large holes: c5 shows repetitive, washed-out texture. Fixed 512 is also the simpler export, so it is the right setting.

### 5.3 Hold-out quality (66 masks; median per shape; lower LPIPS = better)

| Candidate | spot LPIPS | spot PSNR | stroke LPIPS | stroke PSNR | blob LPIPS | blob PSNR | best-LPIPS wins |
|---|---|---|---|---|---|---|---|
| **LaMa @512** | **0.040** | **26.6** | **0.0066** | **30.0** | **0.096** | **22.3** | **57 / 66** |
| MI-GAN @512 | 0.106 | 25.8 | 0.043 | 28.3 | 0.151 | 19.9 | 1 / 66 |
| Telea | 0.203 | 24.5 | 0.037 | 27.9 | 0.209 | 19.7 | 0 / 66 |
| ShiftMap | 0.078 | 24.8 | 0.016 | 27.0 | 0.152 | 18.2 | 8 / 66 |

LaMa is best on every shape, including blemish-sized spots. On spots, the classical exemplar method (ShiftMap) is second and beats MI-GAN, but it costs seconds per dab in OpenCV. Telea is worst on spots and blobs. Raw rows are in `experiments/inpaint/results/holdout.json`.

### 5.4 Compute, size and desktop cost

| | LaMa big-lama | MI-GAN 512 | Telea | ShiftMap |
|---|---|---|---|---|
| Params | 50.98 M | 5.97 M | — | — |
| MACs per 512 tile | **231 G** | **15.1 G** | negligible | n/a (iterative) |
| Core ML fp16 package | **103 MB** | **14.2 MB** | — | — |
| LiteRT fp32 / ONNX fp32 | 206 / 211 MB | 28 / 28 MB | — | — |
| PyTorch CPU, 4 threads, per 512 tile (min, contended) | 2.8–5.4 s | 0.5–0.9 s | 10–400 ms per case | 8–33 s per case |
| PyTorch peak RSS (eager; not representative of devices) | 4.5 GB | 1.2 GB | 0.54 GB (harness baseline, full-res photos) | 0.83 GB |

The PyTorch numbers only show relative cost. Section 6 has the deployable-runtime numbers.

## 6. Exported formats and on-device estimates

**Conversion** (`convert.py`, `convert_tflite.py`). All exports share one signature: `image` f32 [1,3,512,512] in 0..1, `mask` f32 [1,1,512,512] with 1 = remove, and output `result` f32 [1,3,512,512].

- LaMa's Fast Fourier Convolutions call `torch.fft.rfftn/irfftn`, which Core ML and LiteRT cannot use dependably. For export they are replaced by **exact DFT matrix products**, which match `torch.fft` to a max absolute diff of 1.9e-6. The spectral grid is only 64×64 at a 512 input.
- For LiteRT, LaMa's three `ConvTranspose2d(output_padding=1)` layers are rewritten as an equivalent `padding=0` + crop. The converter cannot legalise `output_padding`.
- litert-torch silently corrupts non-contiguous constants. The DFT matrices are therefore made contiguous; without this the first LaMa `.tflite` export came out at 34 dB.

Parity against PyTorch on a real crop (c6):

| Export | LaMa PSNR vs PyTorch | MI-GAN PSNR vs PyTorch |
|---|---|---|
| Core ML fp32 (mlprogram, iOS 17 target) | 130.8 dB | 135.3 dB |
| Core ML fp16 | 64.4 dB (max abs diff 0.024) | 63.2 dB (max abs diff 0.044) |
| ONNX opset 17 fp32 | 133.9 dB | 136.6 dB |
| LiteRT fp32 (litert-torch 0.9.4) | 131.4 dB | 137.8 dB |

**Measured on the Apple M4.** Core ML fp16 and LiteRT/ORT with 4 CPU threads, one 512 tile, 8 runs (`bench_formats.py`, `results/bench_formats.json`):

| Runtime / units | LaMa min / median | MI-GAN min / median | Peak RSS of process (LaMa / MI-GAN) |
|---|---|---|---|
| Core ML `.cpuOnly` | 1579 / 2318 ms | 566 / 874 ms | 357 / 408 MB |
| Core ML `.cpuAndGPU` | **255 / 529 ms** | 32 / 53 ms | 351 / 295 MB |
| Core ML `.cpuAndNeuralEngine` | 2336 / 2757 ms: **ANE compile fails** (`ANECCompile() FAILED`; 266 s first-load attempt, then CPU fallback) | **39 / 44 ms** | 520 / 307 MB |
| Core ML `.all` | 450 / 647 ms (295 s first-load ANE attempt) | 43 / 45 ms | 404 / 314 MB |
| LiteRT XNNPACK, 4 threads | 5640 / 6906 ms | 410 / 837 ms | 991 / 599 MB |
| ONNX Runtime CPU, 4 threads | 7383 / 8042 ms | 666 / 1505 ms | 902 / 905 MB |

(About 36 MB of each RSS figure is the Python process itself.)

**Phone estimates (not measured).** These scale the M4 numbers by relative GPU/ANE throughput, with MACs as a cross-check. Treat them as ±50 %.

| Device class | LaMa per 512 tile | MI-GAN per 512 tile |
|---|---|---|
| iPhone 15 Pro / 16 Pro (A17 Pro / A18 Pro GPU, about M4/2) | ~0.5–1.1 s (`.cpuAndGPU`) | ~0.05–0.1 s (ANE) |
| iPhone SE 3 (A15, 4-core GPU, about M4/3) | ~0.8–1.6 s | ~0.1 s |
| iPhone 11 Pro Max (A13, about M4/4.5) | ~1.2–2.4 s | ~0.2–0.25 s |
| Android flagship NPU (reference) | Qualcomm publishes 34–108 ms for its 45.6 M-param LaMa-Dilated on Snapdragon 8 Gen 1 → 8 Elite Gen 5 (QNN/LiteRT NPU) | — |
| Android mid-range GPU (LiteRT GPU delegate, Adreno 7xx / Mali-G6xx class, like our two dev phones) | **~1.5–3 s** (448 GFLOP at about 0.15–0.3 effective TFLOP/s) | ~0.1–0.2 s |
| Android mid-range CPU only (XNNPACK, about 3–4× slower than M4) | **~15–25 s** (too slow) | ~1.2–1.6 s |

**Memory on device.** The model needs about 100–200 MB of weights plus activations. The bottleneck activations are 64×64×512, about 4 MB in fp16. This cost is independent of photo size because of the crop. The full-resolution photo dominates (a 48 MP RGBA8 image is 192 MB). The CPU paths peak near 1 GB (fp32 weight packing), which is another reason to use GPU or fp16 on Android.

A stroke costs one model call per tile. A wire spanning the frame is 3–6 tiles, so expect about 2–5 s on an A15 with LaMa. The UI should show progress per stroke.

## 7. Recommendation for 1.0 and integration notes

**Engine.** LaMa big-lama, fixed 512 input, for **all** Remove strokes. Routing between native, tiled and downscaled feeds the same engine; there is no hidden algorithm switch. No classical route ships in 1.0. If a cheap blemish tool is wanted later, it should be a separately named **Spot heal** tool that the user picks. Even then, §5.3 says LaMa is better on spots, so the only argument for classical is instant live preview. The engine must never be swapped silently.

**iOS (Core ML).**
- Ship `lama_512_fp16.mlpackage` (103 MB). Xcode compiles it to `.mlmodelc`.
- Set `MLModelConfiguration.computeUnits = .cpuAndGPU`. **Do not use `.all` or the ANE**: the ANE compile fails and costs minutes on first load before falling back.
- Load lazily on first Remove use and release it on memory warning or when leaving the editor.
- Bundle-size options:
  - (a) ship in the app (+~95 MB compressed), or
  - (b) Background Assets / Apple-hosted asset pack, with an explicit "Preparing Remove (100 MB)…" state. Never fall back silently while it downloads.

**Android (LiteRT).**
- Ship `lama_512.tflite` with **fp16 weights**. The fp32 export is 206 MB. fp16 weight conversion (expected ~103 MB) is a follow-up; it was not produced here.
- Run on the LiteRT **GPU delegate**. Use the CPU (XNNPACK) only as a measured fallback, because a CPU pass on a mid-range phone takes about 15–25 s per tile.
- Deliver through Play Asset Delivery (install-time or fast-follow pack).
- ONNX Runtime Mobile works too (`lama_512.onnx`, exact parity), but LiteRT has better GPU/NPU delegate coverage on Android 10–16.

**Same result for preview and export.**
- Remove runs once, on the full-resolution *source* pixels, before tone and colour adjustments, the way heal works in Lightroom.
- It produces a **patch**: crop rect + full-resolution RGB patch + feathered alpha.
- Store the patch in the edit document, keyed by (source hash, stroke list, model id/version).
- Preview composites a downsampled view of that patch, and export composites the same patch at full resolution. The pixels are identical, so there is no preview/export divergence.
- Changing exposure or colour later never re-runs the model.
- When the bundled model version changes, keep old patches so existing edits reproduce exactly.
- The model is deterministic (no noise input), and the GPU/CPU numeric differences do not matter because the patch is cached.

**Cancellation.**
- Model calls run on a background queue or coroutine. Cancellation is checked between strokes and between tiles.
- Core ML `prediction` cannot be interrupted mid-call; at most one tile (~1–2 s worst case on A13) completes and is discarded.
- LiteRT supports in-flight cancellation (`Interpreter.Options.setCancellable(true)` + `cancel()`).
- Each stroke is committed to the edit stack only after its patch is complete, so undo/redo stays atomic per stroke.

**Quality follow-ups**, not blockers:
1. For downscaled strokes with scale > 2 (large objects), add matched grain/noise to the upscaled fill, or run a second native-res LaMa refinement pass. c5 is visibly soft at 1:1.
2. Auto-grow the brush by about 8–12 px, as the cases did, so object edges and shadows don't survive.
3. Show a per-stroke spinner and progress for tiled strokes.

## 8. Decisions needed

1. **Trade-off: LaMa on mid-range Android latency and size vs MI-GAN quality.**
   - Evidence: LaMa is clean on 6/6 cases and 57/66 hold-out wins. It costs 231 GMAC per tile, ~103 MB of fp16 weights, and an estimated **1.5–3 s per tile** on mid-range Android GPUs (15–25 s if only the CPU is usable).
   - MI-GAN is ~14 MB and ~0.1–0.2 s, but it ghosted or smeared on 3/6 cases and has 1/66 hold-out wins.
   - **Recommendation: LaMa on both platforms**, with GPU delegate on Android and a progress UI. Before committing, measure it on the two dev Android phones (Nothing A069, motorola edge 60) and the dev iPhones (SE 3, 11 Pro Max) with an InpaintBench harness in the LUTBench style. This task did not allow installs on phones; permission is needed for that run.
   - Fall back to MI-GAN on Android **only** if the measured GPU p95 exceeds about 4 s per tile. Even then, label it explicitly; do not swap it in silently.
2. **Legal sign-off: Places2-trained weights.**
   - Both commercially licensed candidates (LaMa Apache-2.0, MI-GAN MIT) were trained on Places2, whose image terms are non-commercial research only for the downloader. The authors licensed the *weights* permissively.
   - This applies to every pretrained inpainting model we could ship.
   - **Recommendation: proceed with LaMa and get counsel's sign-off before release.** The only alternative is training our own model on licensed data, which is a paid commitment and is not started.

No paid service or cloud processing was used. No user photo leaves the device in the recommended design.

## 9. Limitations

- No phone measurements (policy for this task). The Mac host was heavily contended, so latency figures are minimum-of-repeats and should be confirmed in a quiet run.
- Six hand-brushed cases plus 66 synthetic hold-out masks. A larger blind A/B with real user strokes should follow once the feature is in a TestFlight or internal build.
- Not evaluated:
  - int8 / palettised LaMa: could take Core ML to about 52 MB; needs a quality check.
  - LiteRT fp16-weight export.
  - The ONNX Runtime CoreML execution provider.
- The PatchMatch patent status was not checked, because no PatchMatch implementation is proposed.

## 10. Reproduce

```bash
cd experiments/inpaint
python3.11 -m venv venv && venv/bin/pip install torch==2.5.1 torchvision==0.20.1 coremltools==8.3 onnx onnxruntime \
    omegaconf pillow numpy opencv-python-headless lpips gdown psutil
python3.11 -m venv venv_contrib && venv_contrib/bin/pip install opencv-contrib-python-headless numpy pillow
python3.11 -m venv venv_tflite && venv_tflite/bin/pip install litert-torch omegaconf pillow opencv-python-headless
PATH="$PWD/venv/bin:$PATH" ./fetch_models.sh                 # pinned URLs + sha256; clones upstream code
export OMP_NUM_THREADS=4
for c in lama lama_flex1024 migan; do venv/bin/python run_eval.py $c; done
for c in telea shiftmap; do venv_contrib/bin/python run_eval.py $c; done
venv/bin/python sheets.py                                     # -> ~/.codex/artifacts/lightly/v1/remove/
venv/bin/python holdout_eval.py telea migan lama
venv_contrib/bin/python holdout_eval.py --score-later shiftmap && venv/bin/python holdout_eval.py --score-saved shiftmap
venv/bin/python convert.py && venv_tflite/bin/python convert_tflite.py
venv/bin/python bench_formats.py && venv_tflite/bin/python bench_formats.py tflite
venv/bin/python flops.py && venv/bin/python summarise.py
```

Committed results: `experiments/inpaint/results/` holds per-candidate case timings, `holdout.json`, `bench_formats.json`, `flops.json` and `conversion_report.json` (export sizes, parity and SHA-256).
