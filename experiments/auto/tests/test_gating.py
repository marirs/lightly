"""The conservative gate may only scale the model's own correction toward identity."""
import numpy as np

from lightly_auto import gating
from lightly_auto.arms import GatedLutArm, LearnedLutArm, apply_lut_to_rgb8
from lightly_auto.paths import ia3dlut as ia


class _FixedWeights:
    """Stand-in classifier that always returns the same basis weights."""

    def __init__(self, weights):
        import torch
        self.weights = torch.tensor([weights], dtype=torch.float32)

    def eval(self):
        return self

    def __call__(self, _):
        return self.weights


def _brightening_basis() -> np.ndarray:
    identity = ia.identity_lut()
    bright = np.clip(identity * 1.3 + 0.03, 0, 1)
    return np.stack([bright, identity, identity]).astype(np.float32)


def _scene(seed=0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    return (rng.uniform(0.15, 0.6, (48, 64, 3)) * 255).astype(np.uint8)


def _gated(config: gating.GateConfig) -> GatedLutArm:
    base = LearnedLutArm("candidate:test", "test candidate", "candidate", _FixedWeights([1.0, 0.0, 0.0]), _brightening_basis())
    return GatedLutArm(base, config)


def test_soft_threshold_strength():
    assert gating.change_strength(2.0, 0.0) == 1.0
    assert gating.change_strength(2.0, 3.0) == 0.0
    assert abs(gating.change_strength(4.0, 1.0) - 0.75) < 1e-12


def test_large_deadzone_returns_the_photo_unchanged():
    image = _scene()
    output = _gated(gating.GateConfig("big", predicted_change_deadzone_dE00=1e6)).render(image)
    assert output.info["gate_strength"] == 0.0
    assert np.array_equal(output.image, image)


def test_gate_never_exceeds_the_ungated_model_change():
    image = _scene(1)
    ungated = apply_lut_to_rgb8(_brightening_basis()[0], image).astype(int)
    for config in (gating.GateConfig("dz", predicted_change_deadzone_dE00=2.0),
                   gating.GateConfig("scene", use_scene_constraints=True, dark_scene_median_L=100.0, dark_max_median_dL=1.0)):
        out = _gated(config).render(image)
        assert 0.0 <= out.info["gate_strength"] <= 1.0
        assert np.abs(out.image.astype(int) - image).mean() <= np.abs(ungated - image).mean() + 1e-9


def test_dark_scene_constraint_lowers_strength_until_it_holds():
    image = _scene(2)
    config = gating.GateConfig("scene", use_scene_constraints=True, dark_scene_median_L=100.0, dark_max_median_dL=1.0)
    arm = _gated(config)
    x256 = ia.prepare_256_antialiased(image)
    profile = gating.preview_profile(x256, ia.fuse_luts(arm.basis_luts, np.array([1.0, 0.0, 0.0], np.float32)))
    strength, reasons = gating.choose_strength(profile, config)
    index = profile.strengths.index(strength)
    assert profile.median_dL[index] <= 1.0 and strength < 1.0 and reasons["constrained"]


def test_gated_arm_keeps_the_runs_label():
    arm = _gated(gating.GateConfig("dz", predicted_change_deadzone_dE00=1.0))
    assert arm.is_ai_auto is False and "test candidate" in arm.label
