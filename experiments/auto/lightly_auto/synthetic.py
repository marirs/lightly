"""Procedural scenes and global degradations for pipeline validation (plan stage (a) mechanics, T3-style).

Why procedural scenes and not the 22 photos: the 22 DEV photos are Unsplash-licensed, and Unsplash Terms
section 8 prohibits ML training use; the plan also says they are never used for training (section 3.1). No
licensed T1/T2 photos exist locally yet. Procedurally generated scenes contain no third-party content, so a
model trained on them has no data-rights encumbrance. They are NOT photo-like enough to say anything about
quality: a smoke run on them measures plumbing (it learns, exports, and stays on the contract), not taste.

Degradations follow plan section 4(a): +-1.5 EV, WB and tint, gamma, contrast, saturation x[0.6, 1.4],
tone-curve flattening, and a phone-like highlight-compressing tone map. 25% of samples are left undegraded
with an identity target. Every degradation is a global per-pixel colour map, so a 3D LUT can represent its
inverse up to clipping.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
from skimage import color as skcolor

REC709_LUMA = np.array([0.2126, 0.7152, 0.0722], np.float32)
IDENTITY_SAMPLE_PROBABILITY = 0.25
COMPONENT_PROBABILITY = 0.6


def srgb_to_linear(x):
    x = np.clip(x, 0.0, 1.0)
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(x):
    x = np.clip(x, 0.0, 1.0)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(x, 1 / 2.4) - 0.055)


def _random_lab_colour(rng: np.random.Generator) -> np.ndarray:
    family = rng.choice(["skin", "foliage", "sky", "neutral", "saturated", "warm"], p=[0.2, 0.15, 0.15, 0.2, 0.15, 0.15])
    if family == "skin":  # spans light to deep skin tones
        lab_l, chroma, hue = rng.uniform(25, 80), rng.uniform(12, 38), rng.uniform(35, 65)
    elif family == "foliage":
        lab_l, chroma, hue = rng.uniform(20, 70), rng.uniform(15, 55), rng.uniform(100, 150)
    elif family == "sky":
        lab_l, chroma, hue = rng.uniform(45, 92), rng.uniform(5, 40), rng.uniform(230, 280)
    elif family == "neutral":
        lab_l, chroma, hue = rng.uniform(5, 97), rng.uniform(0, 6), rng.uniform(0, 360)
    elif family == "warm":  # sunset oranges, wood, sand
        lab_l, chroma, hue = rng.uniform(35, 85), rng.uniform(25, 70), rng.uniform(40, 85)
    else:
        lab_l, chroma, hue = rng.uniform(20, 80), rng.uniform(30, 80), rng.uniform(0, 360)
    lab = np.array([[[lab_l, chroma * np.cos(np.radians(hue)), chroma * np.sin(np.radians(hue))]]])
    return skcolor.lab2rgb(lab)[0, 0].astype(np.float32)


def _smooth_field(rng, height, width, cells, low, high):
    from PIL import Image
    coarse = rng.uniform(low, high, (cells, cells)).astype(np.float32)
    return np.asarray(Image.fromarray(coarse, mode="F").resize((width, height), Image.BICUBIC))


def procedural_scene(rng: np.random.Generator, height: int = 288, width: int = 384) -> np.ndarray:
    """A clean 'scene': horizon gradient, soft ellipses/rectangles, low-frequency shading, optional light
    sources, a scene-level brightness regime (dark / normal / bright) and fine texture. Returns uint8 sRGB."""
    yy, xx = np.mgrid[0:height, 0:width].astype(np.float32)
    yy /= height
    xx /= width
    top, bottom = _random_lab_colour(rng), _random_lab_colour(rng)
    horizon, softness = rng.uniform(0.25, 0.75), rng.uniform(0.02, 0.2)
    blend = 1.0 / (1.0 + np.exp(-(yy - horizon) / softness))
    image = top * (1 - blend[..., None]) + bottom * blend[..., None]
    for _ in range(rng.integers(3, 13)):
        colour = _random_lab_colour(rng)
        cx, cy = rng.uniform(0, 1), rng.uniform(0, 1)
        rx, ry = rng.uniform(0.04, 0.35), rng.uniform(0.04, 0.35)
        edge = rng.uniform(0.01, 0.15)
        if rng.random() < 0.6:
            distance = np.sqrt(((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2) - 1.0
        else:
            distance = np.maximum(np.abs(xx - cx) / rx, np.abs(yy - cy) / ry) - 1.0
        alpha = np.clip(0.5 - distance / (2 * edge / max(rx, ry)), 0, 1)[..., None]
        image = image * (1 - alpha) + colour * alpha
    linear = srgb_to_linear(image) * _smooth_field(rng, height, width, 4, 0.55, 1.35)[..., None]
    regime = rng.choice(["dark", "normal", "bright"], p=[0.2, 0.6, 0.2])
    linear *= {"dark": rng.uniform(0.08, 0.35), "normal": 1.0, "bright": rng.uniform(1.2, 1.8)}[regime]
    if regime == "dark" or rng.random() < 0.15:
        for _ in range(rng.integers(1, 5)):  # point lights: bright warm blobs
            cx, cy, radius = rng.uniform(0, 1), rng.uniform(0, 1), rng.uniform(0.01, 0.05)
            glow = np.exp(-(((xx - cx) ** 2 + (yy - cy) ** 2) / (2 * radius ** 2)))[..., None]
            linear += glow * np.array([1.0, 0.8, 0.5]) * rng.uniform(0.5, 3.0)
    image = linear_to_srgb(linear)
    image += rng.normal(0, rng.uniform(0.003, 0.02), image.shape)
    return np.clip(np.round(np.clip(image, 0, 1) * 255), 0, 255).astype(np.uint8)


@dataclass
class Degradation:
    identity: bool = False
    exposure_ev: float = 0.0
    wb_gains: tuple = (1.0, 1.0, 1.0)
    tone_map_k: float = 0.0  # 0 = off
    gamma: float = 1.0
    contrast: float = 1.0
    saturation: float = 1.0
    flatten: tuple = (0.0, 0.0)
    applied: list = field(default_factory=list)


ALL_COMPONENTS = ("exposure", "white_balance", "phone_tone_map", "gamma", "contrast", "saturation", "flatten")


def sample_degradation(rng: np.random.Generator, components: tuple = ALL_COMPONENTS,
                       identity_probability: float = IDENTITY_SAMPLE_PROBABILITY) -> Degradation:
    """components restricts the family (curriculum / diagnostics). A run is reproducible from its seed and
    component list; different component lists consume the random stream differently."""
    unknown = set(components) - set(ALL_COMPONENTS)
    if unknown:
        raise ValueError(f"unknown degradation components {sorted(unknown)}")
    if rng.random() < identity_probability:
        return Degradation(identity=True)
    d = Degradation()
    while not d.applied:  # at least one component, so non-identity samples are really degraded
        d = _draw_components(rng)
        _drop_components_outside(d, components)
    return d


def _drop_components_outside(d: Degradation, components: tuple) -> None:
    defaults = Degradation()
    resets = {"exposure": ("exposure_ev",), "white_balance": ("wb_gains",), "phone_tone_map": ("tone_map_k",),
              "gamma": ("gamma",), "contrast": ("contrast",), "saturation": ("saturation",), "flatten": ("flatten",)}
    for name in list(d.applied):
        if name not in components:
            for attribute in resets[name]:
                setattr(d, attribute, getattr(defaults, attribute))
            d.applied.remove(name)


def _draw_components(rng: np.random.Generator) -> Degradation:
    d = Degradation()
    if rng.random() < COMPONENT_PROBABILITY:
        d.exposure_ev = float(rng.uniform(-1.5, 1.5)); d.applied.append("exposure")
    if rng.random() < COMPONENT_PROBABILITY:
        gains = np.exp([rng.uniform(-0.25, 0.25), rng.uniform(-0.08, 0.08), rng.uniform(-0.25, 0.25)])
        d.wb_gains = tuple(float(g) for g in gains / (gains @ REC709_LUMA)); d.applied.append("white_balance")
    if rng.random() < 0.35:
        d.tone_map_k = float(rng.uniform(0.5, 3.0)); d.applied.append("phone_tone_map")
    if rng.random() < COMPONENT_PROBABILITY:
        d.gamma = float(np.exp(rng.uniform(-0.3, 0.3))); d.applied.append("gamma")
    if rng.random() < COMPONENT_PROBABILITY:
        d.contrast = float(rng.uniform(0.7, 1.3)); d.applied.append("contrast")
    if rng.random() < COMPONENT_PROBABILITY:
        d.saturation = float(rng.uniform(0.6, 1.4)); d.applied.append("saturation")
    if rng.random() < COMPONENT_PROBABILITY:
        d.flatten = (float(rng.uniform(0, 0.08)), float(rng.uniform(0, 0.08))); d.applied.append("flatten")
    return d


def apply_degradation(clean_rgb8: np.ndarray, d: Degradation) -> np.ndarray:
    """uint8 clean -> uint8 degraded (8-bit quantised, as the app's decoder delivers)."""
    if d.identity:
        return clean_rgb8.copy()
    linear = srgb_to_linear(clean_rgb8.astype(np.float32) / 255.0)
    linear = linear * (2.0 ** d.exposure_ev) * np.array(d.wb_gains, np.float32)
    if d.tone_map_k > 0:  # highlight shoulder: maps 1 -> 1, compresses and lifts mids like phone HDR
        k = d.tone_map_k
        linear = linear * (1 + k) / (linear + k)
    x = linear_to_srgb(linear) ** d.gamma
    x = (x - 0.5) * d.contrast + 0.5
    luma = (np.clip(x, 0, 1) @ REC709_LUMA)[..., None]
    x = luma + (x - luma) * d.saturation
    low, high = d.flatten
    x = np.clip(x, 0, 1) * (1 - low - high) + low
    return np.clip(np.round(x * 255), 0, 255).astype(np.uint8)
