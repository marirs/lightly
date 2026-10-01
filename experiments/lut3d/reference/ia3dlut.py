"""
Faithful, dependency-light port of Image-Adaptive 3D LUT inference (Zeng et al., TPAMI 2022).

Reference revision: https://github.com/HuiZeng/Image-Adaptive-3DLUT
    commit b491f6df64a588864739a157db271e5c848e1805 (2022-11-26)
    weights: pretrained_models/sRGB/{classifier.pth,LUTs.pth}  (paired / FiveK expert C)

Why a port instead of running the repo directly: the repo pins torch 0.4.1 and needs a compiled
C/CUDA trilinear extension. We re-implement the two pieces that matter for inference:

  1. Classifier (CNN, 270,083 params) -> 3 fusion weights from a 256x256 view of the image.
  2. Trilinear LUT application, matching trilinear_cpp/src/trilinear.cpp bit-for-bit in its
     indexing conventions (including the `binsize = 1.0001 / (dim - 1)` quirk).

Contract facts established from the reference code (not from the paper):
  * Input: 8-bit sRGB-encoded RGB, converted with torchvision `to_tensor` -> float in [0, 1].
    No mean/std normalisation. Values are gamma-encoded (NOT linear light).
  * Classifier resizes the WHOLE image (aspect ratio ignored) to 256x256 with nn.Upsample bilinear,
    no antialiasing. With torch 0.4.1 the default is align_corners=False.
  * Fused LUT = w0*LUT0 + w1*LUT1 + w2*LUT2, weights are raw linear outputs (no softmax).
  * LUT tensor shape [3, 33, 33, 33] indexed as LUT[channel, b, g, r]; flat index r + g*33 + b*33^2.
    This is the same memory order as Core Image's CIColorCube (red varies fastest).
  * LUT application happens in the same sRGB-encoded domain; result clamped to [0,1] on save.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

LUT_DIM = 33
REFERENCE_BINSIZE_NUMERATOR = 1.0001  # reproduced from trilinear.cpp; see module docstring


def _discriminator_block(in_filters: int, out_filters: int, normalization: bool = False):
    layers = [nn.Conv2d(in_filters, out_filters, 3, stride=2, padding=1), nn.LeakyReLU(0.2)]
    if normalization:
        layers.append(nn.InstanceNorm2d(out_filters, affine=True))
    return layers


class ReferenceClassifier(nn.Module):
    """Layer-for-layer copy of models.Classifier so the original state_dict loads unchanged."""

    def __init__(self, include_internal_resize: bool, align_corners: bool = False):
        super().__init__()
        resize = (
            nn.Upsample(size=(256, 256), mode="bilinear", align_corners=align_corners)
            if include_internal_resize
            else nn.Identity()
        )
        self.model = nn.Sequential(
            resize,
            nn.Conv2d(3, 16, 3, stride=2, padding=1),
            nn.LeakyReLU(0.2),
            nn.InstanceNorm2d(16, affine=True),
            *_discriminator_block(16, 32, normalization=True),
            *_discriminator_block(32, 64, normalization=True),
            *_discriminator_block(64, 128, normalization=True),
            *_discriminator_block(128, 128),
            nn.Dropout(p=0.5),
            nn.Conv2d(128, 3, 8, padding=0),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.model(x).reshape(-1, 3)


@dataclass
class ReferenceModel:
    classifier_full_input: ReferenceClassifier  # includes the reference's internal Upsample
    classifier_fixed_256: ReferenceClassifier  # expects caller-prepared 1x3x256x256 (deployment form)
    basis_luts: np.ndarray  # float32 [3 basis, 3 channels, b, g, r]


def load_reference_model(weights_dir: str, align_corners: bool = False) -> ReferenceModel:
    classifier_state = torch.load(os.path.join(weights_dir, "classifier.pth"), map_location="cpu", weights_only=False)
    lut_state = torch.load(os.path.join(weights_dir, "LUTs.pth"), map_location="cpu", weights_only=False)

    full = ReferenceClassifier(include_internal_resize=True, align_corners=align_corners)
    fixed = ReferenceClassifier(include_internal_resize=False)
    for classifier in (full, fixed):
        # strict=True: any layer-numbering drift from models.Classifier fails loudly here.
        classifier.load_state_dict(classifier_state, strict=True)
        classifier.eval()

    basis = np.stack([lut_state[str(i)]["LUT"].numpy() for i in range(3)]).astype(np.float32)
    assert basis.shape == (3, 3, LUT_DIM, LUT_DIM, LUT_DIM), basis.shape
    return ReferenceModel(full, fixed, basis)


def to_tensor_srgb(rgb_uint8: np.ndarray) -> torch.Tensor:
    """HxWx3 uint8 sRGB -> 1x3xHxW float in [0,1] (torchvision to_tensor semantics)."""
    return torch.from_numpy(np.array(rgb_uint8, copy=True)).permute(2, 0, 1).float().div(255.0).unsqueeze(0)


def prepare_256_antialiased(rgb_uint8: np.ndarray) -> np.ndarray:
    """Deployment preprocessing proposal: area/antialiased resize of the whole frame to 256x256.

    Aspect ratio is deliberately ignored, because the reference classifier saw squashed frames.
    Antialiasing makes the result independent of source resolution (reference bilinear is not).
    """
    t = to_tensor_srgb(rgb_uint8)
    return F.interpolate(t, size=(256, 256), mode="bilinear", align_corners=False, antialias=True)[0].numpy()


@torch.no_grad()
def predict_weights_reference(model: ReferenceModel, rgb_uint8: np.ndarray) -> np.ndarray:
    return model.classifier_full_input(to_tensor_srgb(rgb_uint8))[0].numpy()


@torch.no_grad()
def predict_weights_from_256(model: ReferenceModel, chw_256: np.ndarray) -> np.ndarray:
    return model.classifier_fixed_256(torch.from_numpy(chw_256).unsqueeze(0))[0].numpy()


def fuse_luts(basis_luts: np.ndarray, weights: np.ndarray) -> np.ndarray:
    """[3,3,D,D,D] x [3] -> [3,D,D,D]."""
    return np.tensordot(weights.astype(np.float32), basis_luts, axes=(0, 0)).astype(np.float32)


def identity_lut(dim: int = LUT_DIM) -> np.ndarray:
    """Exact identity in the reference layout LUT[c, b, g, r]."""
    ramp = np.linspace(0.0, 1.0, dim, dtype=np.float32)
    b, g, r = np.meshgrid(ramp, ramp, ramp, indexing="ij")
    return np.stack([r, g, b]).astype(np.float32)


def apply_lut_reference(lut: np.ndarray, rgb01: np.ndarray, binsize_numerator: float = REFERENCE_BINSIZE_NUMERATOR) -> np.ndarray:
    """Trilinear application matching trilinear.cpp. rgb01: HxWx3 float32 in [0,1]. Returns unclamped float32."""
    dim = lut.shape[-1]
    binsize = binsize_numerator / (dim - 1)
    r, g, b = rgb01[..., 0], rgb01[..., 1], rgb01[..., 2]
    r_id = np.floor(r / binsize).astype(np.int64)
    g_id = np.floor(g / binsize).astype(np.int64)
    b_id = np.floor(b / binsize).astype(np.int64)
    # With numerator 1.0 an input of exactly 1.0 would index dim; clamp so the cell stays valid.
    r_id = np.clip(r_id, 0, dim - 2)
    g_id = np.clip(g_id, 0, dim - 2)
    b_id = np.clip(b_id, 0, dim - 2)
    r_d = r / binsize - r_id
    g_d = g / binsize - g_id
    b_d = b / binsize - b_id

    flat = lut.reshape(3, -1)
    out = np.zeros(rgb01.shape, dtype=np.float32)
    for dr in (0, 1):
        wr = r_d if dr else 1 - r_d
        for dg in (0, 1):
            wg = g_d if dg else 1 - g_d
            for db in (0, 1):
                wb = b_d if db else 1 - b_d
                idx = (r_id + dr) + (g_id + dg) * dim + (b_id + db) * dim * dim
                w = (wr * wg * wb).astype(np.float32)
                for c in range(3):
                    out[..., c] += w * flat[c][idx]
    return out


def blend_toward_identity(lut: np.ndarray, strength: float) -> np.ndarray:
    """Auto strength control: 0 = identity (original), 1 = model output. Linear in LUT space."""
    return identity_lut(lut.shape[-1]) + strength * (lut - identity_lut(lut.shape[-1]))


def to_uint8(rgb01: np.ndarray) -> np.ndarray:
    """Same rounding as demo_eval.py: x*255 + 0.5, clamp, truncate."""
    return np.clip(rgb01 * 255.0 + 0.5, 0, 255).astype(np.uint8)


def export_lut_rgba_float32(lut: np.ndarray) -> bytes:
    """LUT[c,b,g,r] -> interleaved RGBA float32, red fastest (CIColorCube / GL 3D texture layout)."""
    dim = lut.shape[-1]
    rgba = np.ones((dim, dim, dim, 4), dtype=np.float32)
    rgba[..., 0:3] = np.moveaxis(lut, 0, -1)
    return rgba.tobytes()


def endpoint_guardrail(lut: np.ndarray) -> np.ndarray:
    """EXPERIMENTAL post-model guardrail (not part of the upstream method).

    The pretrained FiveK model often maps black below 0 (crushing shadows after clamping) and white below 1
    (greying skies). Rescale every output channel affinely so that the LUT's black corner maps to
    max(black, 0)->0 and white corner to min(white, 1)->1. Only endpoints that are out of range are moved;
    a LUT whose endpoints are already within [0,1] and white >= 1 is untouched.
    """
    out = lut.copy()
    for c in range(3):
        black = float(lut[c, 0, 0, 0])
        white = float(lut[c, -1, -1, -1])
        lo = min(black, 0.0)
        hi = white if white < 1.0 else 1.0
        if lo < 0.0 or white < 1.0:
            out[c] = (lut[c] - lo) / (hi - lo)
    return out


def warm_hue_protection(lut: np.ndarray, max_hue_shift_deg: float = 4.0, chroma_gain_range=(0.92, 1.12)) -> np.ndarray:
    """EXPERIMENTAL LUT-space guardrail: limit hue rotation and chroma change for warm hues (skin, sunsets).

    Operates per LUT node (input colour -> output colour) in CIELAB/LCh. Nodes whose INPUT hue lies in the
    warm band (~15..80 deg, which contains human skin of all tones and sunset oranges) with moderate chroma
    get their output hue pulled to within +/-max_hue_shift_deg of the input hue and their chroma gain
    clamped. Lightness changes are kept. Zero runtime cost: it edits the 33^3 LUT once per photo.
    Limitation: it is still global - any warm-hued object (wood, sand) is protected the same way.
    """
    from skimage import color as skcolor
    dim = lut.shape[-1]
    ident = np.moveaxis(identity_lut(dim), 0, -1).reshape(-1, 3)
    out = np.moveaxis(lut, 0, -1).reshape(-1, 3)
    lab_in = skcolor.rgb2lab(np.clip(ident, 0, 1)[None])[0]
    lab_out = skcolor.rgb2lab(np.clip(out, 0, 1)[None])[0]
    h_in = np.degrees(np.arctan2(lab_in[:, 2], lab_in[:, 1])) % 360
    c_in = np.hypot(lab_in[:, 1], lab_in[:, 2])
    h_out = np.degrees(np.arctan2(lab_out[:, 2], lab_out[:, 1])) % 360
    c_out = np.hypot(lab_out[:, 1], lab_out[:, 2])

    def band(x, lo, hi, soft):  # smooth 0..1 membership
        return np.clip((x - (lo - soft)) / soft, 0, 1) * np.clip(((hi + soft) - x) / soft, 0, 1)

    weight = band(h_in, 15, 80, 10) * band(c_in, 6, 80, 4) * band(lab_in[:, 0], 12, 95, 6)
    dh = ((h_out - h_in + 180) % 360) - 180
    h_new = h_in + np.clip(dh, -max_hue_shift_deg, max_hue_shift_deg)
    gain = np.where(c_in > 1e-3, c_out / np.maximum(c_in, 1e-3), 1.0)
    c_new = c_in * np.clip(gain, *chroma_gain_range)
    lab_new = np.stack([lab_out[:, 0], c_new * np.cos(np.radians(h_new)), c_new * np.sin(np.radians(h_new))], -1)
    rgb_new = skcolor.lab2rgb(lab_new[None])[0]
    # lab2rgb clips to [0,1]; keep the original (possibly out-of-range) value where the node is unprotected.
    blended = out + weight[:, None] * (rgb_new - np.clip(out, 0, 1))
    return np.moveaxis(blended.reshape(dim, dim, dim, 3), -1, 0).astype(np.float32)


def local_exposure_gain(rgb01: np.ndarray, strength: float = 0.5, radius_frac: float = 0.04) -> np.ndarray:
    """EXPERIMENTAL 'smallest local addition': base/detail split on log luminance (guided-filter base,
    as in upstream local_tone_mapping/wlsTonemap.m) and compress the base layer around its median.
    Computed at low resolution (<=512 px) and upsampled bilinearly as a smooth gain map, then applied
    before the global LUT. Returns the gain-adjusted image (float, unclamped)."""
    import cv2
    h, w = rgb01.shape[:2]
    s = 512 / max(h, w)
    small = cv2.resize(rgb01, (max(1, round(w * s)), max(1, round(h * s))), interpolation=cv2.INTER_AREA)
    lum = np.maximum(small @ np.array([0.2126, 0.7152, 0.0722], np.float32), 1e-4)
    log_l = np.log(lum)
    r = max(2, int(radius_frac * 512))
    base = cv2.ximgproc.guidedFilter(log_l.astype(np.float32), log_l.astype(np.float32), r, 0.02) if hasattr(cv2, "ximgproc") \
        else cv2.bilateralFilter(log_l.astype(np.float32), 2 * r + 1, 0.4, r)
    med = np.median(base)
    gain_log = -strength * (base - med)  # lift below-median regions, pull above-median regions down
    gain_log = np.clip(gain_log, np.log(0.75), np.log(2.0))
    gain = np.exp(cv2.resize(gain_log.astype(np.float32), (w, h), interpolation=cv2.INTER_LINEAR))
    # Apply in linear light so the gain behaves like exposure, then re-encode to sRGB.
    lin = np.where(rgb01 <= 0.04045, rgb01 / 12.92, ((rgb01 + 0.055) / 1.055) ** 2.4)
    lin = lin * gain[..., None]
    lin = lin / max(1.0, float(np.percentile(lin, 99.9)))  # avoid pushing new clipping
    return np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.power(np.maximum(lin, 0), 1 / 2.4) - 0.055).astype(np.float32)
