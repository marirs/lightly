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

## Status

Weights downloaded. Not yet run: the network code (Real-ESRGAN/BasicSR, GFPGAN, CodeFormer, GPEN repositories) and
the face detector the face-restore models need are not installed yet.
