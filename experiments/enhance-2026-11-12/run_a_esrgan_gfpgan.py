"""Enhance step 1a: synthetic "old, low-resolution" inputs and the pip-packaged candidates.

Each test photo is degraded (1/4 size, slight blur, JPEG quality 35), then restored x4 by:
  - bicubic (baseline)
  - Real-ESRGAN general x4 v3 (mobile-sized upscaler)
  - Real-ESRGAN x4plus (quality upscaler)
  - GFPGAN v1.4 faces pasted onto the general-x4v3 background (so only the face model differs from CodeFormer/GPEN)
The original photo is the ground truth. Writes outputs/<photo>/<method>.png, outputs/bg/<photo>.png (the shared
background for the face models, used by run_b/run_c) and outputs/timings-a.json.

Run: .venv/bin/python run_a_esrgan_gfpgan.py
"""
import json
import time
from pathlib import Path

import cv2
import numpy as np
import torch
from basicsr.archs.rrdbnet_arch import RRDBNet
from gfpgan import GFPGANer
from realesrgan import RealESRGANer
from realesrgan.archs.srvgg_arch import SRVGGNetCompact

HERE = Path(__file__).resolve().parent
PHOTOS = HERE.parent / "test-photos"
WEIGHTS = HERE / "weights"
OUT = HERE / "outputs"
TEST_PHOTOS = [
    "profile_colour_woman_01.jpg",
    "profile_beard_man_01.jpg",
    "profile_bw_boy_01.jpg",
    "group_three_01.jpg",
    "glasses_pair_mixed_01.jpg",
    "profile_bw_woman_hair_01.jpg",
]
SCALE = 4
DEVICE = torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def degrade(original: np.ndarray) -> np.ndarray:
    """A stand-in for an old, small, compressed photo: 1/4 size, slight blur, heavy JPEG."""
    height, width = original.shape[:2]
    small = cv2.resize(original, (width // SCALE, height // SCALE), interpolation=cv2.INTER_AREA)
    small = cv2.GaussianBlur(small, (3, 3), 0.8)
    ok, encoded = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 35])
    assert ok
    return cv2.imdecode(encoded, cv2.IMREAD_COLOR)


def psnr(reference: np.ndarray, candidate: np.ndarray) -> float:
    candidate = cv2.resize(candidate, (reference.shape[1], reference.shape[0]), interpolation=cv2.INTER_CUBIC)
    mse = np.mean((reference.astype(np.float64) - candidate.astype(np.float64)) ** 2)
    return float(10 * np.log10(255.0**2 / mse)) if mse > 0 else 99.0


def make_upsamplers() -> dict:
    general = RealESRGANer(
        scale=4,
        model_path=str(WEIGHTS / "realesr-general-x4v3/realesr-general-x4v3.pth"),
        model=SRVGGNetCompact(num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4, act_type="prelu"),
        tile=0, half=False, device=DEVICE,
    )
    x4plus = RealESRGANer(
        scale=4,
        model_path=str(WEIGHTS / "realesrgan-x4plus/RealESRGAN_x4plus.pth"),
        model=RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=4),
        tile=256, half=False, device=DEVICE,
    )
    return {"general-x4v3": general, "x4plus": x4plus}


def timed(function):
    if DEVICE.type == "mps":
        torch.mps.synchronize()
    start = time.perf_counter()
    result = function()
    if DEVICE.type == "mps":
        torch.mps.synchronize()
    return result, time.perf_counter() - start


def main() -> None:
    upsamplers = make_upsamplers()
    gfpgan = GFPGANer(model_path=str(WEIGHTS / "gfpgan-v1.4/GFPGANv1.4.pth"), upscale=SCALE, arch="clean",
                      channel_multiplier=2, bg_upsampler=upsamplers["general-x4v3"], device=DEVICE)
    timings, scores = {}, {}
    (OUT / "bg").mkdir(parents=True, exist_ok=True)
    for name in TEST_PHOTOS:
        stem = Path(name).stem
        folder = OUT / stem
        folder.mkdir(parents=True, exist_ok=True)
        original = cv2.imread(str(PHOTOS / name), cv2.IMREAD_COLOR)
        low = degrade(original)
        cv2.imwrite(str(folder / "0-original.png"), original)
        cv2.imwrite(str(folder / "1-degraded.png"), low)
        results = {"2-bicubic": cv2.resize(low, (low.shape[1] * SCALE, low.shape[0] * SCALE), interpolation=cv2.INTER_CUBIC)}
        timings[stem] = {"input": f"{low.shape[1]}x{low.shape[0]}"}
        for label, upsampler in upsamplers.items():
            (output, _), seconds = timed(lambda: upsampler.enhance(low, outscale=SCALE))
            results[f"3-{label}"] = output
            timings[stem][label] = round(seconds, 2)
        cv2.imwrite(str(OUT / "bg" / f"{stem}.png"), results["3-general-x4v3"])
        (_, _, restored), seconds = timed(lambda: gfpgan.enhance(low, has_aligned=False, only_center_face=False, paste_back=True, weight=0.5))
        results["4-gfpgan-v1.4"] = restored
        timings[stem]["gfpgan-v1.4 (faces + bg)"] = round(seconds, 2)
        cv2.imwrite(str(folder / "1-degraded-input.png"), low)
        scores[stem] = {}
        for label, image in results.items():
            cv2.imwrite(str(folder / f"{label}.png"), image)
            scores[stem][label] = round(psnr(original, image), 2)
        print(stem, timings[stem], scores[stem], flush=True)
    (OUT / "timings-a.json").write_text(json.dumps({"device": str(DEVICE), "seconds": timings, "psnr_db": scores}, indent=2))


if __name__ == "__main__":
    main()
