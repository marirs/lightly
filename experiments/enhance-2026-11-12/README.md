# Enhance (1.3) step 1: model candidates (2026-11-13)

Goal: choose an on-device upscaler and a face-restore model for Enhance on iOS and Android, from real outputs on test
photos, then speed and memory on the iPhone 11 Pro Max, iPhone SE 3 and Nothing A069.

## Weights (git-ignored, `weights/<model>/`; downloaded 2026-11-13 with the owner's approval)

| Job | Model | File | Size | SHA-256 | Source |
|---|---|---|---|---|---|
| Upscale, mobile | Real-ESRGAN general x4 v3 | `realesr-general-x4v3.pth` | 4.7 MB | `8dc7edb9…92` | github.com/xinntao/Real-ESRGAN, release v0.2.5.0 |
| Upscale, quality | Real-ESRGAN x4plus | `RealESRGAN_x4plus.pth` | 64 MB | `4fa0d389…f1` | github.com/xinntao/Real-ESRGAN, release v0.1.0 |
| Face restore | GFPGAN v1.4 | `GFPGANv1.4.pth` | 337 MB | `e2cd4703…ad` | github.com/TencentARC/GFPGAN, release v1.3.0 |
| Face restore | CodeFormer | `codeformer.pth` | 369 MB | `1009e537…b7` | github.com/sczhou/CodeFormer, release v0.1.0 |
| Face restore, lighter | GPEN-BFR-512 | `GPEN-BFR-512.pth` | 272 MB | `f1002c41…51` | github.com/yangxy/GPEN (Alibaba OSS mirror) |

Full hashes: `shasum -a 256 weights/*/*.pth`.

## Step 1a: synthetic low-resolution test (Mac, 2026-11-13)

Six `experiments/test-photos` portraits, degraded to 1/4 size + slight blur + JPEG quality 35, restored x4; the original
is the ground truth. Scripts: `run_a_esrgan_gfpgan.py` (pip basicsr), `run_b_codeformer.py` (CodeFormer repo b33cc7d),
`run_c_gpen.py` (GPEN repo 2c73670 generator, CodeFormer's detection/paste-back so only the face model differs),
`make_sheets.py` (face crops side by side, `outputs/sheets/`). All face models paste onto the same general-x4v3
background. Environment: `.venv` (Python 3.11, torch 2.14.1); basicsr's `functional_tensor` import patched in the venv;
`repos/CodeFormer/basicsr/version.py` added by hand.

Mac timings (MPS unless noted): general-x4v3 0.2–0.4 s per photo; x4plus ~5 s; GFPGAN (faces + background) 1.4–3.6 s;
CodeFormer 1.9–7 s; GPEN 4–9 s on CPU. PSNR favours bicubic (GAN models invent detail), so the models are judged by eye.

Observations:
- Upscalers alone make faces waxy and smear eyes on small faces (group photo): portraits need a face model.
- All three face models rebuild small faces convincingly. GPEN-512 stays closest to the person (eye shape, smile);
  CodeFormer 0.8 is close too; CodeFormer 0.5 invents most (stubble on the black-and-white boy, oversaturated lips);
  GFPGAN 1.4 smooths most and tints the black-and-white photo brown.
- Every face model removes freckles: an identity change to watch.
- Phone cost: the face models are 270–370 MB fp32 (~135–185 MB fp16) beside a ~200 MB app; general-x4v3 is 4.7 MB.

Provisional pick: general-x4v3 for the photo, GPEN-512 for faces (CodeFormer 0.8 as the alternative). The owner prefers
**CodeFormer 0.8** (2026-11-13), so the steps below use it.

## Step 1b: real old photos (Unsplash, 2026-11-13)

Ten free Unsplash photos (`real-photos/SOURCES.txt`; images git-ignored): five old family groups and five sepia or
black-and-white portraits (the portraits are recent uploads and may be vintage-style rather than real scans). Each is
reduced to 1200 px wide and enhanced x2: general-x4v3 for the photo, CodeFormer 0.8 for every face (`run_d_real.py`,
sheets from `make_real_sheets.py` in `outputs/real/sheets/`). CodeFormer found faces in all ten (up to 11 in a group).

- Old black-and-white family groups: small, soft faces become natural and recognisable; general-x4v3 alone makes them
  plastic and warps features. The pair is right for this case.
- Sepia portrait: CodeFormer paints blue eyes and red lips into a toned photo (its black-and-white check misses sepia).
  Fix to try: keep the restored face's detail and take its colour from the original.
- A painted family portrait (SpeUAC9IOng is a painting): CodeFormer turns painted faces photographic. Enhance should
  probably leave paintings and illustrations alone.

## Step 1c: on the phones (2026-11-13)

Conversions: `convert_coreml.py` (fp16 mlprogram; CodeFormer through `torch.export`, since tracing turns its shape-keyed
layer lookup into a cast Core ML cannot convert) and `convert_tflite.py` (litert-torch; CodeFormer's one-hot codebook
scatter replaced by the equivalent embedding lookup at conversion time). Core ML CodeFormer against PyTorch on real
aligned faces: mean difference 1.0–1.6 of 255; TFLite matches PyTorch to 1e-5. Sizes: general-x4v3 2.4 MB (Core ML) /
4.7 MB (TFLite); CodeFormer 181 MB (Core ML fp16) / 377 MB (TFLite fp32).

Timings with random inputs, harnesses in `phone/` (run from a scratch build only; not in the app):
`EnhanceBenchmarkTests.swift` (LightlyTests on the iPhone) and `EnhanceBench.kt` (debug launch hook on Android, LiteRT
with the app's threaded XNNPACK delegate). Median of repeated runs after one warm-up.

| Phone | general-x4v3, one 256 px tile | CodeFormer 0.8, one 512 px face | Peak memory with CodeFormer |
|---|---|---|---|
| iPhone SE 3 (A15), Core ML all units (Neural Engine) | 0.02 s (load 1.2 s) | **0.17 s** (load 8.1 s, first run) | ~145 MB |
| iPhone SE 3, CPU + GPU | 0.11 s | 0.68 s | ~450 MB |
| iPhone 11 Pro Max (A13), all units | 0.11 s | **crashes the app** (every run) | – |
| iPhone 11 Pro Max, CPU + GPU | 0.34 s | 2.4 s | ~590 MB |
| Nothing A069, XNNPACK fp16, 4 threads | 1.9 s | 9.3 s | ~1.5 GB PSS |
| Nothing A069, XNNPACK fp32 | 4.0 s | 21.5 s | ~1.9 GB PSS |

A 1200 px photo is about 20 tiles of 256 px, so the photo pass alone is ~0.4 s on the SE 3, ~2–7 s on the 11 Pro Max and
~40 s on the A069.

Conclusions:
- iOS on A14/A15 and later: CodeFormer 0.8 plus general-x4v3 is practical (well under a second per face).
- iPhone 11 Pro Max (A13): CodeFormer must run on CPU + GPU (the Neural Engine path crashes), 2.4 s per face, ~590 MB.
- Android on the A069: too slow and too large as is. Options: LiteRT GPU delegate, fp16/int8 weights, a smaller face
  model (GPEN-256 or GFPGAN's lighter variants), or a lower tile resolution for the photo pass.
- App size: CodeFormer adds ~180 MB on iOS (fp16) and ~190–380 MB on Android; an on-demand download would avoid
  doubling the app.

### LiteRT GPU delegate on the A069 (2026-11-13)

`EnhanceBench.kt` with `GpuDelegate` (litert-gpu 1.4.2, scratch build only):

| Model | XNNPACK fp16 | GPU fp16 | GPU fp32 |
|---|---|---|---|
| general-x4v3, 256 px tile | 1.9 s, ~750 MB | **0.56 s, ~180 MB** | 1.4 s |
| CodeFormer 0.8, 512 px face | **9.3 s**, ~1.5 GB | 30 s, ~1.4 GB (load 16 s) | 31 s |

The GPU takes all of general-x4v3 (photo pass ~11 s for 1200 px) but only 1,252 of CodeFormer's 2,245 operations,
leaving two partitions that bounce between GPU and CPU, so CodeFormer is three times slower than on XNNPACK. Best
current Android split: general-x4v3 on the GPU, CodeFormer on XNNPACK fp16. To get CodeFormer onto the GPU, the
unsupported operations (likely in its transformer and codebook lookup) would need rewriting or a lighter face model.

## Step 1d: making CodeFormer faster on Android (2026-11-13)

Owner: keep CodeFormer's quality, only make it faster. Result: **4.2 s per face on the A069, down from 9.3 s**, with the
original model's output (mean 0.6–1.7 of 255 from PyTorch on five real faces, the same order as Core ML fp16 on iOS).

| A069, one aligned 512 px face | Time | Notes |
|---|---|---|
| Original, XNNPACK fp16 (step 1c) | 9.3 s | CPU only |
| Original, GPU fp16 (step 1c) | 30 s | GPU took 1,252 of 2,245 ops |
| **Split, encoder + decoder on the GPU fp16, transformer on the CPU** | **4.2 s** | encoder 1.3 s, transformer 1.0 s, decoder 1.9 s; ~1.8 GB PSS |
| Split, model load | 42 s first time, 4.3 s after | GPU kernel cache (`setSerializationParams`), cache files on disk |

How (`codeformer_split.py`, `codeformer_gpu.py`; `convert_tflite.py codeformer-split`):
- CodeFormer is 800 GFLOPs per face, almost all in the encoder and decoder convolutions at 32–512 px. The 16x16 token
  transformer, topk and codebook lookup are ~2 %, so they run on the CPU as the original code (real topk, no
  approximation). Chained on the Mac the three TFLite parts match the original CodeFormer to 0.002 of 255.
- The LiteRT GPU delegate on the A069 (Adreno 710) gave wrong numbers for parts of the original graph, found by cutting
  the model into stages and comparing GPU (fp32) with the phone's CPU on a real face (`convert_gpu_probes.py`,
  `phone/EnhanceBench.kt` probes mode). Rewritten with the same maths for the GPU parts:
  - GroupNorm: decoder activations reach ~39,000, so its squares overflowed fp16 (all-NaN output); it is now scaled
    by the tensor's maximum (eps scaled with it) with staged spatial means, and no full-size reshape.
  - VQGAN attention blocks: `reshape-then-transpose @ B` and `A @ B` products came out wrong on the GPU (errors as big
    as the values); every product is now `A @ B^T` on channels-last rows. Each fix was checked on the phone.
- A first single-model attempt (sharpened-softmax codebook, `check_gpu_codebook.py`) measured 2.4 s but its output was
  all NaN on the phone, so that figure is void; its transformer could not be made GPU-correct (see `codeformer_gpu.py`).

Real-face check (`export_phone_faces.py` → phone → `compare_phone_faces.py android-split16`): black-and-white family and
group, sepia portrait, colour portrait and the painting; the phone column matches PyTorch by eye.

iOS: the same GroupNorm rewrite in Core ML was slower (SE 3 0.87 s vs 0.69 s, 11 Pro Max 2.59 s vs 2.33 s, CPU + GPU)
and its fp16 output was wrong (26–41 of 255), so iOS keeps the step 1c model. The rewritten model did run on the 11 Pro
Max Neural Engine without the crash (2.59 s), no faster than its GPU.

Open: the GPU kernel cache is a file the size of the model (~350 MB for the single model; split not yet measured) and the
first load takes ~42 s. The CPU transformer stays the original code at full precision: the owner keeps quality over
a ~1 s gain (2026-11-13).

## Step 1e: colour from the original (2026-11-13)

CodeFormer repaints colour along with detail: on sepia prints it adds blue eyes, pink eyelids and red lips (its own
black-and-white check only catches pure grey). A sepia-or-colour switch is unreliable: measured hue spread puts a sepia
print (4.8) between warm colour portraits (4.3–4.6). Old photos lose detail, not colour, so every restored face now keeps
CodeFormer's lightness (Lab L) and takes its colour (a, b) from the original aligned face, smoothed with a guided filter
steered by the restored lightness so colour follows the restored lips, eyes and hair (`colour_from_original.py`).

Checked on five toned prints and four colour photos (`run_e_colour.py`, sheets in `outputs/colour/`), and through the
full pipeline (`run_d_real.py faces-colour`):
- toned: invented colours are gone (green-blue eyes back to the print's brown, mauve lips back to neutral) with the same
  restored detail; mean colour shift from the original falls from 1.0–1.9 to 0.3–0.5 (Lab a/b, blurred).
- colour: real blue eyes, red lips, skin and teeth keep the original colour; no visible loss against CodeFormer alone.
- Cost on the phone: one Lab conversion and four box filters per 512 px face, no model.

## Step 1f: leaving paintings and drawings alone (in progress, 2026-11-13)

CodeFormer turns painted faces photographic, so Enhance should skip paintings, drawings and prints. Test set
(`fetch_art_test_set.py`, The Met Open Access, CC0, sources in `art-test/SOURCES.csv`, images git-ignored): 70 portrait
paintings and miniatures, 20 drawings and prints, 56 old photographs (daguerreotypes, tintypes, cartes de visite, cabinet
cards, many shot in their cases or mounts), plus the Unsplash real photos and `experiments/test-photos`. 124 images have a
face (eyes at least 20 px apart at 1200 px): 81 art, 43 photos.

| Signal | Art caught | Photos wrongly skipped | Notes |
|---|---|---|---|
| CodeFormer's own confidence (top code probability, `run_f_art.py`) | – | – | AUC 0.68: painted faces score barely lower; not usable |
| Apple Vision `VNClassifyImageRequest`, whole image, max(painting, drawing, illustrations, sketch) ≥ 0.2 | 71/81 | 4/43 | gilt cases and mounts read as "painting"; iOS only |
| Apple Vision on the aligned face crop ≥ 0.2 | 30/81 | 1/43 | the face alone loses the brushwork cues |

Neither is good enough, and Vision has no Android equivalent. Next: a small cross-platform photo-or-art classifier
(needs a backbone and a separate training set; owner approval pending).
