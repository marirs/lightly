"""Codex finding 5: applying the kit's presets one after another must not let a previous Look's settings leak.

Lightroom applies a preset by overwriting only the keys present in it. Several shortlisted originals omit keys
(e.g. 'S1 - Vibes' has no Texture, Dehaze, Grain, Clarity, vignette, midtone grading or parametric shadows), so
a virtual copy that previously held another Look keeps those values. The kit must therefore ship COMPLETE
presets (every look-relevant key explicit) and the README must require a reset copy for every render.
"""
from pathlib import Path
import make_kit

# Modelled on the real 'S1 - Vibes' key set: a tone/colour preset that omits local, grading and effect keys.
PARTIAL = {"ProcessVersion": "11.0", "Exposure2012": "+0.10", "Contrast2012": "+12", "Highlights2012": "-20",
           "Shadows2012": "+15", "HueAdjustmentGreen": "-10", "SaturationAdjustmentBlue": "-15",
           "ToneCurvePV2012": ["0, 10", "128, 128", "255, 250"]}
CONTAMINATION = {"Texture": "+30", "Dehaze": "+20", "GrainAmount": "40", "Clarity2012": "+25",
                 "PostCropVignetteAmount": "-30", "ColorGradeMidtoneSat": "35", "ParametricShadows": "+40",
                 "ToneCurvePV2012Red": ["0, 30", "255, 255"], "ConvertToGrayscale": "True"}


def lightroom_apply(state, preset):
    out = dict(state); out.update({k: v for k, v in preset.items() if k in make_kit.DEVELOP_DEFAULTS}); return out


def test_kit_presets_are_complete_and_overwrite_previous_looks():
    for variant in ("full", "global"):
        preset = make_kit.kit_preset_settings(PARTIAL, variant)
        clean = lightroom_apply(make_kit.DEVELOP_DEFAULTS, preset)
        dirty = lightroom_apply({**make_kit.DEVELOP_DEFAULTS, **CONTAMINATION}, preset)
        leaked = {k for k in make_kit.DEVELOP_DEFAULTS if clean.get(k) != dirty.get(k)}
        assert not leaked, (variant, sorted(leaked))


def test_full_variant_keeps_the_presets_own_values():
    full = make_kit.kit_preset_settings(PARTIAL, "full")
    for k, v in PARTIAL.items():
        if k in make_kit.DEVELOP_DEFAULTS:
            assert full[k] == v, k


def test_readme_requires_reset_copy_for_every_render():
    text = (Path(make_kit.__file__).parent / "README_TEMPLATE.md").read_text().lower()
    assert "reset" in text and "every" in text and "virtual copy" in text
    assert "never apply a look to a copy that already has another look" in text
