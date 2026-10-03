"""reference_model (the executable spec the native ports mirror) against lr_model, the calibrated source of truth.

Run: python -m pytest shared/look-pack/tests -q
These tests need no private preset files.
"""
import json
import math

import numpy as np
import pytest
import torch

import lr_model
import reference_model as rm

MODEL = rm.load_develop_constants()


def oracle(settings: dict, rgb: np.ndarray) -> np.ndarray:
    calib = lr_model.Calib()
    calib.load_state_dict({k: torch.tensor(v) for k, v in MODEL["constants"].items()})
    with torch.no_grad():
        return lr_model.render(torch.from_numpy(rgb.astype(np.float32)), lr_model.Preset(settings, wb_mode="rendered"), calib).numpy()


def recipe_for(settings: dict) -> dict:
    import convert
    recipe, _, malformed = convert.build_recipe(settings, "look-test")
    assert not malformed
    return recipe


RNG = np.random.default_rng(5)
PROBES = np.concatenate([rm.lut_grid(7).reshape(-1, 3), RNG.random((200, 3))])

# One synthetic preset per global operator, plus everything at once (no private files needed).
OPERATOR_SETTINGS = {
    "calibration": {"RedHue": "+40", "RedSaturation": "-5", "GreenHue": "+100", "BlueHue": "-13", "BlueSaturation": "+12"},
    "whiteBalance": {"IncrementalTemperature": "-15", "IncrementalTint": "+19"},
    "exposure": {"Exposure2012": "+0.51"},
    "shadowTint": {"ShadowTint": "-13"},
    "toneSliders": {"Contrast2012": "+52", "Highlights2012": "-24", "Shadows2012": "-28", "Whites2012": "-100", "Blacks2012": "+34"},
    "dehaze": {"Dehaze": "+42"},
    "parametricCurve": {"ParametricShadows": "+43", "ParametricDarks": "+19", "ParametricLights": "-7",
                        "ParametricHighlights": "-13", "ParametricShadowSplit": "14", "ParametricMidtoneSplit": "43"},
    "toneCurve": {"ToneCurvePV2012": ["0, 26", "57, 67", "210, 195", "255, 241"], "ToneCurvePV2012Red": ["0, 10", "255, 240"],
                  "ToneCurvePV2012Blue": ["0, 0", "126, 136", "255, 255"]},
    "hsl": {"HueAdjustmentAqua": "+100", "SaturationAdjustmentBlue": "-100", "LuminanceAdjustmentOrange": "+8",
            "HueAdjustmentRed": "-10", "SaturationAdjustmentGreen": "-90", "LuminanceAdjustmentBlue": "-36"},
    "vibranceSaturation": {"Vibrance": "-26", "Saturation": "-15"},
    "colorGrading": {"SplitToningShadowHue": "55", "SplitToningShadowSaturation": "20", "SplitToningHighlightHue": "209",
                     "SplitToningHighlightSaturation": "12", "ColorGradeMidtoneHue": "87", "ColorGradeMidtoneSat": "12",
                     "ColorGradeGlobalLum": "-6", "ColorGradeBlending": "100", "SplitToningBalance": "+21"},
    "grayscale": {"ConvertToGrayscale": "True", "GrayMixerRed": "-7", "GrayMixerOrange": "-13", "GrayMixerBlue": "+6"},
}


@pytest.mark.parametrize("operator", sorted(OPERATOR_SETTINGS) + ["all"])
def test_develop_global_matches_lr_model(operator):
    settings = {k: v for s in OPERATOR_SETTINGS.values() for k, v in s.items()} if operator == "all" else OPERATOR_SETTINGS[operator]
    recipe = recipe_for(settings)
    if operator != "all":
        assert list(recipe["global"]) == [operator]
    assert np.abs(rm.develop_global(PROBES, recipe, MODEL) - oracle(settings, PROBES)).max() < 5e-4


def test_neutral_recipe_is_identity_within_the_models_floor():
    # Not exactly identity, as in lr_model: OKLab's 1e-7 LMS floor lifts near-black slightly. Ports keep it.
    out = rm.develop_global(PROBES, {"global": {}, "spatial": {}, "finishing": {}}, MODEL)
    assert np.abs(out - PROBES).max() < 1e-4


@pytest.mark.parametrize("seed", range(6))
def test_natural_spline_matches_scipy(seed):
    from scipy.interpolate import CubicSpline
    rng = np.random.default_rng(seed)
    xs = np.sort(rng.choice(np.arange(256), size=rng.integers(3, 9), replace=False)).astype(float)
    ys = rng.random(len(xs))
    q = np.linspace(xs[0], xs[-1], 101)
    assert np.allclose(rm.natural_cubic_spline(xs, ys, q), CubicSpline(xs, ys, bc_type="natural")(q), atol=1e-12)


@pytest.mark.parametrize("raw", [
    ["0, 0", "75, 46", "201, 168", "255, 255"],
    ["0, 26", "57, 67", "210, 195", "255, 241"],
    ["20, 0", "128, 140", "230, 255"],             # held flat outside [x0, xN]
    ["0, 10", "255, 240"],                          # two points: linear
    ["128, 100", "0, 0", "255, 255", "128, 120"],   # unsorted, duplicate x: last wins
])
def test_curve_table_matches_lr_model(raw):
    import convert
    points = convert.curve_points(raw)
    assert np.array_equal(rm.curve_table(points), lr_model.curve_lut(raw))


def test_identity_and_malformed_curves():
    import convert
    assert convert.curve_points(["0, 0", "255, 255"]) is None
    assert convert.curve_points(None) is None
    with pytest.raises(ValueError):
        convert.curve_points(["0, 0", "oops"])


def test_bake_layout_is_blue_slowest_red_fastest():
    lut = rm.bake_global_lut({"global": {}, "spatial": {}, "finishing": {}}, MODEL, 5)
    assert lut.shape == (5, 5, 5, 3) and lut.dtype == np.float32
    b, g, r = 1, 2, 3
    assert np.allclose(lut[b, g, r], [r / 4, g / 4, b / 4], atol=1e-6)
    flat = lut.reshape(-1, 3)
    assert np.allclose(flat[1], [0.25, 0, 0], atol=1e-6), "index 1 steps red"


def test_trilinear_lookup_reproduces_the_function_on_grid_nodes():
    recipe = recipe_for(OPERATOR_SETTINGS["toneSliders"])
    lut = rm.bake_global_lut(recipe, MODEL, 9)
    nodes = rm.lut_grid(9).reshape(-1, 3)
    assert np.abs(rm.apply_lut_trilinear(lut, nodes) - lut.reshape(-1, 3)).max() < 1e-6


def test_strength_mixes_the_global_result_with_its_input():
    developed = rm.develop_global(PROBES, recipe_for(OPERATOR_SETTINGS["exposure"]), MODEL)
    assert np.allclose(rm.apply_strength(PROBES, developed, 0.0), PROBES)
    assert np.allclose(rm.apply_strength(PROBES, developed, 1.0), developed)
    assert np.allclose(rm.apply_strength(PROBES, developed, 0.5), (PROBES + developed) / 2)


# --- spatial and finishing ---------------------------------------------------------------------------

def _photo(h=48, w=64, seed=3):
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w] / np.array([h, w])[:, None, None]
    base = np.stack([0.3 + 0.4 * x, 0.25 + 0.5 * y, 0.5 - 0.2 * x * y], -1)
    return np.clip(base + 0.05 * rng.standard_normal((h, w, 3)), 0, 1)


def test_clarity_texture_match_lr_model():
    img = _photo()
    spatial = MODEL["spatialConstants"]
    calib = lr_model.SpatialCalib()
    calib.load_state_dict({k: torch.tensor(v) for k, v in spatial.items()})
    with torch.no_grad():
        theirs = lr_model.apply_local_contrast(torch.from_numpy(img.astype(np.float32)), 40, -20, calib).numpy()
    assert np.abs(rm.apply_clarity_texture(img, 40, -20, spatial) - theirs).max() < 2e-3


@pytest.mark.parametrize("style,amount", [(1, -30), (1, 25), (2, -40), (3, -50), (3, 40)])
def test_vignette_matches_lr_model(style, amount):
    img = _photo()
    settings = {"PostCropVignetteAmount": str(amount), "PostCropVignetteStyle": str(style), "PostCropVignetteMidpoint": "40",
                "PostCropVignetteFeather": "70", "PostCropVignetteRoundness": "-20", "PostCropVignetteHighlightContrast": "60"}
    with torch.no_grad():
        theirs = lr_model.apply_vignette(torch.from_numpy(img.astype(np.float32)), settings).numpy()
    params = {"amount": amount, "style": style, "midpoint": 40, "feather": 70, "roundness": -20, "highlightContrast": 60}
    assert np.abs(rm.apply_vignette(img, params, MODEL["experimentalConstants"]) - theirs).max() < 2e-3


def test_lowbias32_reference_values():
    def lowbias32(x):  # plain-integer statement of the hash, as the ports write it
        x &= 0xFFFFFFFF
        x ^= x >> 16
        x = (x * 0x7FEB352D) & 0xFFFFFFFF
        x ^= x >> 15
        x = (x * 0x846CA68B) & 0xFFFFFFFF
        return x ^ (x >> 16)
    for x in (0, 1, 2, 255, 0x9E3779B1, 0xFFFFFFFF):
        assert int(rm._lowbias32(x)) == lowbias32(x)


def test_gaussian_field_is_standard_normal_and_deterministic():
    field = rm.gaussian_field(7, 0, 200, 200)
    assert abs(field.mean()) < 0.02 and abs(field.std() - 1) < 0.02
    assert np.array_equal(field, rm.gaussian_field(7, 0, 200, 200))
    assert not np.array_equal(field, rm.gaussian_field(8, 0, 200, 200))


def test_grain_is_resolution_independent():
    """Same grain strength in a preview and an export of the same photo (invariant P=E)."""
    params = {"amount": 50, "size": 25, "roughness": 50, "seed": 11}
    flat = lambda h, w: np.full((h, w, 3), 0.5)
    preview = rm.apply_grain(flat(300, 400), params, MODEL["experimentalConstants"]) - 0.5
    export = rm.apply_grain(flat(900, 1200), params, MODEL["experimentalConstants"]) - 0.5
    assert abs(preview.std() / export.std() - 1) < 0.1
    assert np.allclose(rm.apply_grain(flat(300, 400), params, MODEL["experimentalConstants"]) - 0.5, preview, atol=0)


def test_sharpening_and_noise_reduction_are_neutral_at_zero_and_act_otherwise():
    img = _photo()
    provisional = MODEL["provisionalConstants"]
    neutral_sharpen = {"amount": 0, "radius": 1, "detail": 25, "edgeMasking": 0}
    neutral_nr = {"luminance": 0, "luminanceDetail": 50, "luminanceContrast": 0, "color": 0, "colorDetail": 50, "colorSmoothness": 50}
    assert rm.apply_sharpening(img, neutral_sharpen, provisional) is img
    assert rm.apply_noise_reduction(img, neutral_nr, provisional) is img
    sharpened = rm.apply_sharpening(img, {**neutral_sharpen, "amount": 80, "edgeMasking": 30}, provisional)
    smoothed = rm.apply_noise_reduction(img, {**neutral_nr, "luminance": 60, "color": 50}, provisional)
    detail = lambda im: np.abs(np.diff(im, axis=1)).mean()
    assert detail(sharpened) > detail(img) > detail(smoothed)


def test_override_path_applies_adaptive_tone_then_the_hald_lut():
    settings = {"Contrast2012": "+40", "Highlights2012": "-30", "Shadows2012": "+20", "Dehaze": "+10"}
    recipe = recipe_for(settings)
    identity = rm.lut_grid(33).astype(np.float32)
    out = rm.develop_global_with_override(PROBES, recipe, MODEL, identity)
    adaptive_only = {k: v for k, v in settings.items() if k != "Contrast2012"}  # ingest_kit.SEPARATED_TONE
    assert np.abs(out - oracle(adaptive_only, PROBES)).max() < 1e-3
