"""Reference implementation of the Develop stage of rendering contract v2, reading a pack recipe.

This is the executable specification that the Swift and Kotlin ports mirror line by line. It is a
NumPy port of the calibrated model in `experiments/presets/lr_model.py` (the source of truth for the
global stage); `build_pack.py` and the tests check that, for every preset, rendering the converted
recipe here equals rendering the original Lightroom settings through `lr_model.render`.

Conventions (rendering-v2.md §2):
- Colours are sRGB-encoded floats in [0, 1], shape (..., 3), channel order R, G, B.
- Slider values keep Lightroom's units (mostly -100…100); equations divide by 100 where needed.
- Spatial radii are fractions of the image's long edge, so a preview and an export match.

Only NumPy is used, in float64. The ports may compute in float32; the golden vectors carry the
tolerances that allows (shared/fixtures/look-pack/golden.json).
"""
from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
RENDERING_CONTRACT = REPO / "shared/contracts/rendering-v2.json"

HSL_BANDS = ("red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta")
HSL_CENTRES_DEG = np.array([29.0, 55.0, 105.0, 142.0, 195.0, 264.0, 300.0, 328.0])
LUMA = np.array([0.2126, 0.7152, 0.0722])
TONE_KNOTS = 12
# Row order of the learned tone response tables (developModel.constants.tone_A / tone_B).
TONE_ROWS = ("contrast", "highlights", "shadows", "whites", "blacks", "dehaze")

# OKLab (Björn Ottosson). M1: linear sRGB -> LMS, M2: LMS^(1/3) -> Lab.
OKLAB_M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                     [0.2119034982, 0.6806995451, 0.1073969566],
                     [0.0883024619, 0.2817188376, 0.6299787005]])
OKLAB_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                     [1.9779984951, -2.4285922050, 0.4505937099],
                     [0.0259040371, 0.7827717662, -0.8086757660]])
OKLAB_M1_INV = np.linalg.inv(OKLAB_M1)
OKLAB_M2_INV = np.linalg.inv(OKLAB_M2)


def load_develop_constants(contract_path: Path = RENDERING_CONTRACT) -> dict:
    """The calibrated constants exactly as the contract publishes them (ports embed the same JSON)."""
    contract = json.loads(Path(contract_path).read_text())
    return contract["developModel"]


# ------------------------------------------------------------------ colour helpers

def srgb_to_linear(encoded):
    e = np.asarray(encoded, dtype=np.float64)
    return np.where(e <= 0.04045, e / 12.92, ((np.maximum(e, 0.04045) + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(linear):
    lin = np.maximum(np.asarray(linear, dtype=np.float64), 0.0)
    return np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.maximum(lin, 0.0031308) ** (1 / 2.4) - 0.055)


def linear_to_oklab(linear):
    # The 1e-7 floor matches lr_model: the cube root's slope is infinite at 0.
    lms = np.maximum(linear @ OKLAB_M1.T, 1e-7) ** (1 / 3)
    return lms @ OKLAB_M2.T


def oklab_to_linear(lab):
    lms = lab @ OKLAB_M2_INV.T
    return (lms ** 3) @ OKLAB_M1_INV.T


def smoothstep(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def hsl_band_weights(hue_deg):
    """Piecewise-linear partition of unity over the 8 HSL bands (circular), shape (..., 8)."""
    weights = np.zeros(np.shape(hue_deg) + (8,))
    for i in range(8):
        lower, centre, upper = HSL_CENTRES_DEG[i - 1], HSL_CENTRES_DEG[i], HSL_CENTRES_DEG[(i + 1) % 8]
        span_below = (centre - lower) % 360
        span_above = (upper - centre) % 360
        offset = ((hue_deg - centre + 180) % 360) - 180
        rising = np.clip(1 + offset / span_below, 0, 1)
        falling = np.clip(1 - offset / span_above, 0, 1)
        weights[..., i] = np.where(offset < 0, rising, falling)
    return weights / np.maximum(weights.sum(-1, keepdims=True), 1e-6)


def tone_hat_basis(encoded_luma):
    """Piecewise-linear hat basis on [0, 1] with 12 knots, shape (..., 12)."""
    knots = np.linspace(0, 1, TONE_KNOTS)
    return np.maximum(1 - np.abs(encoded_luma[..., None] - knots) * (TONE_KNOTS - 1), 0.0)


# ------------------------------------------------------------------ tone curves

CURVE_TABLE_SIZE = 256


def natural_cubic_spline(xs, ys, query):
    """Natural cubic spline (second derivative 0 at both ends) through (xs, ys), evaluated at query."""
    xs = np.asarray(xs, dtype=np.float64)
    ys = np.asarray(ys, dtype=np.float64)
    n = len(xs)
    h = np.diff(xs)
    # Tridiagonal system for the interior second derivatives (Thomas algorithm, as the ports do it).
    second = np.zeros(n)
    if n > 2:
        sub = h[:-1].copy()
        diag = 2 * (h[:-1] + h[1:])
        sup = h[1:].copy()
        rhs = 6 * ((ys[2:] - ys[1:-1]) / h[1:] - (ys[1:-1] - ys[:-2]) / h[:-1])
        for i in range(1, n - 2):
            factor = sub[i] / diag[i - 1]
            diag[i] -= factor * sup[i - 1]
            rhs[i] -= factor * rhs[i - 1]
        interior = np.zeros(n - 2)
        interior[-1] = rhs[-1] / diag[-1]
        for i in range(n - 4, -1, -1):
            interior[i] = (rhs[i] - sup[i] * interior[i + 1]) / diag[i]
        second[1:-1] = interior
    q = np.asarray(query, dtype=np.float64)
    segment = np.clip(np.searchsorted(xs, q, side="right") - 1, 0, n - 2)
    x0, x1 = xs[segment], xs[segment + 1]
    y0, y1 = ys[segment], ys[segment + 1]
    m0, m1 = second[segment], second[segment + 1]
    width = x1 - x0
    a = (x1 - q) / width
    b = (q - x0) / width
    return a * y0 + b * y1 + ((a ** 3 - a) * m0 + (b ** 3 - b) * m1) * width * width / 6


def curve_table(points) -> np.ndarray:
    """A recipe curve ([[x, y], ...] in 0…255, sorted, unique x) as a 256-entry float32 table in [0, 1].

    2 points: linear. 3 or more: natural cubic spline. Outside [x0, xN] the end value is held.
    """
    xs = np.array([p[0] for p in points], dtype=np.float64) / 255.0
    ys = np.array([p[1] for p in points], dtype=np.float64) / 255.0
    grid = np.linspace(0, 1, CURVE_TABLE_SIZE)
    if len(xs) == 2:
        out = np.interp(grid, xs, ys)
    else:
        out = natural_cubic_spline(xs, ys, np.clip(grid, xs[0], xs[-1]))
        out[grid < xs[0]] = ys[0]
        out[grid > xs[-1]] = ys[-1]
    return np.clip(out, 0, 1).astype(np.float32)


def apply_curve_table(encoded, table):
    position = np.clip(encoded, 0, 1) * (CURVE_TABLE_SIZE - 1)
    index = np.clip(np.floor(position).astype(np.int64), 0, CURVE_TABLE_SIZE - 2)
    fraction = position - index
    table = table.astype(np.float64)
    return table[index] * (1 - fraction) + table[index + 1] * fraction


# ------------------------------------------------------------------ develop global (stage develop.global)

def calibration_matrix(calibration: dict, C: dict) -> np.ndarray:
    """Camera Calibration primaries: rotate each primary toward its neighbour and scale its saturation."""
    eye = np.eye(3)
    columns = []
    keys = (("redHue", "redSaturation"), ("greenHue", "greenSaturation"), ("blueHue", "blueSaturation"))
    for i, (hue_key, sat_key) in enumerate(keys):
        primary, following, preceding = eye[:, i], eye[:, (i + 1) % 3], eye[:, (i - 1) % 3]
        hue_shift = calibration.get(hue_key, 0.0) / 100 * C["k_cal_hue"] * C["cal_hue"][i]
        primary = primary + max(hue_shift, 0.0) * following + max(-hue_shift, 0.0) * preceding
        saturation = 1 + calibration.get(sat_key, 0.0) / 100 * C["k_cal_sat"] * C["cal_sat"][i]
        grey = np.full(3, primary.sum() / 3)
        columns.append(grey + saturation * (primary - grey))
    matrix = np.stack(columns, 1)
    return matrix / matrix.sum(1, keepdims=True)  # each row sums to 1: white stays white


def apply_luminance(linear, target_luma):
    """Scale to target luminance keeping hue; overflow past 1 is filled with neutral (lr_model.apply_luminance)."""
    luma = np.maximum(linear @ LUMA, 1e-6)[..., None]
    scaled = linear * (target_luma / luma)
    peak = linear.max(-1, keepdims=True)
    k = np.maximum((1 - target_luma) / np.maximum(peak - luma, 1e-9), 0.0)
    limited = linear * k + (target_luma - k * luma)
    over = scaled.max(-1, keepdims=True) > 1
    return np.where(over, limited, scaled)


def _bump(x, lower, upper):
    t = np.clip((x - lower) / max(upper - lower, 1e-3), 0, 1)
    return np.sin(math.pi * t) ** 2


def develop_global(rgb, recipe: dict, model: dict, curve_tables: dict | None = None):
    """Stage develop.global for one preset. `recipe` is the pack entry's `recipe` object."""
    C = model["constants"]
    g = recipe.get("global", {})
    rgb = np.asarray(rgb, dtype=np.float64)
    linear = srgb_to_linear(rgb)

    # 1 calibration (clip: rotated primaries can go below zero; negative light breaks the tone ratio)
    if "calibration" in g:
        linear = np.maximum(linear @ calibration_matrix(g["calibration"], C).T, 0.0)
    else:
        linear = np.maximum(linear, 0.0)
    # 2 white balance: multiplicative in linear light, normalised to keep luminance
    wb = g.get("whiteBalance", {})
    t = wb.get("temperature", 0.0) * C["k_temp"]
    u = wb.get("tint", 0.0) * C["k_tint"]
    gains = np.array([math.exp(t), math.exp(-u), math.exp(-t)])
    linear = linear * (gains / (gains @ LUMA))
    # 3 exposure (EV)
    linear = linear * 2.0 ** g.get("exposure", {}).get("ev", 0.0)
    # 4 shadow tint (green-magenta in the shadows)
    luma = np.maximum(linear @ LUMA, 1e-6)[..., None]
    shadow_weight = 1 - smoothstep(0.0, 0.25, luma)
    green_gain = math.exp(-g.get("shadowTint", {}).get("amount", 0.0) * C["k_shadow_tint"] * 10)
    linear = linear * np.concatenate([np.ones_like(shadow_weight), green_gain ** shadow_weight, np.ones_like(shadow_weight)], -1)

    # 5 basic tone + 6 dehaze response, on encoded luminance, applied as a luminance ratio
    tone = g.get("toneSliders", {})
    dehaze = g.get("dehaze", {}).get("amount", 0.0)
    encoded = linear_to_srgb(luma)
    delta = C["k_contrast"] * tone.get("contrast", 0.0) / 100 * (encoded - 0.5) * 4 * encoded * (1 - encoded)
    delta += C["k_hi"] * tone.get("highlights", 0.0) / 100 * np.exp(-((encoded - C["c_hi"]) / C["w_hi"]) ** 2) * encoded
    delta += C["k_sh"] * tone.get("shadows", 0.0) / 100 * np.exp(-((encoded - C["c_sh"]) / C["w_sh"]) ** 2) * (1 - encoded)
    delta += C["k_wh"] * tone.get("whites", 0.0) / 100 * encoded ** 4
    delta += C["k_bl"] * tone.get("blacks", 0.0) / 100 * (1 - encoded) ** 4
    basis = tone_hat_basis(encoded[..., 0])
    slider_values = {**{k: tone.get(k, 0.0) for k in TONE_ROWS[:5]}, "dehaze": dehaze}
    for row, name in enumerate(TONE_ROWS):
        s = slider_values[name] / 100
        if s:
            response = np.asarray(C["tone_A"][row]) * s + np.asarray(C["tone_B"][row]) * s * s
            delta += (basis @ response)[..., None] * 0.1
    linear = apply_luminance(linear, srgb_to_linear(np.maximum(encoded + delta, 0.0)))
    veil = C["k_dehaze"] * dehaze / 100 * C["dehaze_air"] * 0.05
    linear = (linear - veil) / (1 - veil)

    encoded = linear_to_srgb(linear)
    # 7 parametric curve (per channel, encoded)
    if "parametricCurve" in g:
        p = g["parametricCurve"]
        s1, s2, s3 = p["shadowSplit"] / 100, p["midtoneSplit"] / 100, p["highlightSplit"] / 100
        regions = (p["shadows"] * _bump(encoded, -s1, s1 * 2) + p["darks"] * _bump(encoded, s1 - (s2 - s1), s2)
                   + p["lights"] * _bump(encoded, s2, s3 + (s3 - s2)) + p["highlights"] * _bump(encoded, s3 - (1 - s3), 1 + (1 - s3)))
        encoded = encoded + C["k_param"] * regions / 100 * 0.25
    # 8 point curves: master on every channel, then per channel
    if "toneCurve" in g:
        tables = curve_tables if curve_tables is not None else curve_tables_for(g["toneCurve"])
        if tables.get("master") is not None:
            encoded = apply_curve_table(encoded, tables["master"])
        encoded = np.stack([apply_curve_table(encoded[..., i], tables[c]) if tables.get(c) is not None else encoded[..., i]
                            for i, c in enumerate(("red", "green", "blue"))], -1)

    # 9-12 perceptual colour in OKLCh
    lab = linear_to_oklab(srgb_to_linear(np.clip(encoded, 0, 1)))
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    chroma = np.sqrt(a * a + b * b + 1e-9)
    hue = np.degrees(np.arctan2(b, a + 1e-9)) % 360
    band = hsl_band_weights(hue)
    colourful = np.clip(chroma / 0.08, 0, 1)
    if "hsl" in g:
        hsl = g["hsl"]
        hue_adj = np.asarray(hsl["hue"]) / 100
        sat_adj = np.asarray(hsl["saturation"]) / 100
        lum_adj = np.asarray(hsl["luminance"]) / 100
        hue = hue + C["k_hue"] * (band @ (hue_adj * np.asarray(C["hue_band"]))) * colourful
        chroma = chroma * np.maximum(1 + C["k_hsl_sat"] * (band @ (sat_adj * np.asarray(C["sat_band"]))), 0)
        L = L + C["k_hsl_lum"] * (band @ (lum_adj * np.asarray(C["lum_band"]))) * colourful * L
    presence = g.get("vibranceSaturation", {})
    chroma = chroma * np.maximum(1 + C["k_vib"] * presence.get("vibrance", 0.0) / 100 * (1 - np.clip(chroma / 0.25, 0, 1)), 0)
    chroma = chroma * max(1 + C["k_sat"] * presence.get("saturation", 0.0) / 100, 0.0)
    a2 = chroma * np.cos(np.radians(hue))
    b2 = chroma * np.sin(np.radians(hue))
    if "colorGrading" in g:
        cg = g["colorGrading"]
        balance = cg["balance"] / 100
        blend = 0.15 + 0.35 * cg["blending"] / 100
        w_high = smoothstep(0.5 + 0.25 * balance - blend, 0.5 + 0.25 * balance + blend, L)
        w_shadow = 1 - w_high
        w_mid = 1 - np.abs(w_shadow - w_high)
        zones = (("shadows", w_shadow, 0), ("midtones", w_mid, 1), ("highlights", w_high, 2), ("global", np.ones_like(L), 3))
        for name, weight, zone_index in zones:
            zone = cg[name]
            if zone["saturation"] or zone["luminance"]:
                angle = math.radians(zone["hue"] + 25)  # Lightroom wheel 0 = red; OKLab red is ~29 degrees
                strength = C["k_grade"] * C["grade_zone"][zone_index] * zone["saturation"] / 100
                a2 = a2 + strength * math.cos(angle) * weight
                b2 = b2 + strength * math.sin(angle) * weight
                L = L + C["k_grade_lum"] * zone["luminance"] / 100 * weight * 0.5
    if "grayscale" in g:
        mix = np.asarray(g["grayscale"]["mix"]) / 100
        L = L * (1 + 0.3 * (band @ mix) * colourful)
        a2 = np.zeros_like(a2)
        b2 = np.zeros_like(b2)
    return np.clip(linear_to_srgb(oklab_to_linear(np.stack([L, a2, b2], -1))), 0, 1)


def curve_tables_for(tone_curve: dict) -> dict:
    return {channel: (curve_table(points) if points else None) for channel, points in
            ((c, tone_curve.get(c)) for c in ("master", "red", "green", "blue"))}


def lut_grid(dimension: int) -> np.ndarray:
    """Identity grid in contract layout: [b][g][r] with red fastest, shape (N, N, N, 3) as (r, g, b)."""
    ramp = np.linspace(0, 1, dimension)
    b, g, r = np.meshgrid(ramp, ramp, ramp, indexing="ij")
    return np.stack([r, g, b], -1)


def bake_global_lut(recipe: dict, model: dict, dimension: int = 33) -> np.ndarray:
    """The device bake: sample develop.global on the identity grid. Returns float32 (N, N, N, 3)."""
    tables = curve_tables_for(recipe["global"]["toneCurve"]) if "toneCurve" in recipe.get("global", {}) else None
    grid = lut_grid(dimension).reshape(-1, 3)
    return develop_global(grid, recipe, model, tables).reshape(dimension, dimension, dimension, 3).astype(np.float32)


def apply_lut_trilinear(lut: np.ndarray, rgb) -> np.ndarray:
    """Trilinear lookup in a contract-layout LUT (N, N, N, 3) indexed [b][g][r]."""
    n = lut.shape[0]
    rgb = np.clip(np.asarray(rgb, dtype=np.float64), 0, 1) * (n - 1)
    i0 = np.clip(np.floor(rgb).astype(np.int64), 0, n - 2)
    f = rgb - i0
    r0, g0, b0 = i0[..., 0], i0[..., 1], i0[..., 2]
    fr, fg, fb = f[..., 0:1], f[..., 1:2], f[..., 2:3]
    lut = lut.astype(np.float64)
    out = 0.0
    for db, wb in ((0, 1 - fb), (1, fb)):
        for dg, wg in ((0, 1 - fg), (1, fg)):
            for dr, wr in ((0, 1 - fr), (1, fr)):
                out = out + lut[b0 + db, g0 + dg, r0 + dr] * wb * wg * wr
    return out


def apply_strength(original, developed, strength: float):
    """Develop Amount: the global result is mixed with its input (rendering-v2.md §4.3)."""
    return original + strength * (developed - original)


# ------------------------------------------------------------------ develop spatial and finishing (reference)
# Stage develop.spatial (noise reduction, clarity, texture, sharpening) and the preset's finishing operators
# evaluated in stage effects (vignette, grain). Clarity/texture are lr_model's calibrated operators; vignette is
# lr_model's experimental one; grain keeps lr_model's structure with a portable random field; sharpening and noise
# reduction are provisional Lightly operators (uncalibrated). See rendering-v2.md §5 and §9.

def gaussian_blur(plane: np.ndarray, sigma_px: float) -> np.ndarray:
    """Separable Gaussian with reflect padding, truncated at 3 sigma (lr_model._gauss_blur)."""
    sigma = max(float(sigma_px), 0.3)
    radius = int(min(max(3, math.ceil(3 * sigma)), max(plane.shape) // 2 - 1))
    taps = np.arange(-radius, radius + 1, dtype=np.float64)
    kernel = np.exp(-0.5 * (taps / sigma) ** 2)
    kernel /= kernel.sum()
    padded = np.pad(plane, ((0, 0), (radius, radius)), mode="reflect")
    rows = np.stack([np.convolve(row, kernel, mode="valid") for row in padded])
    padded = np.pad(rows, ((radius, radius), (0, 0)), mode="reflect")
    return np.stack([np.convolve(col, kernel, mode="valid") for col in padded.T], 1)


def _with_lightness(rgb, new_lightness, lab):
    return np.clip(linear_to_srgb(oklab_to_linear(np.stack([np.clip(new_lightness, 0, 1), lab[..., 1], lab[..., 2]], -1))), 0, 1)


def apply_clarity_texture(rgb, clarity: float, texture: float, spatial: dict, strength: float = 1.0):
    if not clarity and not texture:
        return rgb
    lab = linear_to_oklab(srgb_to_linear(rgb))
    L = lab[..., 0]
    long_edge = max(rgb.shape[:2])
    midtones = 4 * L * (1 - L)
    out = L
    if clarity:
        out = out + spatial["k_clarity"] * strength * clarity / 100 * midtones * (L - gaussian_blur(L, spatial["r_clarity"] * long_edge))
    if texture:
        out = out + spatial["k_texture"] * strength * texture / 100 * (L - gaussian_blur(L, spatial["r_texture"] * long_edge))
    return _with_lightness(rgb, out, lab)


def apply_sharpening(rgb, params: dict, provisional: dict, strength: float = 1.0):
    """Unsharp mask on OKLab L. Radius is in Lightroom pixels at the reference long edge."""
    amount = params["amount"] * strength
    if not amount:
        return rgb
    lab = linear_to_oklab(srgb_to_linear(rgb))
    L = lab[..., 0]
    sigma = params["radius"] * max(rgb.shape[:2]) / provisional["referenceLongEdgePx"]
    detail = L - gaussian_blur(L, sigma)
    threshold = (1 - params["detail"] / 100) * provisional["sharpenDetailThreshold"]
    detail = detail * np.abs(detail) / (np.abs(detail) + threshold + 1e-12)
    if params["edgeMasking"]:
        gy, gx = np.gradient(gaussian_blur(L, sigma))
        edge = np.hypot(gx, gy) * max(rgb.shape[:2]) / provisional["referenceLongEdgePx"]
        detail = detail * smoothstep(0.0, params["edgeMasking"] / 100 * provisional["sharpenEdgeScale"], edge)
    return _with_lightness(rgb, L + provisional["k_sharpen"] * amount / 100 * detail, lab)


def apply_noise_reduction(rgb, params: dict, provisional: dict, strength: float = 1.0):
    """Luminance: blend toward a blurred L where the image is flat. Colour: blur a and b."""
    luminance, colour = params["luminance"] * strength, params["color"] * strength
    if not luminance and not colour:
        return rgb
    lab = linear_to_oklab(srgb_to_linear(rgb))
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    scale = max(rgb.shape[:2]) / provisional["referenceLongEdgePx"]
    if luminance:
        smooth = gaussian_blur(L, provisional["nrLumaRadiusPx"] * scale)
        local_contrast = np.abs(L - smooth)
        keep = smoothstep(0.0, provisional["nrDetailScale"] * (1.01 - params["luminanceDetail"] / 100), local_contrast)
        # Contrast keeps more of the local tonal contrast (Lightroom's Luminance Contrast slider).
        weight = luminance / 100 * (1 - keep) * (1 - 0.5 * params["luminanceContrast"] / 100)
        L = L + (smooth - L) * weight
    if colour:
        radius = provisional["nrColourRadiusPx"] * scale * (0.5 + params["colorSmoothness"] / 100)
        weight = colour / 100
        a = a + (gaussian_blur(a, radius) - a) * weight
        b = b + (gaussian_blur(b, radius) - b) * weight
    return np.clip(linear_to_srgb(oklab_to_linear(np.stack([np.clip(L, 0, 1), a, b], -1))), 0, 1)


def pixel_centre_coordinates(height: int, width: int):
    """Normalised pixel-centre coordinates in [-1, 1] (lr_model: linspace(-1, 1, n))."""
    y = np.linspace(-1, 1, height)[:, None] * np.ones((1, width))
    x = np.ones((height, 1)) * np.linspace(-1, 1, width)[None, :]
    return y, x


def apply_vignette(rgb, params: dict, experimental: dict, strength: float = 1.0):
    """Post-crop vignette (lr_model.apply_vignette), in frame coordinates of the stage's input."""
    amount = params["amount"] / 100 * strength
    if not amount:
        return rgb
    midpoint, feather, roundness = params["midpoint"] / 100, params["feather"] / 100, params["roundness"] / 100
    h, w = rgb.shape[:2]
    y, x = pixel_centre_coordinates(h, w)
    if roundness > 0:
        x = x * (1 + roundness * (w / h - 1))
    power = 2.0 + max(0.0, -roundness) * 6.0
    radius = ((np.abs(x) ** power + np.abs(y) ** power) ** (1 / power)) / (2 ** (1 / power))
    centre = 0.25 + 0.65 * midpoint
    width = 0.05 + 0.6 * feather
    t = smoothstep(centre - width / 2, centre + width / 2, radius)
    k = experimental["VIGNETTE_K"]
    if params["style"] == 3:  # paint overlay
        target = 0.0 if amount < 0 else 1.0
        weight = np.clip(abs(amount) * k * t, 0, 1)[..., None]
        return np.clip(rgb * (1 - weight) + target * weight, 0, 1)
    linear = srgb_to_linear(rgb)
    gain = 1 + k * amount * t
    if params["style"] == 2:  # colour priority: lightness only
        lab = linear_to_oklab(linear)
        return _with_lightness(rgb, lab[..., 0] * np.maximum(gain, 0) ** (1 / 3), lab)
    highlight_contrast = params["highlightContrast"] / 100
    if amount < 0 and highlight_contrast:
        luma = np.clip(linear @ LUMA, 0, 1)
        gain = 1 + (gain - 1) * (1 - highlight_contrast * smoothstep(0.35, 0.9, luma))
    return np.clip(linear_to_srgb(linear * np.maximum(gain, 0)[..., None]), 0, 1)


def _lowbias32(x):
    """Integer hash (C. Wellons' lowbias32) on uint32 arrays: the contract's portable random source."""
    x = np.asarray(x, dtype=np.uint64) & 0xFFFFFFFF
    x ^= x >> 16
    x = (x * 0x7FEB352D) & 0xFFFFFFFF
    x ^= x >> 15
    x = (x * 0x846CA68B) & 0xFFFFFFFF
    x ^= x >> 16
    return x


def gaussian_field(seed: int, layer: int, rows: int, cols: int) -> np.ndarray:
    """Standard normal values at integer cells, from hashes (Box-Muller). Identical on every platform."""
    i = np.arange(rows, dtype=np.uint64)[:, None]
    j = np.arange(cols, dtype=np.uint64)[None, :]
    base = _lowbias32(np.uint64(seed & 0xFFFFFFFF) ^ _lowbias32(np.uint64(layer)))
    h1 = _lowbias32(base ^ _lowbias32(i * np.uint64(0x9E3779B1) ^ _lowbias32(j)))
    h2 = _lowbias32(h1 ^ np.uint64(0x85EBCA6B))
    u1 = ((h1 >> 8).astype(np.float64) + 0.5) / 16777216.0
    u2 = ((h2 >> 8).astype(np.float64) + 0.5) / 16777216.0
    return np.sqrt(-2 * np.log(u1)) * np.cos(2 * math.pi * u2)


def bilinear_upsample(field: np.ndarray, height: int, width: int) -> np.ndarray:
    """Half-pixel-centre bilinear resize (torch interpolate, align_corners=False)."""
    def axis(out_n, in_n):
        src = np.clip((np.arange(out_n) + 0.5) * in_n / out_n - 0.5, 0, in_n - 1)
        lo = np.floor(src).astype(np.int64)
        hi = np.minimum(lo + 1, in_n - 1)
        return lo, hi, src - lo
    y0, y1, fy = axis(height, field.shape[0])
    x0, x1, fx = axis(width, field.shape[1])
    top = field[y0][:, x0] * (1 - fx) + field[y0][:, x1] * fx
    bottom = field[y1][:, x0] * (1 - fx) + field[y1][:, x1] * fx
    return top * (1 - fy)[:, None] + bottom * fy[:, None]


def grain_supersampling(cells_long: int, long_edge: int) -> int:
    """Integer supersampling factor so every grain cell spans at least 2 output pixels before averaging.

    Contract fixes 1 (rendering-v2 revision 1): when a small render has fewer pixels than grain cells, the
    bilinear "upsample" became a point sample of the field. Each pixel then got an independent value at
    1.5x the intended amplitude (the 2/3 normalisation assumes interpolation), so a small preview showed
    coarse, too-strong grain that the same export viewed at that size does not have. Rendering at s times
    the size and box-averaging s x s blocks gives the preview what downscaling the export would give it.
    """
    return max(1, math.ceil(2 * cells_long / long_edge))


def box_average(plane: np.ndarray, factor: int) -> np.ndarray:
    """Mean of each factor x factor block (the plane's sides are multiples of factor)."""
    if factor == 1:
        return plane
    h, w = plane.shape[0] // factor, plane.shape[1] // factor
    return plane.reshape(h, factor, w, factor).mean(axis=(1, 3))


def grain_noise(height: int, width: int, params: dict, experimental: dict) -> np.ndarray:
    """The unit grain field n at the output size (rendering-v2.md F2), before amount and tone weighting."""
    size = params["size"] / 100
    long_edge = max(height, width)
    cells_long = max(8, int(round(experimental["GRAIN_REF_LONG"] / (1 + 4 * size))))
    rows, cols = max(2, round(cells_long * height / long_edge)), max(2, round(cells_long * width / long_edge))
    factor = grain_supersampling(cells_long, long_edge)
    h, w = height * factor, width * factor
    fine = bilinear_upsample(gaussian_field(params["seed"], 0, rows, cols), h, w) / (2 / 3)
    coarse = bilinear_upsample(gaussian_field(params["seed"], 1, max(2, rows // 3), max(2, cols // 3)), h, w) / (2 / 3)
    roughness = params["roughness"] / 100
    noise = ((1 - roughness) * fine + roughness * coarse) / math.sqrt((1 - roughness) ** 2 + roughness ** 2)
    return box_average(noise, factor)


def _with_lightness_keep_chromaticity(rgb, new_lightness, lab):
    """Replace OKLab L, scaling a and b by the same factor so hue and saturation (a/L, b/L) are unchanged.

    Scaling (L, a, b) by r scales LMS^(1/3) by r, i.e. linear RGB by r^3: the pixel only gets brighter or
    darker. `_with_lightness` keeps a and b fixed instead, which raises the saturation of every pixel the
    grain darkens and lowers it where it brightens; on skin at grain 55 that read as coloured grain.
    L is at least about 0.0046 (the 1e-7 LMS floor), so the ratio is always defined.
    """
    target = np.clip(new_lightness, 0, 1)
    ratio = target / np.maximum(lab[..., 0], 1e-6)
    scaled = np.stack([target, lab[..., 1] * ratio, lab[..., 2] * ratio], -1)
    return np.clip(linear_to_srgb(oklab_to_linear(scaled)), 0, 1)


def apply_grain(rgb, params: dict, experimental: dict, strength: float = 1.0):
    """Film grain on OKLab lightness, strongest in the midtones. Grain cells are set per long edge (resolution independent).

    v2 differs from lr_model.apply_grain on purpose: the random field comes from a portable hash instead of
    torch.randn, and is normalised analytically (bilinear interpolation of unit noise has standard deviation
    2/3 on average) instead of by the image's own sample statistics, so preview and export get the same grain.
    Revision 1 also differs on purpose: chromaticity is kept (no colour noise) and renders with fewer pixels
    than 2 per grain cell are supersampled and box-averaged (see grain_supersampling).
    """
    amount = params["amount"] / 100 * strength
    if not amount:
        return rgb
    h, w = rgb.shape[:2]
    noise = grain_noise(h, w, params, experimental)
    lab = linear_to_oklab(srgb_to_linear(rgb))
    L = lab[..., 0]
    L = L + experimental["GRAIN_K"] * amount * noise * (4 * L * (1 - L) + 0.2)
    return _with_lightness_keep_chromaticity(rgb, L, lab)


# ------------------------------------------------------------------ light leak (stage effects, rendering-v2.md §6)
# Revision 2 (contract fixes 2, C4): the geometry is the approved prototype's CSS exactly,
# radial-gradient(circle at x% y%, core, ring 30%, transparent 55%) on a frame-sized overlay rotated by
# transform: rotate(). A CSS circle without a size is farthest-corner, so the stops are fractions of the
# distance from the centre to the farthest frame corner. Prism is provisional and not defined here.
LIGHT_LEAK_STYLE_COLOURS = {
    "warm": ((255, 150, 70), (255, 90, 60)),
    "amber": ((255, 176, 64), (230, 120, 40)),
    "rose": ((255, 140, 160), (220, 90, 120)),
}
LIGHT_LEAK_RING_STOP = 0.30
LIGHT_LEAK_END_STOP = 0.55


def light_leak_farthest_corner(height: int, width: int, x_percent: float, y_percent: float) -> float:
    """The CSS farthest-corner gradient ray, in frame pixels, for a leak centred at (x, y) % of the frame."""
    centre_x, centre_y = x_percent / 100 * width, y_percent / 100 * height
    return max(math.hypot(corner_x - centre_x, corner_y - centre_y) for corner_x in (0, width) for corner_y in (0, height))


def light_leak_premultiplied(height: int, width: int, params: dict) -> np.ndarray:
    """The overlay's premultiplied colour (H, W, 3) in [0, 1] at pixel centres, after its rotation."""
    style = params["style"]
    if style not in LIGHT_LEAK_STYLE_COLOURS:
        raise ValueError(f"light leak style {style!r} has no reference (prism is provisional)")
    core, ring = (np.array(c, np.float64) / 255 for c in LIGHT_LEAK_STYLE_COLOURS[style])
    core_alpha, ring_alpha = min(params["intensity"] / 130, 1.0), min(params["intensity"] / 400, 1.0)
    leak_x, leak_y = params["x"] / 100 * width, params["y"] / 100 * height
    ray = light_leak_farthest_corner(height, width, params["x"], params["y"])
    # CSS rotate() is clockwise on screen (y down); sampling undoes it about the frame centre.
    theta = math.radians(params["rotation"])
    cos_t, sin_t = math.cos(theta), math.sin(theta)
    py, px = np.mgrid[0:height, 0:width].astype(np.float64) + 0.5
    dx, dy = px - width / 2, py - height / 2
    qx = width / 2 + cos_t * dx + sin_t * dy
    qy = height / 2 - sin_t * dx + cos_t * dy
    covered = (qx >= 0) & (qx <= width) & (qy >= 0) & (qy <= height)
    t = np.hypot(qx - leak_x, qy - leak_y) / ray
    inner = np.clip(t / LIGHT_LEAK_RING_STOP, 0, 1)[..., None]
    outer = np.clip((t - LIGHT_LEAK_RING_STOP) / (LIGHT_LEAK_END_STOP - LIGHT_LEAK_RING_STOP), 0, 1)[..., None]
    premultiplied = np.where((t <= LIGHT_LEAK_RING_STOP)[..., None],
                             core_alpha * core * (1 - inner) + ring_alpha * ring * inner,
                             ring_alpha * ring * (1 - outer))
    return np.where(covered[..., None], premultiplied, 0.0)


def apply_light_leak(rgb, params: dict):
    """Screen-blend the leak onto an sRGB-encoded frame: out = base + P·(1 − base), P premultiplied."""
    rgb = np.asarray(rgb, np.float64)
    premultiplied = light_leak_premultiplied(rgb.shape[0], rgb.shape[1], params)
    return rgb + premultiplied * (1 - rgb)


def develop_global_with_override(rgb, recipe: dict, model: dict, override_lut: np.ndarray):
    """develop.global when the pack ships a validated Lightroom HALD LUT for the preset (rendering-v2.md §4.4).

    Lightroom's global-only HALD excludes the adaptive tone sliders (the kit neutralises them), so they are
    applied first with the calibrated model, then the HALD LUT: the same order as ingest_kit.full_recipe.
    Contrast is NOT among them; it is inside the HALD.
    """
    g = recipe.get("global", {})
    adaptive: dict = {}
    if "toneSliders" in g:
        adaptive["toneSliders"] = {**g["toneSliders"], "contrast": 0}
    if "dehaze" in g:
        adaptive["dehaze"] = g["dehaze"]
    toned = develop_global(rgb, {"global": adaptive}, model) if adaptive else np.asarray(rgb, dtype=np.float64)
    return apply_lut_trilinear(override_lut, toned)
