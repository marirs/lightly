"""Conservative gating of a learned Auto LUT: decide HOW MUCH of the model's own correction to apply.

A gate never adds a correction of its own. It only chooses a strength s in [0, 1] and applies
    gated LUT = identity + s * (model LUT - identity)            (ia3dlut.blend_toward_identity)
so s = 0 returns the photo unchanged and s = 1 is the ungated model. A gate is therefore not a fixed filter
and cannot be passed off as one: with the model removed there is nothing left to apply.

Everything the gate looks at is computed on the pinned 256x256 model input and on the model's fused LUT,
so the same decision can run on device before the full-resolution render. The two mechanisms are:

  1. Predicted-change shrinkage (an "already-good" gate). m = mean dE00 between the 256 input and the model's
     output on it. The model's correction is shrunk so the applied change is roughly max(0, m - deadzone):
         s_change = 0                       if m <= deadzone
                  = (m - deadzone) / m      otherwise          (soft threshold on change magnitude)
     Rationale: on validation, photos that need nothing still get a correction from the model (identity drift
     ~3 dE00), and degraded photos get larger ones. Soft thresholding keeps most of a large correction and
     removes small ones entirely.

  1b. Optional learned "needs correction" detector (detector_path). A logistic regression over preview
     statistics, the model's three basis weights and the predicted change, fitted on the TRAIN split (clean vs
     synthetically degraded copies) by gate_study.py; its threshold is chosen on validation. When its
     probability is below detector_threshold the strength is 0 (photo left unchanged).

  2. Scene-aware constraints. Starting from s_change, the strength is lowered (never raised) along a fixed
     grid until every applicable constraint holds on the 256 preview of the gated output:
       * dark scenes (median L* of the input below dark_scene_median_L): median L* may rise by at most
         dark_max_median_dL and new black clipping may grow by at most max_new_clip_pp;
       * warm-highlight scenes (share of warm, chromatic, bright pixels at least warm_scene_min_share):
         warm chroma ratio must stay >= warm_min_chroma_ratio and the median warm hue shift within
         warm_max_abs_dh_deg;
       * every scene: new highlight clipping may grow by at most max_new_clip_pp.
     These are the spec's "must preserve" requirements (spec.md section 1.1), checked with thresholds
     deliberately TIGHTER than PROTOCOL.json so that the 256 preview predicts the full-resolution rubric
     with margin. Because they mirror the rubric, a gate that uses them makes the rubric pass partly by
     construction: the rubric then says even less about whether the correction helps (see the report).

Thresholds come only from the validation split of CC0REF (and DEV-22); see gate_study.py. They are frozen per
gate in a JSON config (gating/*.json) before any frozen-set run.
"""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass

import numpy as np
from skimage import color

from .paths import ia3dlut as ia

STRENGTH_GRID_STEP = 0.05  # the constraint search lowers s in these steps; 21 points from 0 to 1


@dataclass(frozen=True)
class GateConfig:
    gate_id: str
    # 1. predicted-change shrinkage. deadzone 0 disables it.
    predicted_change_deadzone_dE00: float = 0.0
    # 2. scene-aware constraints. use_scene_constraints False disables all of them.
    use_scene_constraints: bool = False
    dark_scene_median_L: float = 35.0
    dark_max_median_dL: float = 1.5
    warm_scene_min_share: float = 0.02
    warm_min_chroma_ratio: float = 0.98
    warm_max_abs_dh_deg: float = 2.5
    max_new_clip_pp: float = 0.25
    # 1b. learned detector. Empty path disables it. Path is relative to experiments/auto.
    detector_path: str = ""
    detector_threshold: float = 0.5

    @staticmethod
    def load(path: str) -> "GateConfig":
        payload = json.load(open(path))
        return GateConfig(**payload["gate"])

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class PreviewProfile:
    """Per-strength predictions on the 256 preview. Index i of every list is strength strengths[i]."""
    strengths: list
    predicted_change_dE00: float      # mean dE00(preview, model output at s = 1)
    input_median_L: float
    warm_share: float
    median_dL: list
    new_clip_lo_pp: list
    new_clip_hi_pp: list
    warm_chroma_ratio: list           # None entries when the scene has no warm pixels
    warm_abs_dh_deg: list


def strength_grid() -> np.ndarray:
    return np.round(np.arange(0.0, 1.0 + 1e-9, STRENGTH_GRID_STEP), 4)


def _clip_fractions(rgb8: np.ndarray) -> tuple[float, float]:
    # Same definitions as the rubric: black = all channels <= 1, highlight = any channel >= 254.
    return float((rgb8 <= 1).all(-1).mean()), float((rgb8 >= 254).any(-1).mean())


def preview_profile(x256_chw: np.ndarray, model_lut: np.ndarray) -> PreviewProfile:
    """Everything the gate needs, from the model input and the model's (ungated) fused LUT only."""
    preview_float = np.moveaxis(x256_chw, 0, -1).astype(np.float32)
    preview8 = ia.to_uint8(preview_float)
    # Trilinear application is linear in the LUT, so the gated output at strength s is exactly
    # input + s * (model output - input) before rounding; one LUT application serves every s.
    model_out = ia.apply_lut_reference(model_lut, preview8.astype(np.float32) / 255.0, binsize_numerator=1.0)
    base = preview8.astype(np.float32) / 255.0
    lab0 = color.rgb2lab(preview8)
    L0 = lab0[..., 0]
    C0 = np.hypot(lab0[..., 1], lab0[..., 2])
    H0 = np.degrees(np.arctan2(lab0[..., 2], lab0[..., 1])) % 360.0
    warm = (H0 > 20) & (H0 < 95) & (C0 > 20) & (L0 > np.percentile(L0, 60))  # rubric's sunset warm mask
    clip_lo0, clip_hi0 = _clip_fractions(preview8)
    profile = PreviewProfile(strengths=strength_grid().tolist(), predicted_change_dE00=0.0,
                             input_median_L=float(np.median(L0)), warm_share=float(warm.mean()),
                             median_dL=[], new_clip_lo_pp=[], new_clip_hi_pp=[], warm_chroma_ratio=[], warm_abs_dh_deg=[])
    for strength in profile.strengths:
        out8 = ia.to_uint8(base + strength * (model_out - base))
        lab1 = color.rgb2lab(out8)
        if strength == 1.0:
            profile.predicted_change_dE00 = float(color.deltaE_ciede2000(lab0, lab1).mean())
        clip_lo, clip_hi = _clip_fractions(out8)
        profile.median_dL.append(float(np.median(lab1[..., 0]) - np.median(L0)))
        profile.new_clip_lo_pp.append((clip_lo - clip_lo0) * 100.0)
        profile.new_clip_hi_pp.append((clip_hi - clip_hi0) * 100.0)
        if warm.any():
            C1 = np.hypot(lab1[..., 1], lab1[..., 2])[warm]
            H1 = np.degrees(np.arctan2(lab1[..., 2], lab1[..., 1]))[warm] % 360.0
            dh = ((H1 - H0[warm] + 180.0) % 360.0) - 180.0
            profile.warm_chroma_ratio.append(float(C1.mean() / max(C0[warm].mean(), 1e-3)))
            profile.warm_abs_dh_deg.append(float(abs(np.median(dh))))
        else:
            profile.warm_chroma_ratio.append(None)
            profile.warm_abs_dh_deg.append(None)
    return profile


DETECTOR_FEATURES = ["log_predicted_change", "w0", "w1", "w2", "L_p1", "L_p5", "L_p50", "L_p95", "L_p99",
                     "chroma_mean", "chroma_std", "a_mean", "b_mean", "clip_lo", "clip_hi", "warm_share"]


def detector_features(x256_chw: np.ndarray, weights: np.ndarray, profile: PreviewProfile) -> dict:
    """Deployable features: the 256 preview, the model's own basis weights and its predicted change."""
    preview8 = ia.to_uint8(np.moveaxis(x256_chw, 0, -1).astype(np.float32))
    lab = color.rgb2lab(preview8)
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    chroma = np.hypot(a, b)
    clip_lo, clip_hi = _clip_fractions(preview8)
    p1, p5, p50, p95, p99 = np.percentile(L, [1, 5, 50, 95, 99])
    return {"log_predicted_change": float(np.log(max(profile.predicted_change_dE00, 1e-3))),
            "w0": float(weights[0]), "w1": float(weights[1]), "w2": float(weights[2]),
            "L_p1": float(p1), "L_p5": float(p5), "L_p50": float(p50), "L_p95": float(p95), "L_p99": float(p99),
            "chroma_mean": float(chroma.mean()), "chroma_std": float(chroma.std()),
            "a_mean": float(a.mean()), "b_mean": float(b.mean()), "clip_lo": clip_lo, "clip_hi": clip_hi,
            "warm_share": profile.warm_share}


def detector_probability(features: dict, detector: dict) -> float:
    """Logistic regression stored as JSON (mean, scale, coef, intercept); no sklearn at inference."""
    x = np.array([features[name] for name in detector["features"]], np.float64)
    z = (x - np.array(detector["mean"])) / np.array(detector["scale"])
    logit = float(z @ np.array(detector["coef"]) + detector["intercept"])
    return float(1.0 / (1.0 + np.exp(-logit)))


def change_strength(predicted_change: float, deadzone: float) -> float:
    if deadzone <= 0.0:
        return 1.0
    if predicted_change <= deadzone:
        return 0.0
    return (predicted_change - deadzone) / predicted_change


def constraints_hold(profile: PreviewProfile, index: int, config: GateConfig) -> bool:
    if profile.new_clip_hi_pp[index] > config.max_new_clip_pp:
        return False
    if profile.input_median_L < config.dark_scene_median_L:
        if profile.median_dL[index] > config.dark_max_median_dL or profile.new_clip_lo_pp[index] > config.max_new_clip_pp:
            return False
    if profile.warm_share >= config.warm_scene_min_share and profile.warm_chroma_ratio[index] is not None:
        if (profile.warm_chroma_ratio[index] < config.warm_min_chroma_ratio
                or profile.warm_abs_dh_deg[index] > config.warm_max_abs_dh_deg):
            return False
    return True


def choose_strength(profile: PreviewProfile, config: GateConfig, detector_p: float | None = None) -> tuple[float, dict]:
    """Returns (strength, reasons). The constraint search only ever lowers the strength. detector_p is the
    learned detector's probability that the photo needs correction (required when config.detector_path)."""
    s_change = change_strength(profile.predicted_change_dE00, config.predicted_change_deadzone_dE00)
    if config.detector_path:
        if detector_p is None:
            raise ValueError("gate has a detector but no detector probability was supplied")
        if detector_p < config.detector_threshold:
            s_change = 0.0
    reasons = {"predicted_change_dE00": round(profile.predicted_change_dE00, 4), "s_change": round(s_change, 4),
               "detector_p": None if detector_p is None else round(detector_p, 4),
               "dark_scene": profile.input_median_L < config.dark_scene_median_L,
               "warm_scene": profile.warm_share >= config.warm_scene_min_share}
    if not config.use_scene_constraints or s_change == 0.0:
        return s_change, reasons
    grid = profile.strengths
    # Constraints are evaluated on the grid; s_change itself is first rounded DOWN onto the grid so the
    # chosen point is one that was actually checked.
    start = int(np.floor(s_change / STRENGTH_GRID_STEP + 1e-9))
    for index in range(start, -1, -1):
        if constraints_hold(profile, index, config):
            reasons["constrained"] = index < start
            return float(grid[index]), reasons
    reasons["constrained"] = True
    return 0.0, reasons
