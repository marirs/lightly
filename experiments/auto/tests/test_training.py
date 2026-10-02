import os

import numpy as np
import pytest
import torch
from skimage import color as skcolor

from lightly_auto import synthetic
from lightly_auto.arms import trained_run_arm
from lightly_auto.lut_torch import (WarmHuePenalty, apply_lut_batch, deployment_preprocess, endpoint_penalty,
                                    fuse_basis, rgb_to_lab_torch, tv_and_monotonicity)
from lightly_auto.manifest import TrainingRightsError, assert_training_rights, load_manifest
from lightly_auto.paths import AUTO_ROOT, ia3dlut as ia


def test_training_preprocess_is_bitwise_the_pinned_deployment_resize():
    image = np.random.default_rng(0).integers(0, 256, (301, 517, 3), dtype=np.uint8)
    training = deployment_preprocess(torch.from_numpy(image).permute(2, 0, 1)[None].float() / 255.0)[0].numpy()
    np.testing.assert_array_equal(training, ia.prepare_256_antialiased(image))


def test_differentiable_trilinear_matches_contract_reference():
    rng = np.random.default_rng(1)
    lut = (ia.identity_lut() + rng.normal(0, 0.05, (3, 33, 33, 33))).astype(np.float32)
    image = rng.random((40, 50, 3)).astype(np.float32)
    image[0, 0] = 1.0  # exact upper grid edge
    image[0, 1] = 0.0
    expected = ia.apply_lut_reference(lut, image, binsize_numerator=1.0)
    actual = apply_lut_batch(torch.from_numpy(lut)[None], torch.from_numpy(image).permute(2, 0, 1)[None])[0].permute(1, 2, 0).numpy()
    np.testing.assert_allclose(actual, expected, atol=2e-6)


def test_fusion_matches_reference():
    rng = np.random.default_rng(2)
    basis = rng.normal(size=(3, 3, 33, 33, 33)).astype(np.float32)
    weights = np.array([0.7, -0.2, 1.3], np.float32)
    np.testing.assert_allclose(fuse_basis(torch.from_numpy(weights)[None], torch.from_numpy(basis))[0].numpy(),
                               ia.fuse_luts(basis, weights), atol=1e-5)


def test_regularisers_are_zero_on_identity_and_positive_on_bad_luts():
    identity = torch.from_numpy(ia.identity_lut())
    tv, monotonic = tv_and_monotonicity(identity)
    assert float(monotonic) == 0.0 and float(tv) > 0
    assert float(endpoint_penalty(identity[None])) == 0.0
    assert float(endpoint_penalty((identity * 0.9)[None])) > 0  # white maps to 0.9: grey whites
    reversed_lut = identity.flip(-1)
    assert float(tv_and_monotonicity(reversed_lut)[1]) > 0
    penalty = WarmHuePenalty()
    assert float(penalty(identity[None])) == pytest.approx(0.0, abs=1e-6)
    swapped = identity[[1, 0, 2]][None]  # red<->green swap rotates warm hues a lot
    assert float(penalty(swapped)) > 1e-3


def test_torch_lab_matches_skimage():
    rgb = np.random.default_rng(3).random((500, 3)).astype(np.float32)
    np.testing.assert_allclose(rgb_to_lab_torch(torch.from_numpy(rgb)).numpy(), skcolor.rgb2lab(rgb[None])[0], atol=2e-3)


def test_degradation_sampler_identity_share_and_effect():
    rng = np.random.default_rng(4)
    samples = [synthetic.sample_degradation(rng) for _ in range(2000)]
    assert 0.22 < np.mean([s.identity for s in samples]) < 0.28
    scene = synthetic.procedural_scene(np.random.default_rng(5))
    assert scene.dtype == np.uint8 and scene.shape == (288, 384, 3)
    np.testing.assert_array_equal(synthetic.apply_degradation(scene, synthetic.Degradation(identity=True)), scene)
    strong = synthetic.Degradation(exposure_ev=-1.0, applied=["exposure"])
    assert synthetic.apply_degradation(scene, strong).mean() < scene.mean()


def test_dev22_photos_can_never_be_training_data():
    rows = load_manifest(os.path.join(AUTO_ROOT, "eval", "dev22_manifest.csv"))
    with pytest.raises(TrainingRightsError):
        assert_training_rights(rows)


def test_tiny_training_run_writes_a_loadable_smoke_model(tmp_path):
    import train
    card = train.main(["--run-id", "tiny", "--steps", "3", "--scenes", "4", "--val-scenes", "8", "--threads", "1",
                       "--runs-dir", str(tmp_path)])
    assert card["kind"] == "smoke" and card["is_ai_auto_candidate"] is False and card["contract"]["basis_luts"] == 3
    arm = trained_run_arm(str(tmp_path / "tiny"))
    assert "NOT an AI Auto candidate" in arm.label and arm.is_ai_auto is False
    image = synthetic.procedural_scene(np.random.default_rng(6))
    assert arm.render(image).image.shape == image.shape

    import export
    export_card = export.main(str(tmp_path / "tiny"))
    assert export_card["parity"]["passes"], export_card["parity"]
    assert export_card["is_ai_auto_candidate"] is False


def test_degradation_component_restriction():
    rng = np.random.default_rng(7)
    for _ in range(200):
        d = synthetic.sample_degradation(rng, ("exposure",))
        assert d.identity or d.applied == ["exposure"]
        assert d.wb_gains == (1.0, 1.0, 1.0) and d.gamma == 1.0
    with pytest.raises(ValueError):
        synthetic.sample_degradation(rng, ("blur",))
