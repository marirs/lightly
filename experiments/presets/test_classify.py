"""Regression tests for classify.py (Codex M1 finding 1). Run: python -m pytest test_classify.py -q"""
import lrsettings, classify


def _p(settings):
    return lrsettings.ParsedPreset("test.xmp", "xmp", "t", settings)


def test_profile_only_preset_is_not_complete():
    r = classify.classify(_p({"ProcessVersion": "11.0", "CameraProfile": "Adobe Standard"}))
    assert r["coverage"] == "incomplete" and "CameraProfile" in r["not-implemented"]


def test_embedded_profile_is_neutral():
    r = classify.classify(_p({"ProcessVersion": "11.0", "CameraProfile": "Embedded", "Exposure2012": "+0.50"}))
    assert r["coverage"] == "complete" and r["modelled"] == ["Exposure2012"]


def test_vignette_and_grain_are_experimental_not_complete():
    r = classify.classify(_p({"ProcessVersion": "11.0", "PostCropVignetteAmount": "-20", "GrainAmount": "15"}))
    assert r["coverage"] == "incomplete"
    assert {"PostCropVignetteAmount", "GrainAmount"} <= set(r["experimental"])


def test_clarity_is_experimental_not_complete():
    r = classify.classify(_p({"ProcessVersion": "11.0", "Clarity2012": "+20"}))
    assert r["coverage"] == "incomplete" and r["experimental"] == ["Clarity2012"]


def test_every_modelled_key_is_read_by_renderer():
    assert "Exposure2012" in classify.MODELLED and "CameraProfile" not in classify.MODELLED
    assert "Temperature" not in classify.MODELLED


def test_nothing_reports_validated_without_reference():
    r = classify.classify(_p({"ProcessVersion": "11.0", "Exposure2012": "+0.50"}))
    assert r["validation"] == {"status": "none"}


def test_local_tone_sliders_are_approximated_not_modelled():
    r = classify.classify(_p({"ProcessVersion": "11.0", "Highlights2012": "-40", "Shadows2012": "+30", "Dehaze": "+10"}))
    assert r["uses_approximation"] and set(r["approximated"]) == {"Highlights2012", "Shadows2012", "Dehaze"}
    assert "modelled" not in r
