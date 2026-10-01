"""Codex re-review issue 1: missing grain must not validate.

Probe that exposed it: Lightly's grain disabled, Lightroom reference with grain -> still 'validated' (ratio ~0.77),
because the grain statistic also measured image detail. Grain is now measured as its CONTRIBUTION over the
grain-free global-only render, in smooth regions only; photos without enough smooth area are 'insufficient
evidence', and a Look needs sufficient evidence (controlled smooth fixture) for its grain to count as validated.
"""
import numpy as np, torch
import lr_model as lm
import ingest_kit
from test_f7_two_validations import _kit

SETTINGS = {"ProcessVersion": "11.0", "GrainAmount": "35", "GrainSize": "25", "GrainFrequency": "50"}
# The simulated Lightroom reference keeps REAL grain even when a test disables Lightly's grain operator.
_REAL_GRAIN = lm.apply_grain


def _lightroom(seed):
    def full(src, glob_img, grain=True):
        if not grain:
            return glob_img
        with torch.no_grad():
            return _REAL_GRAIN(torch.from_numpy(glob_img.astype(np.float32)), SETTINGS, seed=seed).numpy()
    return full


def test_disabled_lightly_grain_is_not_validated(tmp_path, monkeypatch):
    monkeypatch.setattr(lm, "apply_grain", lambda img, s, seed=0: img)  # Lightly renders NO grain
    look = _kit(tmp_path, SETTINGS, _lightroom(seed=99), fixtures=True)
    assert look["full"]["status"] != "validated", look["full"]
    assert any(p.get("grain") == "fail" for p in look["full"]["photos"].values()), look["full"]["photos"]


def test_matching_grain_with_other_seed_validates_with_fixture_evidence(tmp_path):
    look = _kit(tmp_path, SETTINGS, _lightroom(seed=12345), fixtures=True)
    assert look["full"]["status"] == "validated", look["full"]
    assert look["full"]["photos"]["fixture_smooth"]["grain"] == "pass"


def test_without_smooth_evidence_grain_cannot_validate(tmp_path):
    look = _kit(tmp_path, SETTINGS, _lightroom(seed=12345), fixtures=False, textured_only=True)
    assert look["full"]["status"] != "validated"
    assert "insufficient grain evidence" in look["full"].get("reason", "")


def test_fixture_cards_are_generated(tmp_path):
    import make_kit
    make_kit.write_fixtures(tmp_path)
    assert (tmp_path / "fixture_smooth.jpg").exists() and (tmp_path / "fixture_textured.jpg").exists()
