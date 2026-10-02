"""Differentiable pieces of the ia3dlut deployment contract, for training.

Contract (spec.md section 4.6): fused LUT = sum_i w_i * B_i with 3 basis LUTs of 33^3, layout LUT[c, b, g, r],
applied with exact-grid trilinear interpolation (binsize 1/(dim-1)) in the sRGB-encoded domain.

`grid_sample(..., align_corners=True)` on a [N, 3, b, g, r] volume with grid coordinates (x=r, y=g, z=b)
mapped to [-1, 1] is exactly that interpolation; tests/test_training.py checks it against
ia3dlut.apply_lut_reference(binsize_numerator=1.0).

The TV / monotonicity regulariser re-implements upstream TV_3D (Image-Adaptive-3DLUT, Apache-2.0,
models.py at b491f6d): squared neighbour differences with doubled edge weights, plus ReLU of decreasing steps.
"""
from __future__ import annotations

import numpy as np
import torch
import torch.nn.functional as F
from skimage import color as skcolor

from .paths import ia3dlut as ia


def deployment_preprocess(images01: torch.Tensor) -> torch.Tensor:
    """[B,3,H,W] 8-bit-quantised sRGB in [0,1] -> [B,3,256,256]. Must stay identical to
    ia3dlut.prepare_256_antialiased (the pinned resize): bilinear, align_corners=False, antialias=True."""
    return F.interpolate(images01, size=(256, 256), mode="bilinear", align_corners=False, antialias=True)


def fuse_basis(weights: torch.Tensor, basis: torch.Tensor) -> torch.Tensor:
    """[B,3] x [3 basis, 3, D, D, D] -> [B, 3, D, D, D]; raw weights, no softmax (contract)."""
    return torch.einsum("nk,kcbgr->ncbgr", weights, basis)


def apply_lut_batch(luts: torch.Tensor, images01: torch.Tensor) -> torch.Tensor:
    """Per-sample exact-grid trilinear LUT application. luts [B,3,D,D,D], images [B,3,H,W] -> [B,3,H,W]."""
    batch, _, height, width = images01.shape
    grid = images01.clamp(0.0, 1.0).permute(0, 2, 3, 1) * 2.0 - 1.0  # (r, g, b) -> (x, y, z)
    grid = grid.reshape(batch, height, width, 1, 3)
    sampled = F.grid_sample(luts, grid, mode="bilinear", padding_mode="border", align_corners=True)
    return sampled.reshape(batch, 3, height, width)


def identity_basis_init(dim: int = ia.LUT_DIM) -> torch.Tensor:
    """Upstream sRGB initialisation: basis 0 = identity, bases 1 and 2 = zero."""
    basis = torch.zeros(3, 3, dim, dim, dim)
    basis[0] = torch.from_numpy(ia.identity_lut(dim))
    return basis


def _edge_weights(dim: int, axis: int) -> torch.Tensor:
    shape = [3, dim, dim, dim]
    shape[axis] = dim - 1
    weights = torch.ones(shape)
    index = [slice(None)] * 4
    for edge in (0, dim - 2):
        index[axis] = edge
        weights[tuple(index)] *= 2.0
    return weights


def tv_and_monotonicity(lut: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    """One basis LUT [3, b, g, r] -> (tv, monotonicity) as upstream TV_3D."""
    dim = lut.shape[-1]
    tv = lut.new_zeros(())
    mono = lut.new_zeros(())
    for axis in (3, 2, 1):  # r, g, b
        forward = lut.narrow(axis, 0, dim - 1) - lut.narrow(axis, 1, dim - 1)
        tv = tv + torch.mean((forward * _edge_weights(dim, axis).to(lut)) ** 2)
        mono = mono + torch.mean(F.relu(forward))
    return tv, mono


def endpoint_penalty(fused: torch.Tensor) -> torch.Tensor:
    """Plan section 4: penalise L(0) < 0 and L(1) < 1 per channel (crushed blacks, grey whites)."""
    black = fused[:, :, 0, 0, 0]
    white = fused[:, :, -1, -1, -1]
    return (F.relu(-black) ** 2 + F.relu(1.0 - white) ** 2).mean()


# --------------------------------------------------------------------------- warm-hue (skin/sunset) hinge

_D65_WHITE = torch.tensor([0.95047, 1.0, 1.08883])
_SRGB_TO_XYZ = torch.tensor([[0.412453, 0.357580, 0.180423],
                             [0.212671, 0.715160, 0.072169],
                             [0.019334, 0.119193, 0.950227]])  # skimage's matrix, so warm bands agree with M1


def rgb_to_lab_torch(rgb: torch.Tensor) -> torch.Tensor:
    """[..., 3] sRGB-encoded [0,1] -> CIELAB (D65), differentiable."""
    rgb = rgb.clamp(0.0, 1.0)
    linear = torch.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055).clamp_min(1e-8) ** 2.4)
    xyz = linear @ _SRGB_TO_XYZ.to(rgb).T / _D65_WHITE.to(rgb)
    delta = 6.0 / 29.0
    f = torch.where(xyz > delta ** 3, xyz.clamp_min(1e-8) ** (1.0 / 3.0), xyz / (3 * delta ** 2) + 4.0 / 29.0)
    return torch.stack([116.0 * f[..., 1] - 16.0, 500.0 * (f[..., 0] - f[..., 1]), 200.0 * (f[..., 1] - f[..., 2])], -1)


class WarmHuePenalty:
    """Plan section 4: for LUT nodes whose INPUT is in the warm band (hue 15-80 deg, chroma 6-80, L 12-95, the
    same soft band as ia3dlut.warm_hue_protection), hinge on |dhue| > 4 deg and on chroma gain outside
    [0.92, 1.12]. Computed on the fused LUT, so it costs nothing at inference."""

    def __init__(self, dim: int = ia.LUT_DIM, max_hue_deg: float = 4.0, chroma_range=(0.92, 1.12)):
        nodes = np.moveaxis(ia.identity_lut(dim), 0, -1).reshape(-1, 3)
        lab = skcolor.rgb2lab(nodes[None])[0]
        hue = np.degrees(np.arctan2(lab[:, 2], lab[:, 1])) % 360
        chroma = np.hypot(lab[:, 1], lab[:, 2])

        def band(x, lo, hi, soft):
            return np.clip((x - (lo - soft)) / soft, 0, 1) * np.clip(((hi + soft) - x) / soft, 0, 1)

        weight = band(hue, 15, 80, 10) * band(chroma, 6, 80, 4) * band(lab[:, 0], 12, 95, 6)
        keep = weight > 0
        self.node_rgb_index = torch.from_numpy(np.nonzero(keep)[0])
        self.weight = torch.from_numpy(weight[keep]).float()
        self.ab_in = torch.from_numpy(lab[keep, 1:]).float()
        self.chroma_in = torch.from_numpy(chroma[keep]).float()
        self.max_hue_rad = float(np.radians(max_hue_deg))
        self.chroma_range = chroma_range

    def __call__(self, fused: torch.Tensor) -> torch.Tensor:
        nodes = fused.reshape(fused.shape[0], 3, -1).permute(0, 2, 1)[:, self.node_rgb_index]  # [B, K, 3]
        ab_out = rgb_to_lab_torch(nodes)[..., 1:]
        a_in, b_in = self.ab_in[:, 0], self.ab_in[:, 1]
        a_out, b_out = ab_out[..., 0], ab_out[..., 1]
        dhue = torch.atan2(a_in * b_out - b_in * a_out, a_in * a_out + b_in * b_out + 1e-6)
        gain = torch.sqrt(a_out ** 2 + b_out ** 2 + 1e-8) / self.chroma_in
        hue_hinge = F.relu(dhue.abs() - self.max_hue_rad) ** 2
        chroma_hinge = F.relu(self.chroma_range[0] - gain) ** 2 + F.relu(gain - self.chroma_range[1]) ** 2
        return ((hue_hinge + chroma_hinge) * self.weight).sum(-1).mean() / self.weight.sum()
