"""Tests for the experimental vignette and grain operators (contract stage O3).

Properties that must hold regardless of calibration: neutral at zero, correct direction, monotonic in amount,
resolution independence (preview vs export), deterministic grain from a seed, grain strength scales with amount.
Fidelity to Lightroom is NOT tested here; that needs the export kit.
"""
import numpy as np, torch
import lr_model as lm


def _grey(h=300, w=450, v=0.5):
    return torch.full((h, w, 3), v)


def test_vignette_zero_is_identity():
    img = _grey()
    assert torch.equal(lm.apply_vignette(img, {"PostCropVignetteAmount": "0"}), img)


def test_negative_vignette_darkens_corners_not_centre():
    out = lm.apply_vignette(_grey(), {"PostCropVignetteAmount": "-40"})
    h, w = out.shape[:2]
    assert abs(float(out[h // 2, w // 2, 0]) - 0.5) < 0.01
    assert float(out[0, 0, 0]) < 0.45 and float(out[-1, -1, 0]) < 0.45


def test_positive_vignette_brightens_corners():
    out = lm.apply_vignette(_grey(), {"PostCropVignetteAmount": "+40"})
    assert float(out[0, 0, 0]) > 0.55


def test_vignette_monotonic_in_amount():
    corners = [float(lm.apply_vignette(_grey(), {"PostCropVignetteAmount": str(a)})[0, 0, 0]) for a in (-10, -30, -60, -90)]
    assert all(a > b for a, b in zip(corners, corners[1:]))


def test_vignette_resolution_independent():
    s = {"PostCropVignetteAmount": "-50", "PostCropVignetteMidpoint": "40", "PostCropVignetteFeather": "60"}
    big = lm.apply_vignette(_grey(600, 900), s)
    small = lm.apply_vignette(_grey(200, 300), s)
    down = torch.nn.functional.interpolate(big.permute(2, 0, 1)[None], size=(200, 300), mode="area")[0].permute(1, 2, 0)
    assert float((down - small).abs().max()) < 0.01


def test_grain_zero_is_identity_and_seeded():
    img = _grey()
    assert torch.equal(lm.apply_grain(img, {"GrainAmount": "0"}, seed=1), img)
    a = lm.apply_grain(img, {"GrainAmount": "30"}, seed=7); b = lm.apply_grain(img, {"GrainAmount": "30"}, seed=7)
    c = lm.apply_grain(img, {"GrainAmount": "30"}, seed=8)
    assert torch.equal(a, b) and not torch.equal(a, c)


def test_grain_strength_scales_with_amount_and_keeps_mean():
    img = _grey()
    s10 = float((lm.apply_grain(img, {"GrainAmount": "10"}, seed=1) - img).std())
    s50 = float((lm.apply_grain(img, {"GrainAmount": "50"}, seed=1) - img).std())
    assert s50 > 3 * s10 > 0
    assert abs(float(lm.apply_grain(img, {"GrainAmount": "50"}, seed=1).mean()) - 0.5) < 0.01


def test_grain_statistics_resolution_independent():
    """Same visual grain at preview and export size: residual std after area-downsampling to a common size."""
    s = {"GrainAmount": "40", "GrainSize": "25"}
    big = lm.apply_grain(_grey(900, 1350), s, seed=3) - 0.5
    small = lm.apply_grain(_grey(300, 450), s, seed=3) - 0.5
    pool = lambda t: torch.nn.functional.interpolate(t.permute(2, 0, 1)[None], size=(150, 225), mode="area")
    r = float(pool(big).std() / pool(small).std())
    assert 0.6 < r < 1.6, r


# --- Codex re-review issue 2: no "implemented" spatial parameter may be silently ignored ---------------------
import classify

_BASE = {"GrainAmount": "35", "GrainSize": "25", "GrainFrequency": "50",
         "PostCropVignetteAmount": "-40", "PostCropVignetteMidpoint": "50", "PostCropVignetteFeather": "50",
         "PostCropVignetteRoundness": "0", "PostCropVignetteStyle": "1", "PostCropVignetteHighlightContrast": "0"}
_ALT = {"GrainAmount": "70", "GrainSize": "60", "GrainFrequency": "90", "PostCropVignetteAmount": "-80",
        "PostCropVignetteMidpoint": "20", "PostCropVignetteFeather": "90", "PostCropVignetteRoundness": "60",
        "PostCropVignetteStyle": "3", "PostCropVignetteHighlightContrast": "80"}


def _textured(h=240, w=360):
    y, x = torch.meshgrid(torch.linspace(0, 1, h), torch.linspace(0, 1, w), indexing="ij")
    return torch.stack([0.2 + 0.7 * x, 0.15 + 0.8 * y, 0.5 + 0.4 * torch.sin(9 * x)], -1).clamp(0, 1)


def _render_spatial(s):
    return lm.apply_grain(lm.apply_vignette(_textured(), s), s, seed=4)


def test_every_experimental_spatial_parameter_changes_pixels():
    spatial = sorted(k for k in classify.SPATIAL if k != "GrainSeed")
    assert set(spatial) <= set(_BASE), sorted(set(spatial) - set(_BASE))
    base = _render_spatial(_BASE)
    ignored = [k for k in spatial if torch.equal(_render_spatial({**_BASE, k: _ALT[k]}), base)]
    assert not ignored, f"parameters read as implemented but ignored: {ignored}"


def test_grain_frequency_changes_grain_structure_not_strength():
    img = _grey()
    lo = lm.apply_grain(img, {**_BASE, "GrainFrequency": "23"}, seed=2) - img
    hi = lm.apply_grain(img, {**_BASE, "GrainFrequency": "90"}, seed=2) - img
    assert not torch.equal(lo, hi)
    assert 0.7 < float(hi.std() / lo.std()) < 1.4


def test_vignette_styles_differ_and_highlight_priority_protects_highlights():
    bright = _grey(v=0.92)
    s = {"PostCropVignetteAmount": "-60"}
    hp = lm.apply_vignette(bright, {**s, "PostCropVignetteStyle": "1", "PostCropVignetteHighlightContrast": "100"})
    hp0 = lm.apply_vignette(bright, {**s, "PostCropVignetteStyle": "1", "PostCropVignetteHighlightContrast": "0"})
    paint = lm.apply_vignette(bright, {**s, "PostCropVignetteStyle": "3"})
    assert float(hp[0, 0, 0]) > float(hp0[0, 0, 0])            # highlight contrast protects bright corners
    assert not torch.equal(paint, hp0)                          # paint overlay is a different operator
