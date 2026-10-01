"""Approximate Lightroom (Process Version 2012+) global develop pipeline for RENDERED inputs (JPEG/HEIC),
written in PyTorch so its unknown constants can be calibrated against Lightroom renders.

Adobe does not publish its formulas. Each operator below is our model of the visible behaviour, with
free constants (`Calib`) fitted on (original, Lightroom-render) pairs. Fidelity classes, reported per preset
by convert.py:
  modelled      global op implemented here; accuracy measured on held-out presets
  approximated  LOCAL in Lightroom (Highlights/Shadows/Whites/Blacks use local tone mapping, Dehaze is
                local) but modelled here as a global curve -> error grows on high-dynamic-range images
  spatial       not a colour transform (vignette, grain): carried as separate Look parameters, not in the LUT
  unsupported   not converted (local masks, Clarity, Texture, creative-profile RGB tables, Point Color,
                legacy PV2010 sliders, camera profiles other than Embedded) -> reported, never silently dropped
  not-a-look    detail/geometry (sharpening, noise reduction, lens, CA, crop, perspective): intentionally ignored

Operator order (inputs and outputs are sRGB-encoded [0,1]):
  linearise -> calibration primaries -> white balance -> exposure -> basic tone (contrast, highlights,
  shadows, whites, blacks) -> dehaze (global approx) -> parametric curve -> point curves (RGB, R, G, B)
  -> HSL bands -> vibrance/saturation -> colour grading / split toning -> grayscale mix -> encode
"""
from __future__ import annotations

import math
import numpy as np
import torch
import torch.nn as nn

# ------------------------------------------------------------------ helpers

def srgb_to_linear(e):
    return torch.where(e <= 0.04045, e / 12.92, ((e.clamp(min=0.04045) + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(l):
    l = l.clamp(min=0)
    return torch.where(l <= 0.0031308, l * 12.92, 1.055 * l.clamp(min=0.0031308) ** (1 / 2.4) - 0.055)


_M1 = torch.tensor([[0.4122214708, 0.5363325363, 0.0514459929], [0.2119034982, 0.6806995451, 0.1073969566], [0.0883024619, 0.2817188376, 0.6299787005]])
_M2 = torch.tensor([[0.2104542553, 0.7936177850, -0.0040720468], [1.9779984951, -2.4285922050, 0.4505937099], [0.0259040371, 0.7827717662, -0.8086757660]])


def lin_to_oklab(l):
    lms = (l @ _M1.T).clamp(min=1e-7) ** (1 / 3)  # eps: cube-root gradient is infinite at 0
    return lms @ _M2.T


def oklab_to_lin(lab):
    lms = lab @ torch.linalg.inv(_M2).T
    return (lms ** 3) @ torch.linalg.inv(_M1).T


def smoothstep(a, b, x):
    t = ((x - a) / (b - a)).clamp(0, 1)
    return t * t * (3 - 2 * t)


# Lightroom HSL band centres (degrees, on OKLCh hue which is close to perceptual hue).
# OKLab hue of sRGB primaries/secondaries: red ~29, orange ~55, yellow ~110, green ~142, aqua ~195, blue ~264, purple ~300, magenta ~328
HSL_BANDS = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
HSL_CENTRES = torch.tensor([29.0, 55.0, 105.0, 142.0, 195.0, 264.0, 300.0, 328.0])


def band_weights(h_deg):
    """Piecewise-linear partition of unity over the 8 HSL bands (circular)."""
    c = HSL_CENTRES
    w = torch.zeros(h_deg.shape + (8,), dtype=h_deg.dtype)
    for i in range(8):
        lo, mid, hi = c[i - 1], c[i], c[(i + 1) % 8]
        d_lo = (mid - lo) % 360
        d_hi = (hi - mid) % 360
        dh = ((h_deg - mid + 180) % 360) - 180
        rising = (1 + dh / d_lo).clamp(0, 1)
        falling = (1 - dh / d_hi).clamp(0, 1)
        w[..., i] = torch.where(dh < 0, rising, falling)
    return w / w.sum(-1, keepdim=True).clamp(min=1e-6)


# ------------------------------------------------------------------ settings -> numeric

def _f(s, k, default=0.0):
    v = s.get(k)
    try:
        return float(str(v).replace("+", "")) if v not in (None, "") else default
    except ValueError:
        return default


def curve_lut(points, n=256, method="natural"):
    """Lightroom point curve ["x, y", ...] (0..255) -> 256-entry LUT in [0,1]. None if neutral/absent/malformed."""
    if not isinstance(points, list) or len(points) < 2:
        return None
    try:
        pts = sorted({float(p.split(",")[0]): float(p.split(",")[1]) for p in points}.items())
    except (ValueError, IndexError, AttributeError):
        return None
    x = np.array([p[0] for p in pts]) / 255.0
    y = np.array([p[1] for p in pts]) / 255.0
    if len(x) == 2 and np.allclose(x, [0, 1]) and np.allclose(y, [0, 1]):
        return None
    xs = np.linspace(0, 1, n)
    if len(x) == 2:
        out = np.interp(xs, x, y)
    else:
        from scipy.interpolate import CubicSpline, PchipInterpolator
        f = CubicSpline(x, y, bc_type="natural") if method == "natural" else PchipInterpolator(x, y)
        out = f(np.clip(xs, x[0], x[-1]))
        out[xs < x[0]] = y[0]; out[xs > x[-1]] = y[-1]  # Lightroom holds endpoints flat outside the curve
    return np.clip(out, 0, 1).astype(np.float32)


SCALAR_KEYS = [
    "IncrementalTemperature", "IncrementalTint", "Temperature", "Tint", "Exposure2012", "Contrast2012",
    "Highlights2012", "Shadows2012", "Whites2012", "Blacks2012", "Dehaze", "Vibrance", "Saturation",
    "ParametricShadows", "ParametricDarks", "ParametricLights", "ParametricHighlights",
    "RedHue", "RedSaturation", "GreenHue", "GreenSaturation", "BlueHue", "BlueSaturation", "ShadowTint",
] + [f"{a}Adjustment{b}" for a in ("Hue", "Saturation", "Luminance") for b in HSL_BANDS]


def grading_from_settings(s):
    """Colour Grading (PV2012 v11+) with fallback to legacy Split Toning keys. Returns dict of floats."""
    def g(new, old, default=0.0):
        return _f(s, new, _f(s, old, default)) if s.get(new) is not None else _f(s, old, default)
    return {
        "sh_hue": g("ColorGradeShadowHue", "SplitToningShadowHue"), "sh_sat": g("ColorGradeShadowSat", "SplitToningShadowSaturation"),
        "hi_hue": g("ColorGradeHighlightHue", "SplitToningHighlightHue"), "hi_sat": g("ColorGradeHighlightSat", "SplitToningHighlightSaturation"),
        "mid_hue": _f(s, "ColorGradeMidtoneHue"), "mid_sat": _f(s, "ColorGradeMidtoneSat"),
        "gl_hue": _f(s, "ColorGradeGlobalHue"), "gl_sat": _f(s, "ColorGradeGlobalSat"),
        "sh_lum": _f(s, "ColorGradeShadowLum"), "mid_lum": _f(s, "ColorGradeMidtoneLum"), "hi_lum": _f(s, "ColorGradeHighlightLum"),
        "gl_lum": _f(s, "ColorGradeGlobalLum"),
        "balance": g("ColorGradeBalance", "SplitToningBalance") if s.get("ColorGradeBalance") is not None else _f(s, "SplitToningBalance"),
        "blending": _f(s, "ColorGradeBlending", 50.0),
    }


class Preset:
    """Numeric view of one preset for the renderer."""

    def __init__(self, s: dict, curve_method="natural", wb_mode="rendered"):
        self.v = {k: _f(s, k) for k in SCALAR_KEYS}
        self.has_abs_temp = s.get("Temperature") is not None and wb_mode == "dng"
        self.grading = grading_from_settings(s)
        self.splits = (_f(s, "ParametricShadowSplit", 25) / 100, _f(s, "ParametricMidtoneSplit", 50) / 100, _f(s, "ParametricHighlightSplit", 75) / 100)
        self.curves = {c: curve_lut(s.get(k), method=curve_method) for c, k in
                       (("rgb", "ToneCurvePV2012"), ("r", "ToneCurvePV2012Red"), ("g", "ToneCurvePV2012Green"), ("b", "ToneCurvePV2012Blue"))}
        self.gray = str(s.get("ConvertToGrayscale", "False")) == "True"
        self.gray_mix = [_f(s, f"GrayMixer{b}") for b in HSL_BANDS]


# ------------------------------------------------------------------ calibrated model

TONE_KNOTS = 12
TONE_SLIDERS = ["Contrast2012", "Highlights2012", "Shadows2012", "Whites2012", "Blacks2012", "Dehaze"]


def hats(e, n=TONE_KNOTS):
    """Piecewise-linear hat basis on [0,1] with n knots -> (..., n)."""
    knots = torch.linspace(0, 1, n)
    return (1 - (e.unsqueeze(-1) - knots).abs() * (n - 1)).clamp(min=0)

class Calib(nn.Module):
    """Free constants of the approximation. Initial values are first guesses; calibrate.py fits them."""

    def __init__(self):
        super().__init__()
        P = lambda v: nn.Parameter(torch.tensor(float(v)))
        self.k_temp, self.k_tint = P(0.006), P(0.004)            # log-gain per incremental unit
        self.abs_temp_ref, self.k_mired = P(5500.0), P(0.0011)   # absolute Temperature (DNG/raw mode only)
        self.k_contrast = P(0.35)
        self.k_hi, self.k_sh, self.k_wh, self.k_bl = P(0.25), P(0.25), P(0.25), P(0.12)
        self.c_hi, self.c_sh = P(0.75), P(0.25)
        self.w_hi, self.w_sh = P(0.18), P(0.18)
        self.k_dehaze, self.dehaze_air = P(0.15), P(0.9)
        self.k_param = P(0.25)
        self.k_hue = P(30.0)                                     # degrees at +/-100
        self.k_hsl_sat, self.k_hsl_lum = P(0.8), P(0.15)
        self.k_sat, self.k_vib = P(1.0), P(0.6)
        self.k_cal_hue, self.k_cal_sat, self.k_shadow_tint = P(0.25), P(0.5), P(0.002)
        self.k_grade, self.k_grade_lum = P(0.08), P(0.1)
        # Learned response curves: delta(e) = sum_j (A[s,j]*t + B[s,j]*t^2) * hat_j(e), t = slider/100.
        # Rows: Contrast, Highlights, Shadows, Whites, Blacks, Dehaze. Initialised to zero (= the analytic terms only).
        self.tone_A = nn.Parameter(torch.zeros(6, TONE_KNOTS))
        self.tone_B = nn.Parameter(torch.zeros(6, TONE_KNOTS))
        self.hue_band = nn.Parameter(torch.ones(8))      # per-band multipliers on k_hue / k_hsl_sat / k_hsl_lum
        self.sat_band = nn.Parameter(torch.ones(8))
        self.lum_band = nn.Parameter(torch.ones(8))
        self.grade_zone = nn.Parameter(torch.ones(4))    # shadows, midtones, highlights, global
        self.cal_hue = nn.Parameter(torch.ones(3)); self.cal_sat = nn.Parameter(torch.ones(3))

    def as_dict(self):
        return {k: v.detach().tolist() for k, v in self.named_parameters()}


def _calibration_matrix(p: Preset, C: Calib):
    """Camera Calibration primaries: rotate each primary toward the next (R->G->B->R) and scale its saturation."""
    eye = torch.eye(3)
    cols = []
    for i, (hk, sk) in enumerate((("RedHue", "RedSaturation"), ("GreenHue", "GreenSaturation"), ("BlueHue", "BlueSaturation"))):
        e = eye[:, i]; nxt = eye[:, (i + 1) % 3]; prv = eye[:, (i - 1) % 3]
        h = p.v[hk] / 100 * C.k_cal_hue * C.cal_hue[i]
        e = e + torch.clamp(h, min=0) * nxt + torch.clamp(-h, min=0) * prv
        sat = 1 + p.v[sk] / 100 * C.k_cal_sat * C.cal_sat[i]
        grey = torch.full((3,), 1 / 3) * e.sum()
        cols.append(grey + sat * (e - grey))
    M = torch.stack(cols, 1)
    return M / (M @ torch.ones(3)).unsqueeze(1)  # rows renormalised so white stays white


def _bump(x, lo, hi):
    """Smooth hump that is 0 outside [lo, hi] and 1 at the centre."""
    t = ((x - lo) / (hi - lo).clamp(min=1e-3)).clamp(0, 1)
    return torch.sin(math.pi * t) ** 2


def _apply_curve(e, lut):
    if lut is None:
        return e
    t = torch.from_numpy(lut)
    pos = e.clamp(0, 1) * 255
    i0 = pos.floor().long().clamp(0, 254)
    f = pos - i0
    return t[i0] * (1 - f) + t[i0 + 1] * f


def render(rgb: torch.Tensor, p: Preset, C: Calib) -> torch.Tensor:
    """rgb: (..., 3) sRGB-encoded in [0,1] -> (..., 3) sRGB-encoded (unclamped until the end)."""
    v = p.v
    lin = srgb_to_linear(rgb)
    lin = lin @ _calibration_matrix(p, C).T
    # white balance (multiplicative in linear light, normalised to keep luminance)
    t = v["IncrementalTemperature"] * C.k_temp
    u = v["IncrementalTint"] * C.k_tint
    if p.has_abs_temp:
        mired = 1e6 / max(v["Temperature"], 1000.0)
        t = t + (1e6 / C.abs_temp_ref - mired) * -C.k_mired
        u = u + v["Tint"] * C.k_tint
    gains = torch.stack([torch.exp(t), torch.exp(-u), torch.exp(-t)])
    gains = gains / (gains @ torch.tensor([0.2126, 0.7152, 0.0722]))
    lin = lin * gains
    lin = lin * 2 ** v["Exposure2012"]
    # shadow tint (calibration panel): green-magenta in shadows
    Y = (lin @ torch.tensor([0.2126, 0.7152, 0.0722])).unsqueeze(-1).clamp(min=1e-6)
    shadow_w = 1 - smoothstep(0.0, 0.25, Y)
    lin = lin * torch.stack([torch.ones(()), torch.exp(-v["ShadowTint"] * C.k_shadow_tint * 10 * torch.ones(())), torch.ones(())]) ** shadow_w

    # basic tone on encoded luminance, applied as a ratio to keep hue
    e = linear_to_srgb(Y)
    d = C.k_contrast * v["Contrast2012"] / 100 * (e - 0.5) * 4 * e * (1 - e)
    d = d + C.k_hi * v["Highlights2012"] / 100 * torch.exp(-((e - C.c_hi) / C.w_hi) ** 2) * e
    d = d + C.k_sh * v["Shadows2012"] / 100 * torch.exp(-((e - C.c_sh) / C.w_sh) ** 2) * (1 - e)
    d = d + C.k_wh * v["Whites2012"] / 100 * e ** 4
    d = d + C.k_bl * v["Blacks2012"] / 100 * (1 - e) ** 4
    H = hats(e.squeeze(-1)) if e.dim() > 1 else hats(e)
    for i, k in enumerate(TONE_SLIDERS):
        t = v[k] / 100
        if t:
            d = d + ((C.tone_A[i] * t + C.tone_B[i] * t * t) * H).sum(-1, keepdim=True) * 0.1
    e2 = (e + d).clamp(min=0)
    lin = lin * (srgb_to_linear(e2) / Y)
    # dehaze (global approximation): subtract a constant veil, renormalise
    dz = (C.k_dehaze * v["Dehaze"] / 100) * C.dehaze_air
    lin = (lin - dz * 0.05) / (1 - dz * 0.05)

    enc = linear_to_srgb(lin)
    # parametric curve (per channel, encoded domain)
    s1, s2, s3 = (torch.tensor(x) for x in p.splits)
    pd = (v["ParametricShadows"] * _bump(enc, torch.tensor(0.0) - s1, s1 * 2) + v["ParametricDarks"] * _bump(enc, s1 - (s2 - s1), s2)
          + v["ParametricLights"] * _bump(enc, s2, s3 + (s3 - s2)) + v["ParametricHighlights"] * _bump(enc, s3 - (1 - s3), torch.tensor(1.0) + (1 - s3)))
    enc = enc + C.k_param * pd / 100 * 0.25
    # point curves: master on all channels, then per channel
    enc = _apply_curve(enc, p.curves["rgb"])
    enc = torch.stack([_apply_curve(enc[..., i], p.curves[c]) for i, c in enumerate("rgb")], -1)

    # perceptual colour ops in OKLCh
    lab = lin_to_oklab(srgb_to_linear(enc.clamp(0, 1)))
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    Cc = torch.sqrt(a * a + b * b + 1e-9)
    h = torch.rad2deg(torch.atan2(b, a + 1e-9)) % 360
    w = band_weights(h)
    hue_adj = torch.tensor([v[f"HueAdjustment{x}"] for x in HSL_BANDS]) / 100
    sat_adj = torch.tensor([v[f"SaturationAdjustment{x}"] for x in HSL_BANDS]) / 100
    lum_adj = torch.tensor([v[f"LuminanceAdjustment{x}"] for x in HSL_BANDS]) / 100
    colourful = (Cc / 0.08).clamp(0, 1)
    h = h + C.k_hue * (w @ (hue_adj * C.hue_band)) * colourful
    Cc = Cc * (1 + C.k_hsl_sat * (w @ (sat_adj * C.sat_band))).clamp(min=0)
    L = L + C.k_hsl_lum * (w @ (lum_adj * C.lum_band)) * colourful * L
    # vibrance (protects already saturated colours) and saturation
    Cc = Cc * (1 + C.k_vib * v["Vibrance"] / 100 * (1 - (Cc / 0.25).clamp(0, 1))).clamp(min=0)
    Cc = Cc * (1 + C.k_sat * v["Saturation"] / 100).clamp(min=0)
    # colour grading / split toning: luminance-weighted tints added in OKLab
    g = p.grading
    bal = g["balance"] / 100
    blend = 0.15 + 0.35 * g["blending"] / 100
    w_sh = 1 - smoothstep(0.5 + 0.25 * bal - blend, 0.5 + 0.25 * bal + blend, L)
    w_hi = smoothstep(0.5 + 0.25 * bal - blend, 0.5 + 0.25 * bal + blend, L)
    w_mid = 1 - (w_sh - w_hi).abs()
    a2, b2 = Cc * torch.cos(torch.deg2rad(h)), Cc * torch.sin(torch.deg2rad(h))
    for z, (hue, sat, lum, wgt) in enumerate(((g["sh_hue"], g["sh_sat"], g["sh_lum"], w_sh), (g["mid_hue"], g["mid_sat"], g["mid_lum"], w_mid),
                                 (g["hi_hue"], g["hi_sat"], g["hi_lum"], w_hi), (g["gl_hue"], g["gl_sat"], g["gl_lum"], torch.ones_like(L)))):
        if sat or lum:
            hh = math.radians(hue + 25)  # Lightroom hue wheel 0 = red; OKLab red ~ 29 deg
            a2 = a2 + C.k_grade * C.grade_zone[z] * sat / 100 * math.cos(hh) * wgt
            b2 = b2 + C.k_grade * C.grade_zone[z] * sat / 100 * math.sin(hh) * wgt
            L = L + C.k_grade_lum * lum / 100 * wgt * 0.5
    if p.gray:
        mix = torch.tensor(p.gray_mix) / 100
        L = L * (1 + 0.3 * (w @ mix) * colourful)
        a2 = torch.zeros_like(a2); b2 = torch.zeros_like(b2)
    out = linear_to_srgb(oklab_to_lin(torch.stack([L, a2, b2], -1)))
    return out.clamp(0, 1)


def bake_lut(p: Preset, C: Calib, dim=33) -> np.ndarray:
    """Sample the global pipeline on a dim^3 grid -> float32 [dim,dim,dim,3] indexed [b,g,r] (red fastest)."""
    ramp = torch.linspace(0, 1, dim)
    b, g, r = torch.meshgrid(ramp, ramp, ramp, indexing="ij")
    grid = torch.stack([r, g, b], -1)
    with torch.no_grad():
        return render(grid.reshape(-1, 3), p, C).reshape(dim, dim, dim, 3).numpy().astype(np.float32)


# ------------------------------------------------------------------ spatial: Clarity / Texture (contract stage O3)

class SpatialCalib(nn.Module):
    """Constants for the local-contrast operators. Radii are fractions of the image's long edge, so a preview
    and a full-resolution export get the same visual effect (resolution independence, invariant P=E)."""

    def __init__(self):
        super().__init__()
        P = lambda v: nn.Parameter(torch.tensor(float(v)))
        self.k_clarity, self.r_clarity = P(0.6), P(0.02)
        self.k_texture, self.r_texture = P(0.5), P(0.004)

    def as_dict(self):
        return {k: v.detach().tolist() for k, v in self.named_parameters()}


def _gauss_blur(x, sigma_px):
    """x: (H, W) tensor; separable Gaussian with reflect padding. sigma may be a tensor (differentiable)."""
    sigma = torch.as_tensor(sigma_px).clamp(min=0.3)
    radius = int(min(max(3, math.ceil(3 * float(sigma))), max(x.shape) // 2 - 1))
    t = torch.arange(-radius, radius + 1, dtype=x.dtype)
    k = torch.exp(-0.5 * (t / sigma) ** 2); k = k / k.sum()
    y = torch.nn.functional.pad(x[None, None], (radius, radius, 0, 0), mode="reflect")
    y = torch.nn.functional.conv2d(y, k.view(1, 1, 1, -1))
    y = torch.nn.functional.pad(y, (0, 0, radius, radius), mode="reflect")
    return torch.nn.functional.conv2d(y, k.view(1, 1, -1, 1))[0, 0]


def apply_local_contrast(img: torch.Tensor, clarity: float, texture: float, S: SpatialCalib) -> torch.Tensor:
    """img: (H, W, 3) sRGB-encoded. Boost (or reduce) luminance detail at two scales, weighted to midtones,
    and re-apply as a luminance ratio so hue is kept."""
    if not clarity and not texture:
        return img
    lab = lin_to_oklab(srgb_to_linear(img))
    L = lab[..., 0]
    long_edge = max(img.shape[:2])
    mid = 4 * L * (1 - L)  # Lightroom's Clarity is weakest in deep shadows and bright highlights
    out = L
    if clarity:
        out = out + S.k_clarity * clarity / 100 * mid * (L - _gauss_blur(L, S.r_clarity * long_edge))
    if texture:
        out = out + S.k_texture * texture / 100 * (L - _gauss_blur(L, S.r_texture * long_edge))
    lab = torch.stack([out.clamp(0, 1), lab[..., 1], lab[..., 2]], -1)
    return linear_to_srgb(oklab_to_lin(lab)).clamp(0, 1)


# ------------------------------------------------------------------ spatial: vignette and grain (contract stage O3)
# EXPERIMENTAL and UNCALIBRATED: shapes follow Lightroom's controls (amount, midpoint, feather, roundness; grain
# amount, size, frequency) but the constants are first guesses to be fitted on the export kit's full-Look photos.
# Both are defined in normalised frame coordinates so preview and export match (invariant P=E).

VIGNETTE_K = 0.9       # linear-light gain change at the frame corner for amount = +/-100
GRAIN_K = 0.12         # OKLab L standard deviation for amount = 100
GRAIN_REF_LONG = 1200  # grains along the long edge at size 0, independent of output resolution


def apply_vignette(img: torch.Tensor, s: dict) -> torch.Tensor:
    a = _f(s, "PostCropVignetteAmount") / 100
    if not a:
        return img
    mid = _f(s, "PostCropVignetteMidpoint", 50) / 100
    feather = _f(s, "PostCropVignetteFeather", 50) / 100
    roundness = _f(s, "PostCropVignetteRoundness", 0) / 100
    h, w = img.shape[:2]
    y, x = torch.meshgrid(torch.linspace(-1, 1, h), torch.linspace(-1, 1, w), indexing="ij")
    if roundness > 0:  # towards a true circle in pixel space
        x = x * (1 + roundness * (w / h - 1))
    p = 2.0 + max(0.0, -roundness) * 6.0  # towards the frame's rectangle (superellipse)
    r = ((x.abs() ** p + y.abs() ** p) ** (1 / p)) / (2 ** (1 / p))
    centre = 0.25 + 0.65 * mid
    width = 0.05 + 0.6 * feather
    t = smoothstep(centre - width / 2, centre + width / 2, r)
    style = int(_f(s, "PostCropVignetteStyle", 1))
    if style == 3:
        # Paint Overlay: blend toward black (darkening) or white (lightening), flattening contrast at the edges.
        target = 0.0 if a < 0 else 1.0
        w = (abs(a) * VIGNETTE_K * t).clamp(0, 1).unsqueeze(-1)
        return (img * (1 - w) + target * w).clamp(0, 1)
    lin = srgb_to_linear(img)
    gain = 1 + VIGNETTE_K * a * t
    if style == 2:
        # Color Priority: change lightness only, keeping hue and chroma.
        lab = lin_to_oklab(lin)
        L = (lab[..., 0] * gain.clamp(min=0) ** (1 / 3)).clamp(0, 1)
        return linear_to_srgb(oklab_to_lin(torch.stack([L, lab[..., 1], lab[..., 2]], -1))).clamp(0, 1)
    # Highlight Priority (default): darkening is reduced in highlights in proportion to Highlight Contrast.
    hc = _f(s, "PostCropVignetteHighlightContrast", 0) / 100
    if a < 0 and hc:
        Y = (lin @ torch.tensor([0.2126, 0.7152, 0.0722])).clamp(0, 1)
        protect = hc * smoothstep(0.35, 0.9, Y)
        gain = 1 + (gain - 1) * (1 - protect)
    return linear_to_srgb(lin * gain.clamp(min=0).unsqueeze(-1)).clamp(0, 1)


def apply_grain(img: torch.Tensor, s: dict, seed: int = 0) -> torch.Tensor:
    amount = _f(s, "GrainAmount") / 100
    if not amount:
        return img
    size = _f(s, "GrainSize", 25) / 100
    h, w = img.shape[:2]
    long_edge = max(h, w)
    ref_long = max(8, int(round(GRAIN_REF_LONG / (1 + 4 * size))))
    gh, gw = max(2, round(ref_long * h / long_edge)), max(2, round(ref_long * w / long_edge))
    gen = torch.Generator().manual_seed(int(seed))
    up = lambda n: torch.nn.functional.interpolate(n[None, None], size=(h, w), mode="bilinear", align_corners=False)[0, 0]
    fine = up(torch.randn((gh, gw), generator=gen))
    # Frequency (Lightroom "Roughness"): higher values mix in a coarser, clumpier field. Strength is renormalised,
    # so frequency changes the grain's structure, not its amount.
    roughness = _f(s, "GrainFrequency", 50) / 100
    coarse = up(torch.randn((max(2, gh // 3), max(2, gw // 3)), generator=gen))
    noise = (1 - roughness) * fine / fine.std().clamp(min=1e-6) + roughness * coarse / coarse.std().clamp(min=1e-6)
    noise = noise / noise.std().clamp(min=1e-6)
    lab = lin_to_oklab(srgb_to_linear(img))
    L = lab[..., 0]
    L = L + GRAIN_K * amount * noise * (4 * L * (1 - L) + 0.2)
    return linear_to_srgb(oklab_to_lin(torch.stack([L.clamp(0, 1), lab[..., 1], lab[..., 2]], -1))).clamp(0, 1)
