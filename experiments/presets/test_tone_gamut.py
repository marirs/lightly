"""Basic-tone luminance changes must stay inside the colour gamut.

render() applies tone as a luminance ratio to keep hue. For a near-black saturated pixel (e.g. pure
dark blue) almost all luminance must come from one channel, so a lift multiplied that channel far
out of range: Nordic Tone (10) turned the darkest blues bright blue (0.017, 0.158, 0.877). Lightroom
cannot brighten a near-black shadow into a saturated mid-tone. Run: python -m pytest test_tone_gamut.py -q
"""
import json
from pathlib import Path

import pytest
import torch

import lr_model as lm

HERE = Path(__file__).parent


def calib():
    C = lm.Calib()
    C.load_state_dict({k: torch.tensor(v) for k, v in json.load(open(HERE / "calibration_natural.json"))["constants"].items()})
    return C


def nordic_like_preset():
    # The values that triggered it in Nordic Tone (10): camera-calibration Blue Saturation +8 and Green
    # Saturation -32 push a pure dark blue's red and green below zero, so its luminance is ~0 and the
    # basic-tone ratio (target / luminance) exploded. Tone values are the preset's own.
    return lm.Preset({"Exposure2012": "-0.15", "Contrast2012": "+8", "Highlights2012": "-28", "Shadows2012": "+17",
                      "Whites2012": "-43", "Blacks2012": "+17", "BlueSaturation": "+8", "GreenSaturation": "-32"},
                     wb_mode="rendered")


def test_near_black_saturated_pixels_stay_dark_and_ordered():
    C, p = calib(), nordic_like_preset()
    dark_blues = torch.tensor([[0.0, 0.0, b / 32] for b in range(1, 6)])
    with torch.no_grad():
        out = lm.render(dark_blues, p, C)
    # Before the fix every one of these became (0.017, 0.158, 0.877).
    assert float(out.max()) < 0.3, out
    assert torch.all(out[1:, 2] >= out[:-1, 2] - 1e-4), "blue must not decrease as the input gets brighter"


def test_luminance_ratio_fills_with_neutral_instead_of_leaving_the_gamut():
    lin = torch.tensor([[0.0, 0.0, 0.01]])        # dark pure blue, luminance 0.000722
    target = torch.tensor([[0.2]])                # a lift far beyond what blue alone can carry
    out = lm.apply_luminance(lin, target)
    assert float(out.max()) <= 1.0 + 1e-6
    assert float((out @ torch.tensor([0.2126, 0.7152, 0.0722]))[0]) == pytest.approx(0.2, abs=1e-4)
    assert float(out[0, 2]) >= float(out[0, 1]) >= 0 and float(out[0, 0]) > 0  # still bluish, now partly neutral


def test_luminance_ratio_is_a_pure_ratio_inside_the_gamut():
    lin = torch.tensor([[0.10, 0.20, 0.05]])
    Y = lin @ torch.tensor([0.2126, 0.7152, 0.0722])
    out = lm.apply_luminance(lin, Y.unsqueeze(-1) * 1.5)
    assert torch.allclose(out, lin * 1.5, atol=1e-6)


def test_in_gamut_pixels_keep_channel_order():
    C, p = calib(), nordic_like_preset()
    torch.manual_seed(0)
    midtones = torch.rand(256, 3) * 0.5 + 0.25
    with torch.no_grad():
        out = lm.render(midtones, p, C)
    assert float(lm.srgb_to_linear(out).max()) <= 1.0 + 1e-5
