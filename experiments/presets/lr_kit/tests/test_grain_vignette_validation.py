"""Full-recipe validation for Looks with grain and vignette.

Grain is random, so per-pixel dE cannot match Lightroom even when the grain is right. The comparison must be
grain-insensitive (dE after a blur matched to grain size) AND check grain strength separately, so a recipe that
simply omits grain does not pass.
"""
import numpy as np, torch
import lr_model as lm
from test_f7_two_validations import _kit

SETTINGS = {"ProcessVersion": "11.0", "GrainAmount": "35", "GrainSize": "25", "PostCropVignetteAmount": "-20"}


def _lightroom(seed, with_grain=True):
    def full(src, glob_img):
        with torch.no_grad():
            x = lm.apply_vignette(torch.from_numpy(glob_img.astype(np.float32)), SETTINGS)
            return (lm.apply_grain(x, SETTINGS, seed=seed) if with_grain else x).numpy()
    return full


def test_grain_from_a_different_seed_still_validates(tmp_path):
    look = _kit(tmp_path, SETTINGS, _lightroom(seed=12345))
    assert look["full"]["unimplemented"] == []
    assert look["full"]["status"] == "validated", look["full"]


def test_recipe_grain_vs_lightroom_without_grain_fails(tmp_path):
    look = _kit(tmp_path, SETTINGS, _lightroom(seed=0, with_grain=False))
    assert look["full"]["status"] == "failed"
    assert any(not p.get("grain_ok", True) for p in look["full"]["photos"].values())
