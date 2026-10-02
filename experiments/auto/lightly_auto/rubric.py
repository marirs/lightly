"""Per-image rubric metrics and pass/fail against PROTOCOL.json (spec.md section 1.1).

Metric definitions are the ones in experiments/lut3d/reference/evaluate.py (M1), factored into a library so
the same code scores baselines, smoke runs and future candidates. Two deliberate additions:
  * absolute-valued hue shifts (skin_abs_dh_deg, warm_abs_dh_deg), because the targets are |dh| <= 4 deg
    and a class mean of signed shifts could cancel out;
  * the source-side analysis (Lab, masks) is computed once per image and shared by every arm.

The rubric measures PRESERVATION plus a few testable corrections. An unchanged Original passes most of it by
construction; it is a necessary condition, not evidence of improvement. Improvement is the preference
study's job (auto-training-plan.md section 5.3).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

import numpy as np
from skimage import color

SKIN_MASK_MIN_PIXELS = 50  # same as M1 evaluate.py


def hue_difference_deg(hue_from: np.ndarray, hue_to: np.ndarray) -> np.ndarray:
    """Signed shortest-arc hue difference in degrees, in (-180, 180]."""
    return ((hue_to - hue_from + 180.0) % 360.0) - 180.0


@dataclass
class LabView:
    lightness: np.ndarray
    chroma: np.ndarray
    hue_deg: np.ndarray
    lab: np.ndarray

    @staticmethod
    def from_rgb8(rgb8: np.ndarray) -> "LabView":
        lab = color.rgb2lab(rgb8)
        return LabView(lab[..., 0], np.hypot(lab[..., 1], lab[..., 2]),
                       np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360.0, lab)


@dataclass
class SourceAnalysis:
    """Everything about the ORIGINAL image that the metrics need. Masks are defined on the original only,
    so every arm is measured on the same pixels."""
    rubric_class: str
    rgb8: np.ndarray
    lab_view: LabView
    face_boxes: list
    skin_mask: Optional[np.ndarray] = None
    warm_mask: Optional[np.ndarray] = None
    subject_mask: Optional[np.ndarray] = None
    highlight_mask: Optional[np.ndarray] = None
    clip_lo_fraction: float = 0.0
    clip_hi_fraction: float = 0.0


def _clip_fractions(rgb8: np.ndarray) -> tuple[float, float]:
    # Same definitions as M1: black clip = all channels <= 1, highlight clip = any channel >= 254.
    return float((rgb8 <= 1).all(-1).mean()), float((rgb8 >= 254).any(-1).mean())


def _skin_mask(view: LabView, face_boxes: list) -> Optional[np.ndarray]:
    """Central 60% of each face box, restricted to skin-like hue/chroma in the original (M1 definition)."""
    if not face_boxes:
        return None
    height, width = view.lightness.shape
    mask = np.zeros((height, width), bool)
    for x, y, box_w, box_h in face_boxes:
        x0, y0 = int((x + 0.2 * box_w) * width), int((y + 0.2 * box_h) * height)
        mask[y0:int(y0 + 0.6 * box_h * height), x0:int(x0 + 0.6 * box_w * width)] = True
    mask &= (view.hue_deg > 10) & (view.hue_deg < 90) & (view.chroma > 5) & (view.lightness > 8)
    return mask if mask.sum() > SKIN_MASK_MIN_PIXELS else None


def analyse_source(rubric_class: str, rgb8: np.ndarray, face_boxes: list) -> SourceAnalysis:
    view = LabView.from_rgb8(rgb8)
    analysis = SourceAnalysis(rubric_class, rgb8, view, list(face_boxes))
    analysis.clip_lo_fraction, analysis.clip_hi_fraction = _clip_fractions(rgb8)
    analysis.skin_mask = _skin_mask(view, face_boxes)
    L0, C0, H0 = view.lightness, view.chroma, view.hue_deg
    if rubric_class == "sunset":
        warm = (H0 > 20) & (H0 < 95) & (C0 > 20) & (L0 > np.percentile(L0, 60))
        analysis.warm_mask = warm if warm.any() else None
    if rubric_class == "backlit":
        height, width = L0.shape
        if face_boxes:
            x, y, box_w, box_h = face_boxes[0]
            subject = np.zeros((height, width), bool)
            subject[int(y * height):int((y + box_h) * height), int(x * width):int((x + box_w) * width)] = True
        else:
            subject = L0 <= np.percentile(L0, 30)
        analysis.subject_mask = subject
        analysis.highlight_mask = L0 >= np.percentile(L0, 90)
    return analysis


def compute_metrics(source: SourceAnalysis, out8: np.ndarray) -> dict:
    """All rubric metrics for one arm's output against the original. Keys absent = not applicable."""
    assert out8.shape == source.rgb8.shape and out8.dtype == np.uint8, (out8.shape, out8.dtype)
    v0, v1 = source.lab_view, LabView.from_rgb8(out8)
    out_clip_lo, out_clip_hi = _clip_fractions(out8)
    metrics = {
        "dE00_mean": float(color.deltaE_ciede2000(v0.lab, v1.lab).mean()),
        "dL_mean": float(v1.lightness.mean() - v0.lightness.mean()),
        "chroma_ratio_all": float(v1.chroma.mean() / max(v0.chroma.mean(), 1e-3)),
        "clipLo_pp": (out_clip_lo - source.clip_lo_fraction) * 100.0,
        "clipHi_pp": (out_clip_hi - source.clip_hi_fraction) * 100.0,
    }
    if source.skin_mask is not None:
        m = source.skin_mask
        skin_dh = float(np.median(hue_difference_deg(v0.hue_deg[m], v1.hue_deg[m])))
        metrics.update(skin_dh_deg=skin_dh, skin_abs_dh_deg=abs(skin_dh),
                       skin_chroma_ratio=float(v1.chroma[m].mean() / v0.chroma[m].mean()),
                       skin_dL=float(v1.lightness[m].mean() - v0.lightness[m].mean()))
    if source.warm_mask is not None:
        m = source.warm_mask
        warm_dh = float(np.median(hue_difference_deg(v0.hue_deg[m], v1.hue_deg[m])))
        metrics.update(warm_chroma_ratio=float(v1.chroma[m].mean() / v0.chroma[m].mean()),
                       warm_dh_deg=warm_dh, warm_abs_dh_deg=abs(warm_dh))
    if source.rubric_class == "night":
        metrics.update(night_p5_dL=float(np.percentile(v1.lightness, 5) - np.percentile(v0.lightness, 5)),
                       night_p50_dL=float(np.median(v1.lightness) - np.median(v0.lightness)))
    if source.subject_mask is not None:
        metrics.update(subject_dL=float(v1.lightness[source.subject_mask].mean() - v0.lightness[source.subject_mask].mean()),
                       highlight_dL=float(v1.lightness[source.highlight_mask].mean() - v0.lightness[source.highlight_mask].mean()))
    return metrics


# ----------------------------------------------------------------------------------------------- verdicts

def bound_passes(value: float, bound: dict) -> bool:
    if "max" in bound and not value <= bound["max"]:
        return False
    if "min" in bound and not value >= bound["min"]:
        return False
    if "min_exclusive" in bound and not value > bound["min_exclusive"]:
        return False
    return True


@dataclass
class ImageVerdict:
    scorable: bool
    passed: Optional[bool]  # None when unscorable
    failed_criteria: list = field(default_factory=list)
    missing_criteria: list = field(default_factory=list)
    checked_criteria: list = field(default_factory=list)


def applicable_criteria(protocol: dict, rubric_class: str, has_skin_mask: bool, labels: dict) -> dict:
    """Criterion name -> bound for this image: the class's gated criteria, plus skin criteria when the
    image has faces, plus conditional criteria whose label is set on the image."""
    criteria_by_class = protocol["criteria"]
    if rubric_class not in criteria_by_class or rubric_class == "skin":
        raise KeyError(f"unknown rubric class {rubric_class!r}")
    class_entry = criteria_by_class[rubric_class]
    applicable = dict(class_entry.get("gated", {}))
    skin = criteria_by_class["skin"]
    # requires_skin: a portrait whose face mask is missing must surface as unscorable, not as a free pass.
    if has_skin_mask or class_entry.get("requires_skin", False):
        applicable.update(skin["gated"])
        for name, bound in skin.get("conditional", {}).items():
            if labels.get(bound["only_if_label"]) is True:
                applicable[name] = {k: v for k, v in bound.items() if k != "only_if_label"}
    return applicable


def judge_image(protocol: dict, rubric_class: str, metrics: dict, labels: dict) -> ImageVerdict:
    criteria = applicable_criteria(protocol, rubric_class, "skin_chroma_ratio" in metrics, labels)
    verdict = ImageVerdict(scorable=True, passed=True)
    for name, bound in sorted(criteria.items()):
        if name not in metrics:
            verdict.missing_criteria.append(name)
            continue
        verdict.checked_criteria.append(name)
        if not bound_passes(metrics[name], bound):
            verdict.failed_criteria.append(name)
    if verdict.missing_criteria:
        verdict.scorable, verdict.passed = False, None
    else:
        verdict.passed = not verdict.failed_criteria
    return verdict
