import numpy as np
import pytest

from lightly_auto.protocol import load_protocol
from lightly_auto.rubric import ImageVerdict
from lightly_auto.stats import (clopper_pearson, images_needed_for_mdd, minimum_detectable_difference,
                                percentile_bootstrap_mean, summarise_class)

PROTOCOL = load_protocol(verify_lock=False)


def test_clopper_pearson_known_values():
    lower, upper = clopper_pearson(3, 3, 0.95)
    assert lower == pytest.approx(0.025 ** (1 / 3), abs=1e-6) and upper == 1.0
    lower, upper = clopper_pearson(0, 3, 0.95)
    assert lower == 0.0 and upper == pytest.approx(1 - 0.025 ** (1 / 3), abs=1e-6)


def test_bootstrap_is_deterministic_and_degenerate_when_all_pass():
    values = np.array([1.0, 0.0, 1.0, 1.0, 0.0])
    assert percentile_bootstrap_mean(values, 2000, 7, 0.95) == percentile_bootstrap_mean(values, 2000, 7, 0.95)
    assert percentile_bootstrap_mean(np.ones(3), 2000, 7, 0.95) == (1.0, 1.0)


def test_mdd_matches_plan_example():
    # Plan section 6.3: sigma_d ~ 2 and n = 40 gives an MDD of about 0.9.
    assert minimum_detectable_difference(2.0, 40) == pytest.approx(0.886, abs=0.01)
    assert images_needed_for_mdd(2.0, 0.886) <= 41


def _row(image_id, dE, passed):
    verdict = ImageVerdict(scorable=True, passed=passed, failed_criteria=[] if passed else ["dE00_mean"])
    return {"image_id": image_id, "metrics": {"dE00_mean": dE}, "verdict": verdict, "labels": {}}


def test_class_fails_s1_when_pass_rate_below_80_percent():
    rows = [_row("a", 1.0, True), _row("b", 1.0, True), _row("c", 5.0, False)]
    summary = summarise_class(PROTOCOL, "already_good", rows)
    assert summary.pass_rate == pytest.approx(2 / 3)
    assert summary.criteria[0].mean_meets_target  # mean 2.33 <= 3
    assert summary.class_passes_S1 is False


def test_class_fails_s1_when_mean_misses_target_even_if_rate_is_high():
    rows = [_row(str(i), 2.9, True) for i in range(8)] + [_row("x", 30.0, False)]
    summary = summarise_class(PROTOCOL, "already_good", rows)
    assert summary.pass_rate == pytest.approx(8 / 9)
    assert not summary.criteria[0].mean_meets_target
    assert summary.class_passes_S1 is False


def test_ungated_class_reports_no_s1_verdict():
    rows = [{"image_id": "l", "metrics": {"dE00_mean": 9.0}, "verdict": ImageVerdict(True, True), "labels": {}}]
    summary = summarise_class(PROTOCOL, "landscape", rows)
    assert summary.gated is False and summary.class_passes_S1 is None
