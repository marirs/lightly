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

Provisional pick: general-x4v3 for the photo, GPEN-512 for faces (CodeFormer 0.8 as the alternative). Next: real old and
low-resolution photos, then Core ML / TFLite conversion and timing on the three review phones.
