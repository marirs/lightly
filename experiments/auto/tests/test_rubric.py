import numpy as np
import pytest
from skimage import color

from lightly_auto.protocol import load_protocol
from lightly_auto.rubric import analyse_source, compute_metrics, hue_difference_deg, judge_image

PROTOCOL = load_protocol(verify_lock=False)
FACE_BOX = [0.25, 0.25, 0.5, 0.5]


def skin_scene(height=120, width=160):
    """Warm skin-like patch in the middle of a grey-blue background."""
    image = np.zeros((height, width, 3), np.uint8)
    image[:] = (90, 100, 120)
    image[30:90, 40:120] = (200, 150, 120)
    return image


def rotate_hue(rgb8, degrees):
    lab = color.rgb2lab(rgb8)
    angle = np.radians(degrees)
    a, b = lab[..., 1], lab[..., 2]
    lab[..., 1], lab[..., 2] = a * np.cos(angle) - b * np.sin(angle), a * np.sin(angle) + b * np.cos(angle)
    return np.clip(np.round(color.lab2rgb(lab) * 255), 0, 255).astype(np.uint8)


def test_hue_difference_wraps():
    assert hue_difference_deg(np.array([350.0]), np.array([10.0]))[0] == pytest.approx(20.0)
    assert hue_difference_deg(np.array([10.0]), np.array([350.0]))[0] == pytest.approx(-20.0)


def test_identity_output_has_zero_change():
    image = skin_scene()
    source = analyse_source("portrait", image, [FACE_BOX])
    metrics = compute_metrics(source, image.copy())
    assert metrics["dE00_mean"] == 0.0
    assert metrics["skin_abs_dh_deg"] == 0.0
    assert metrics["skin_chroma_ratio"] == pytest.approx(1.0)
    assert metrics["clipLo_pp"] == 0.0 and metrics["clipHi_pp"] == 0.0


def test_known_hue_rotation_is_measured_and_fails_skin_target():
    image = skin_scene()
    source = analyse_source("portrait", image, [FACE_BOX])
    metrics = compute_metrics(source, rotate_hue(image, 8.0))
    assert metrics["skin_dh_deg"] == pytest.approx(8.0, abs=0.8)
    verdict = judge_image(PROTOCOL, "portrait", metrics, {})
    assert verdict.scorable and not verdict.passed
    assert "skin_abs_dh_deg" in verdict.failed_criteria


def test_portrait_without_face_is_unscorable_not_a_free_pass():
    image = skin_scene()
    source = analyse_source("portrait", image, [])
    verdict = judge_image(PROTOCOL, "portrait", compute_metrics(source, image), {})
    assert not verdict.scorable and verdict.passed is None


def test_backlit_identity_fails_because_subject_must_be_raised():
    image = skin_scene()
    source = analyse_source("backlit", image, [])
    verdict = judge_image(PROTOCOL, "backlit", compute_metrics(source, image), {})
    assert verdict.failed_criteria == ["subject_dL"]


def test_backlit_lift_without_new_clipping_passes():
    image = skin_scene()
    source = analyse_source("backlit", image, [])
    lifted = np.clip(image.astype(int) + 10, 0, 253).astype(np.uint8)
    assert judge_image(PROTOCOL, "backlit", compute_metrics(source, lifted), {}).passed


def test_face_underexposed_label_enables_skin_lightness_criterion():
    image = skin_scene()
    source = analyse_source("portrait", image, [FACE_BOX])
    metrics = compute_metrics(source, image)
    assert judge_image(PROTOCOL, "portrait", metrics, {}).passed
    labelled = judge_image(PROTOCOL, "portrait", metrics, {"face_underexposed": True})
    assert labelled.failed_criteria == ["skin_dL"]


def test_night_lift_fails_mood_criterion():
    image = np.full((80, 80, 3), 30, np.uint8)
    source = analyse_source("night", image, [])
    verdict = judge_image(PROTOCOL, "night", compute_metrics(source, np.full_like(image, 50)), {})
    assert "night_p50_dL" in verdict.failed_criteria


def test_landscape_is_reported_but_not_gated():
    image = skin_scene()
    source = analyse_source("landscape", image, [])
    verdict = judge_image(PROTOCOL, "landscape", compute_metrics(source, 255 - image), {})
    assert verdict.passed and verdict.checked_criteria == []


def test_unknown_class_is_rejected():
    image = skin_scene()
    with pytest.raises(KeyError):
        judge_image(PROTOCOL, "food", compute_metrics(analyse_source("landscape", image, []), image), {})
