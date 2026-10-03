"""Convert the commercially usable candidates to on-device formats and check parity.

Outputs (all git-ignored under models/exported/):
  lama_512_fp16.mlpackage, lama_512_fp32.mlpackage, lama_512.onnx
  migan_512_fp16.mlpackage, migan_512_fp32.mlpackage, migan_512.onnx
  conversion_report.json (sizes, parity vs PyTorch, sha256)

Every exported graph has the same app-facing signature so the two platforms can share one
pre/post-processing path:
  inputs : image float32 [1,3,512,512] in 0..1 (sRGB), mask float32 [1,1,512,512] (1 = remove)
  output : result float32 [1,3,512,512] in 0..1 (model fill; paste-back happens outside)

LaMa's Fast Fourier Convolutions use torch.fft.rfftn/irfftn. Neither Core ML nor TFLite/NNAPI
has a dependable 2-D real FFT op, so for export the FFTs are replaced by exact DFT matrix
products (the spectral grid is only 64x64 at a 512 input, so this costs ~2% of the FLOPs).
The replacement is verified numerically against torch.fft below.
"""
from __future__ import annotations

import hashlib
import json
import math
import sys
import time
from pathlib import Path

import numpy as np
import torch

import inpaint_lib as lib

EXPORT_DIR = lib.MODELS_DIR / "exported"
SIDE = lib.MODEL_INPUT_SIDE


# --------------------------------------------------------------------------------------------
# Exact DFT-by-matmul replacement for LaMa's FourierUnit (fixed spatial size)
# --------------------------------------------------------------------------------------------


def _dft_matrices(height: int, width: int):
    half_width = width // 2 + 1
    h = torch.arange(height, dtype=torch.float64)
    w = torch.arange(width, dtype=torch.float64)
    k_w = torch.arange(half_width, dtype=torch.float64)
    angle_h = 2 * math.pi * torch.outer(h, h) / height  # symmetric (k1, h)
    angle_w = 2 * math.pi * torch.outer(w, k_w) / width  # (w, k2)
    cos_h, sin_h = torch.cos(angle_h), torch.sin(angle_h)
    cos_w, sin_w = torch.cos(angle_w), torch.sin(angle_w)
    # Inverse real transform along W: bins 1..W/2-1 appear twice in the full spectrum.
    hermitian_weight = torch.full((half_width,), 2.0, dtype=torch.float64)
    hermitian_weight[0] = 1.0
    if width % 2 == 0:
        hermitian_weight[-1] = 1.0
    inv_cos_w = (cos_w * hermitian_weight).T  # (k2, w)
    inv_sin_w = (sin_w * hermitian_weight).T
    scale = 1.0 / math.sqrt(height * width)  # norm="ortho" on both directions
    # .contiguous(): litert-torch serialises non-contiguous constants (e.g. a .T view) with the
    # wrong strides, which silently corrupted the inverse transform in the first .tflite export.
    as_f32 = lambda tensor: tensor.to(torch.float32).contiguous()
    return {
        "cos_h": as_f32(cos_h), "sin_h": as_f32(sin_h),
        "cos_w": as_f32(cos_w * scale), "sin_w": as_f32(sin_w * scale),
        "inv_cos_w": as_f32(inv_cos_w * scale), "inv_sin_w": as_f32(inv_sin_w * scale),
    }


def rfft2_ortho_matmul(x: torch.Tensor, mats) -> tuple[torch.Tensor, torch.Tensor]:
    real_w = torch.matmul(x, mats["cos_w"])  # (B,C,H,W2)
    imag_w = -torch.matmul(x, mats["sin_w"])
    real = torch.matmul(mats["cos_h"], real_w) + torch.matmul(mats["sin_h"], imag_w)
    imag = torch.matmul(mats["cos_h"], imag_w) - torch.matmul(mats["sin_h"], real_w)
    return real, imag


def irfft2_ortho_matmul(real: torch.Tensor, imag: torch.Tensor, mats) -> torch.Tensor:
    real_h = torch.matmul(mats["cos_h"], real) - torch.matmul(mats["sin_h"], imag)
    imag_h = torch.matmul(mats["sin_h"], real) + torch.matmul(mats["cos_h"], imag)
    return torch.matmul(real_h, mats["inv_cos_w"]) - torch.matmul(imag_h, mats["inv_sin_w"])


def exportable_fourier_unit_forward(self, x):
    """Drop-in for FourierUnit.forward (big-lama config: 2-D, no SE, no pos-enc, no rescale)."""
    assert self.spatial_scale_factor is None and not self.spectral_pos_encoding
    assert not self.use_se and not self.ffc3d and self.fft_norm == "ortho"
    # The DFT matrices are built on the first (eager, un-traced) call and reused while tracing;
    # avoiding int(shape) inside the traced graph keeps Core ML from seeing dynamic casts.
    if torch.jit.is_tracing():
        assert hasattr(self, "_dft_mats"), "run one eager forward before tracing"
    else:
        cache_key = tuple(int(size) for size in x.shape[-2:])
        if getattr(self, "_dft_cache_key", None) != cache_key:
            self._dft_mats = _dft_matrices(*cache_key)
            self._dft_cache_key = cache_key
    real, imag = rfft2_ortho_matmul(x, self._dft_mats)
    # Interleave as [c0.re, c0.im, c1.re, ...] exactly like the upstream stack/permute/view.
    spectrum = torch.stack((real, imag), dim=2).flatten(1, 2)
    spectrum = self.relu(self.bn(self.conv_layer(spectrum)))
    spectrum = spectrum.unflatten(1, (-1, 2))
    return irfft2_ortho_matmul(spectrum[:, :, 0], spectrum[:, :, 1], self._dft_mats)


class CroppedTransposedConv(torch.nn.Module):
    """ConvTranspose2d(k=3, s=2, p=1, output_padding=1) rewritten as padding=0 + crop.

    LiteRT's converter cannot legalise transposed convs with output_padding. With padding=0 the
    full output is 2H+1; padding=1 drops row/col 0 and 2H, output_padding=1 re-adds row/col 2H,
    so the original equals full[..., 1:, 1:]. Same weights, exact same maths.
    """

    def __init__(self, original: torch.nn.ConvTranspose2d):
        super().__init__()
        assert original.kernel_size == (3, 3) and original.stride == (2, 2)
        assert original.padding == (1, 1) and original.output_padding == (1, 1)
        self.full = torch.nn.ConvTranspose2d(original.in_channels, original.out_channels, 3, 2, 0,
                                             bias=original.bias is not None)
        self.full.load_state_dict(original.state_dict())

    def forward(self, x):
        return self.full(x)[..., 1:, 1:]


def replace_output_padded_transposed_convs(module: torch.nn.Module) -> int:
    replaced = 0
    for child_name, child in module.named_children():
        if isinstance(child, torch.nn.ConvTranspose2d) and child.output_padding == (1, 1):
            setattr(module, child_name, CroppedTransposedConv(child))
            replaced += 1
        else:
            replaced += replace_output_padded_transposed_convs(child)
    return replaced


def patch_lama_for_export() -> None:
    from saicinpainting.training.modules.ffc import FourierUnit

    FourierUnit.forward = exportable_fourier_unit_forward


# --------------------------------------------------------------------------------------------
# Uniform app-facing wrappers
# --------------------------------------------------------------------------------------------


class LamaExportWrapper(torch.nn.Module):
    def __init__(self, generator):
        super().__init__()
        self.generator = generator

    def forward(self, image, mask):
        return self.generator(torch.cat([image * (1 - mask), mask], dim=1))


class MiganExportWrapper(torch.nn.Module):
    def __init__(self, generator):
        super().__init__()
        self.generator = generator

    def forward(self, image, mask):
        known = 1 - mask
        network_input = torch.cat([known - 0.5, (image * 2 - 1) * known], dim=1)
        return (self.generator(network_input) * 0.5 + 0.5).clamp(0, 1)


def sample_inputs():
    """A real crop + brush (case c6) so parity is measured on photographic content, not noise."""
    case = [case for case in lib.load_cases() if case.case_id == "c6_textured_background"][0]
    image = lib.load_rgb(case.photo_path)
    mask = lib.rasterise_mask(case, image.shape[1], image.shape[0])
    window = lib.context_window(mask)
    crop = image[window.y0:window.y0 + window.side, window.x0:window.x0 + window.side]
    mask_crop = mask[window.y0:window.y0 + window.side, window.x0:window.x0 + window.side]
    from PIL import Image

    crop = np.array(Image.fromarray(crop).resize((SIDE, SIDE), Image.BICUBIC))
    mask_crop = (np.array(Image.fromarray(mask_crop).resize((SIDE, SIDE), Image.BILINEAR)) > 0)
    image_tensor = torch.from_numpy(crop).permute(2, 0, 1)[None].float() / 255
    mask_tensor = torch.from_numpy(mask_crop.astype(np.float32))[None, None]
    return image_tensor, mask_tensor


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    files = sorted(p for p in path.rglob("*") if p.is_file()) if path.is_dir() else [path]
    for file_path in files:
        digest.update(file_path.read_bytes())
    return digest.hexdigest()


def size_mb(path: Path) -> float:
    files = [p for p in path.rglob("*") if p.is_file()] if path.is_dir() else [path]
    return round(sum(p.stat().st_size for p in files) / 1e6, 2)


def psnr_vs(reference: np.ndarray, candidate: np.ndarray) -> float:
    mse = float(np.mean((reference.astype(np.float64) - candidate.astype(np.float64)) ** 2))
    return float("inf") if mse == 0 else 10 * math.log10(1.0 / mse)


def convert_one(name: str, wrapper: torch.nn.Module, reference_output: np.ndarray, image, mask, report):
    import coremltools as ct
    import onnxruntime as ort

    traced = torch.jit.trace(wrapper, (image, mask), check_trace=False)
    entry = report.setdefault(name, {})
    for precision, compute_precision in (("fp16", ct.precision.FLOAT16), ("fp32", ct.precision.FLOAT32)):
        started = time.perf_counter()
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="image", shape=image.shape), ct.TensorType(name="mask", shape=mask.shape)],
            outputs=[ct.TensorType(name="result")],
            convert_to="mlprogram",
            compute_precision=compute_precision,
            minimum_deployment_target=ct.target.iOS17,
        )
        out_path = EXPORT_DIR / f"{name}_{SIDE}_{precision}.mlpackage"
        mlmodel.save(str(out_path))
        prediction = mlmodel.predict({"image": image.numpy(), "mask": mask.numpy()})["result"]
        entry[f"coreml_{precision}"] = {
            "path": str(out_path.relative_to(lib.EXPERIMENT_ROOT)),
            "size_mb": size_mb(out_path),
            "convert_s": round(time.perf_counter() - started, 1),
            "psnr_vs_pytorch_db": round(psnr_vs(reference_output, prediction), 2),
            "max_abs_diff": round(float(np.abs(reference_output - prediction).max()), 4),
            "sha256": sha256_of(out_path),
        }
        print(name, precision, entry[f"coreml_{precision}"], flush=True)

    onnx_path = EXPORT_DIR / f"{name}_{SIDE}.onnx"
    torch.onnx.export(wrapper, (image, mask), str(onnx_path), input_names=["image", "mask"],
                      output_names=["result"], opset_version=17, do_constant_folding=True, dynamo=False)
    session = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    onnx_output = session.run(None, {"image": image.numpy(), "mask": mask.numpy()})[0]
    entry["onnx_fp32"] = {
        "path": str(onnx_path.relative_to(lib.EXPERIMENT_ROOT)),
        "size_mb": size_mb(onnx_path),
        "opset": 17,
        "psnr_vs_pytorch_db": round(psnr_vs(reference_output, onnx_output), 2),
        "max_abs_diff": round(float(np.abs(reference_output - onnx_output).max()), 4),
        "sha256": sha256_of(onnx_path),
    }
    print(name, "onnx", entry["onnx_fp32"], flush=True)


def main() -> None:
    torch.set_num_threads(4)
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    targets = set(sys.argv[1:]) or {"lama", "migan"}
    report_path = EXPORT_DIR / "conversion_report.json"
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    image, mask = sample_inputs()

    if "lama" in targets:
        generator = lib.build_lama_generator()
        wrapper = LamaExportWrapper(generator).eval()
        with torch.no_grad():
            reference = wrapper(image, mask).numpy()
        patch_lama_for_export()
        with torch.no_grad():
            matmul_output = wrapper(image, mask).numpy()
        report.setdefault("lama", {})["dft_matmul_vs_torch_fft"] = {
            "max_abs_diff": float(np.abs(reference - matmul_output).max()),
            "psnr_db": round(psnr_vs(reference, matmul_output), 2),
        }
        print("lama dft-matmul parity", report["lama"]["dft_matmul_vs_torch_fft"], flush=True)
        report["lama"]["parameters_m"] = round(sum(p.numel() for p in generator.parameters()) / 1e6, 2)
        convert_one("lama", wrapper, reference, image, mask, report)

    if "migan" in targets:
        generator = lib.build_migan_generator(SIDE)
        wrapper = MiganExportWrapper(generator).eval()
        with torch.no_grad():
            reference = wrapper(image, mask).numpy()
        report.setdefault("migan", {})["parameters_m"] = round(sum(p.numel() for p in generator.parameters()) / 1e6, 2)
        convert_one("migan", wrapper, reference, image, mask, report)

    report_path.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
