"""Evaluation arms. Every arm maps the analysis proxy (uint8 sRGB) to an output of the same size through the
deployment path: 256x256 pinned preprocessing -> a 33^3 LUT -> exact-grid trilinear application.

Labels matter: only a model trained under auto-training-plan.md may ever be presented as AI Auto. Every arm
defined here today is explicitly NOT AI Auto (is_ai_auto=False), and the runner prints that next to results.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Callable

import numpy as np

from .paths import RESEARCH_WEIGHTS_DIR, ia3dlut as ia

REC709_LUMA = np.array([0.2126, 0.7152, 0.0722], np.float32)


def srgb_to_linear(x: np.ndarray) -> np.ndarray:
    x = np.clip(x, 0.0, 1.0)
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4).astype(np.float32)


def linear_to_srgb(x: np.ndarray) -> np.ndarray:
    x = np.clip(x, 0.0, 1.0)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(x, 1 / 2.4) - 0.055).astype(np.float32)


def lut_from_function(per_pixel: Callable[[np.ndarray], np.ndarray], dim: int = ia.LUT_DIM) -> np.ndarray:
    """Tabulate an RGB->RGB function on the identity grid, in the reference layout LUT[c, b, g, r]."""
    grid = np.moveaxis(ia.identity_lut(dim), 0, -1)  # [b, g, r, 3] holding (r, g, b)
    return np.moveaxis(per_pixel(grid.reshape(-1, 3)).reshape(dim, dim, dim, 3), -1, 0).astype(np.float32)


@dataclass
class ArmOutput:
    image: np.ndarray
    info: dict


class Arm:
    name: str = ""
    label: str = ""
    kind: str = ""  # identity | control | research | smoke | candidate
    is_ai_auto: bool = False

    def render(self, proxy_rgb8: np.ndarray) -> ArmOutput:
        raise NotImplementedError

    def describe(self) -> dict:
        return {"name": self.name, "label": self.label, "kind": self.kind, "is_ai_auto": self.is_ai_auto}


def apply_lut_to_rgb8(lut: np.ndarray, rgb8: np.ndarray) -> np.ndarray:
    return ia.to_uint8(ia.apply_lut_reference(lut, rgb8.astype(np.float32) / 255.0, binsize_numerator=1.0))


class OriginalArm(Arm):
    name, kind = "original", "identity"
    label = "Original (unchanged) - NOT AI Auto"

    def render(self, proxy_rgb8):
        return ArmOutput(proxy_rgb8.copy(), {})


class LevelsGreyWorldControlArm(Arm):
    """Fixed, non-learned control: partial grey-world white balance in linear light, then a clamped global
    auto-levels stretch. Statistics come from the same 256x256 view the model sees, so it is a fair global
    control. This is the 'simple heuristic' weights-path.md section 2 mentions as an Android stopgap.
    It is NOT AI Auto and must never be labelled as such."""
    name, kind = "control_levels_greyworld", "control"
    label = "Control: fixed auto-levels + grey-world WB (non-learned) - NOT AI Auto"
    WB_STRENGTH = 0.5          # full grey-world neutralises sunsets; half is a common compromise
    WB_GAIN_RANGE = (0.85, 1.18)
    LEVELS_LOW_PCT, LEVELS_HIGH_PCT = 0.5, 99.5
    MAX_BLACK_POINT, MIN_WHITE_POINT = 0.06, 0.90  # caps keep the stretch mild on low-key/high-key images

    def build_lut(self, x256_chw: np.ndarray) -> tuple[np.ndarray, dict]:
        pixels = np.moveaxis(x256_chw, 0, -1).reshape(-1, 3)
        linear = srgb_to_linear(pixels)
        luminance = linear @ REC709_LUMA
        usable = (pixels.max(-1) < 0.98) & (luminance > 0.02)
        if usable.sum() < 100:
            usable = np.ones(len(pixels), bool)
        channel_means = linear[usable].mean(0)
        grey_gains = float(channel_means @ REC709_LUMA) / np.maximum(channel_means, 1e-6)
        gains = np.clip(1.0 + self.WB_STRENGTH * (grey_gains - 1.0), *self.WB_GAIN_RANGE)
        gains = gains / float(gains @ REC709_LUMA)  # keep luminance of grey unchanged
        balanced = linear_to_srgb(linear * gains)
        luma = balanced @ REC709_LUMA
        black = min(float(np.percentile(luma, self.LEVELS_LOW_PCT)), self.MAX_BLACK_POINT)
        white = max(float(np.percentile(luma, self.LEVELS_HIGH_PCT)), self.MIN_WHITE_POINT)
        black = max(black, 0.0)
        white = min(white, 1.0)

        def develop(rgb):
            out = linear_to_srgb(srgb_to_linear(rgb) * gains)
            return np.clip((out - black) / (white - black), 0.0, 1.0)

        return lut_from_function(develop), {"wb_gains": gains.round(4).tolist(), "black": round(black, 4), "white": round(white, 4)}

    def render(self, proxy_rgb8):
        lut, info = self.build_lut(ia.prepare_256_antialiased(proxy_rgb8))
        return ArmOutput(apply_lut_to_rgb8(lut, proxy_rgb8), info)


class LearnedLutArm(Arm):
    """Classifier -> 3 weights -> fused basis LUT, optionally followed by the M1 experimental guardrails."""

    def __init__(self, name: str, label: str, kind: str, classifier, basis_luts: np.ndarray,
                 guardrails: str = "none", strength: float = 1.0):
        self.name, self.label, self.kind = name, label, kind
        self.classifier, self.basis_luts = classifier.eval(), basis_luts
        self.guardrails, self.strength = guardrails, strength

    def fused_lut(self, proxy_rgb8: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        import torch
        x256 = ia.prepare_256_antialiased(proxy_rgb8)
        with torch.no_grad():
            weights = self.classifier(torch.from_numpy(x256).unsqueeze(0))[0].numpy()
        lut = ia.fuse_luts(self.basis_luts, weights)
        if self.guardrails in ("endpoint", "endpoint_warmhue"):
            lut = ia.endpoint_guardrail(lut)
        lut = ia.blend_toward_identity(lut, self.strength)
        if self.guardrails == "endpoint_warmhue":
            lut = ia.warm_hue_protection(lut)
        return lut, weights

    def render(self, proxy_rgb8):
        lut, weights = self.fused_lut(proxy_rgb8)
        endpoint_fired = bool(np.any(lut[:, 0, 0, 0] < 0) or np.any(lut[:, -1, -1, -1] < 1))
        return ArmOutput(apply_lut_to_rgb8(lut, proxy_rgb8),
                         {"weights": np.round(weights, 4).tolist(), "lut_min": float(lut.min()), "lut_max": float(lut.max()),
                          "endpoints_out_of_range_after_guardrails": endpoint_fired})


def research_arm(variant: str) -> LearnedLutArm:
    """FiveK expert-C research model (M1). INTERNAL EVALUATION ONLY: never shipped, never shown externally,
    never used as a training target (auto-training-plan.md section 5.3)."""
    if not os.path.isdir(RESEARCH_WEIGHTS_DIR):
        raise FileNotFoundError(f"research weights not found at {RESEARCH_WEIGHTS_DIR} (run lut3d/reference/fetch_reference.sh)")
    model = ia.load_reference_model(RESEARCH_WEIGHTS_DIR)
    if variant == "auto100":
        return LearnedLutArm("research_auto100", "Research FiveK model, 100% - RESEARCH-ONLY, never ships, NOT AI Auto",
                             "research", model.classifier_fixed_256, model.basis_luts)
    if variant == "guard75_hp":
        return LearnedLutArm("research_guard75_hp",
                             "Research FiveK model + endpoint / 75% / warm-hue guardrails - RESEARCH-ONLY, never ships, NOT AI Auto",
                             "research", model.classifier_fixed_256, model.basis_luts, guardrails="endpoint_warmhue", strength=0.75)
    raise ValueError(variant)


def trained_run_arm(run_dir: str) -> LearnedLutArm:
    """A model produced by train.py. Its label comes from the run's own card, so a smoke run can never be
    reported as a candidate."""
    import torch
    card = json.load(open(os.path.join(run_dir, "run_card.json")))
    classifier = ia.ReferenceClassifier(include_internal_resize=False)
    classifier.load_state_dict(torch.load(os.path.join(run_dir, "classifier.pt"), map_location="cpu", weights_only=True), strict=True)
    basis = np.load(os.path.join(run_dir, "basis_luts.npy")).astype(np.float32)
    kind = card["kind"]
    label = card["arm_label"]
    return LearnedLutArm(f"{kind}:{card['run_id']}", label, kind, classifier, basis)


class GatedLutArm(LearnedLutArm):
    """A trained run behind a conservative gate (lightly_auto/gating.py). The gate only scales the model's own
    correction toward identity; it never adds a correction, so this is still the learned model, never a fixed
    filter. Its label inherits the run's label, so a gated research candidate is still NOT AI Auto."""

    def __init__(self, base: LearnedLutArm, gate_config):
        super().__init__(f"{base.name}+gate:{gate_config.gate_id}", f"{base.label} + conservative gate {gate_config.gate_id}",
                         base.kind, base.classifier, base.basis_luts)
        self.gate_config = gate_config

    def render(self, proxy_rgb8):
        from .gating import choose_strength, detector_features, detector_probability, preview_profile
        from .paths import AUTO_ROOT
        import torch
        x256 = ia.prepare_256_antialiased(proxy_rgb8)
        with torch.no_grad():
            weights = self.classifier(torch.from_numpy(x256).unsqueeze(0))[0].numpy()
        model_lut = ia.fuse_luts(self.basis_luts, weights)
        profile = preview_profile(x256, model_lut)
        detector_p = None
        if self.gate_config.detector_path:
            detector = json.load(open(os.path.join(AUTO_ROOT, self.gate_config.detector_path)))
            detector_p = detector_probability(detector_features(x256, weights, profile), detector)
        strength, reasons = choose_strength(profile, self.gate_config, detector_p)
        lut = ia.blend_toward_identity(model_lut, strength)
        return ArmOutput(apply_lut_to_rgb8(lut, proxy_rgb8),
                         {"weights": np.round(weights, 4).tolist(), "gate_strength": strength, **reasons})


def build_arm(spec: str) -> Arm:
    if spec == "original":
        return OriginalArm()
    if spec == "control_levels_greyworld":
        return LevelsGreyWorldControlArm()
    if spec.startswith("research_"):
        return research_arm(spec[len("research_"):])
    if spec.startswith("run:"):
        return trained_run_arm(spec[len("run:"):])
    if spec.startswith("gated:"):  # gated:<run_dir>@<gate_config.json>
        from .gating import GateConfig
        run_dir, config_path = spec[len("gated:"):].split("@", 1)
        return GatedLutArm(trained_run_arm(run_dir), GateConfig.load(config_path))
    raise ValueError(f"unknown arm {spec!r}")
