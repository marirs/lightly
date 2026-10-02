"""Class-level aggregation for the S1 rule: class means, pass rates, bootstrap and exact CIs, and MDD.

Every random draw uses the protocol's fixed bootstrap seed, so a summary is a pure function of its inputs.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
from scipy import stats as scipy_stats

from .rubric import applicable_criteria, bound_passes


def percentile_bootstrap_mean(values: np.ndarray, resamples: int, seed: int, level: float) -> tuple[float, float]:
    """Percentile bootstrap CI of the mean, resampling items with replacement."""
    values = np.asarray(values, dtype=np.float64)
    if values.size == 0:
        return (math.nan, math.nan)
    rng = np.random.default_rng(seed)
    draws = rng.integers(0, values.size, size=(resamples, values.size))
    means = values[draws].mean(axis=1)
    alpha = (1.0 - level) / 2.0
    return (float(np.quantile(means, alpha)), float(np.quantile(means, 1.0 - alpha)))


def clopper_pearson(successes: int, trials: int, level: float) -> tuple[float, float]:
    """Exact binomial CI. Stays informative when every image passes or fails (bootstrap gives [p, p])."""
    if trials == 0:
        return (math.nan, math.nan)
    alpha = 1.0 - level
    lower = 0.0 if successes == 0 else float(scipy_stats.beta.ppf(alpha / 2, successes, trials - successes + 1))
    upper = 1.0 if successes == trials else float(scipy_stats.beta.ppf(1 - alpha / 2, successes + 1, trials - successes))
    return (lower, upper)


def minimum_detectable_difference(sigma_of_paired_difference: float, n: int, z_alpha: float = 1.96, z_power: float = 0.8416) -> float:
    """Plan section 6.3: MDD ~= (z_{a/2} + z_power) * sigma_d / sqrt(n)  (~2.8 sigma_d / sqrt(n))."""
    if n <= 0:
        return math.inf
    return (z_alpha + z_power) * sigma_of_paired_difference / math.sqrt(n)


def images_needed_for_mdd(sigma_of_paired_difference: float, target_mdd: float, z_alpha: float = 1.96, z_power: float = 0.8416) -> int:
    if target_mdd <= 0:
        return 10 ** 9
    return int(math.ceil(((z_alpha + z_power) * sigma_of_paired_difference / target_mdd) ** 2))


@dataclass
class CriterionSummary:
    name: str
    bound: dict
    n: int
    mean: float
    ci: tuple
    mean_meets_target: bool


@dataclass
class ClassSummary:
    rubric_class: str
    n_images: int
    n_scorable: int
    n_pass: int
    pass_rate: Optional[float]
    pass_rate_bootstrap_ci: tuple
    pass_rate_exact_ci: tuple
    criteria: list = field(default_factory=list)
    gated: bool = True
    class_passes_S1: Optional[bool] = None
    unscorable_images: list = field(default_factory=list)


def _metric_for_class_mean(name: str, metrics: dict) -> Optional[float]:
    # abs-valued metrics are already absolute in the rubric (skin_abs_dh_deg, warm_abs_dh_deg).
    return metrics.get(name)


def summarise_class(protocol: dict, rubric_class: str, rows: list[dict]) -> ClassSummary:
    """rows: dicts with 'image_id', 'metrics', 'verdict' (ImageVerdict) and 'labels' for one arm and class."""
    rule = protocol["class_rule_S1"]
    boot = rule["ci"]["bootstrap"]
    level = boot["level"]
    scorable = [r for r in rows if r["verdict"].scorable]
    passes = np.array([1.0 if r["verdict"].passed else 0.0 for r in scorable])
    n_pass = int(passes.sum())
    summary = ClassSummary(
        rubric_class=rubric_class, n_images=len(rows), n_scorable=len(scorable), n_pass=n_pass,
        pass_rate=(n_pass / len(scorable)) if scorable else None,
        pass_rate_bootstrap_ci=percentile_bootstrap_mean(passes, boot["resamples"], boot["seed"], level),
        pass_rate_exact_ci=clopper_pearson(n_pass, len(scorable), level),
        unscorable_images=[r["image_id"] for r in rows if not r["verdict"].scorable],
    )
    # Union of criteria that apply to at least one image; each mean is over the images it applies to.
    per_criterion_values: dict[str, list] = {}
    per_criterion_bound: dict[str, dict] = {}
    for r in scorable:
        has_skin = "skin_chroma_ratio" in r["metrics"]
        for name, bound in applicable_criteria(protocol, rubric_class, has_skin, r["labels"]).items():
            value = _metric_for_class_mean(name, r["metrics"])
            if value is not None:
                per_criterion_values.setdefault(name, []).append(value)
                per_criterion_bound[name] = bound
    summary.gated = bool(per_criterion_bound)
    for index, name in enumerate(sorted(per_criterion_values)):
        values = np.array(per_criterion_values[name])
        mean = float(values.mean())
        summary.criteria.append(CriterionSummary(
            name=name, bound=per_criterion_bound[name], n=int(values.size), mean=mean,
            ci=percentile_bootstrap_mean(values, boot["resamples"], boot["seed"] + 1 + index, level),
            mean_meets_target=bound_passes(mean, per_criterion_bound[name])))
    if summary.gated and summary.pass_rate is not None:
        summary.class_passes_S1 = (summary.pass_rate >= rule["min_pass_rate"]
                                   and all(c.mean_meets_target for c in summary.criteria))
    return summary
