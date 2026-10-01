"""Codex review: grain validation still accepted insufficient evidence.

(a) A Look with a positive grain setting but ZERO grain in both Lightroom's and Lightly's renders validated:
    'neither adds grain' must not count as measurable grain evidence.
(b) The grain-free reference was Lightroom's GLOBAL-ONLY export, which also removes tone, clarity and vignette,
    while Lightly's side kept them. Both sides must use the FULL recipe with only grain disabled:
    Lightroom `<look>__nograin__<photo>.jpg` (preset `[nograin]`) vs Lightly's full recipe without grain.
"""
import json
import numpy as np, torch
import lr_model as lm
import ingest_kit, make_kit
from test_f7_two_validations import _kit

GRAIN = {"ProcessVersion": "11.0", "GrainAmount": "35", "GrainSize": "25", "GrainFrequency": "50"}
_REAL_GRAIN = lm.apply_grain


def test_zero_grain_on_both_sides_is_not_evidence(tmp_path, monkeypatch):
    monkeypatch.setattr(lm, "apply_grain", lambda img, s, seed=0: img)  # Lightly: no grain
    look = _kit(tmp_path, GRAIN, lambda src, g: g, fixtures=True)      # Lightroom: no grain either
    assert look["full"]["status"] != "validated", look["full"]
    assert "insufficient grain evidence" in look["full"].get("reason", "")


def test_kit_generates_nograin_preset_only_for_grain_looks():
    full = make_kit.kit_preset_settings({**GRAIN, "Clarity2012": "+20"}, "nograin")
    assert full["GrainAmount"] in ("0", "+0") and full["Clarity2012"] == "+20"
    assert make_kit.needs_nograin(GRAIN) and not make_kit.needs_nograin({"ProcessVersion": "11.0"})


def test_missing_nograin_exports_block_grain_validation(tmp_path):
    def lightroom(src, g, grain=True):
        if not grain:
            return g
        with torch.no_grad():
            return _REAL_GRAIN(torch.from_numpy(g.astype(np.float32)), GRAIN, seed=5).numpy()
    look = _kit(tmp_path, GRAIN, lightroom, fixtures=True, nograin_exports=False)
    assert look["full"]["status"] == "incomplete"
    assert any("__nograin__" in m for m in look["full"]["missing"]), look["full"]["missing"]


def test_grain_reference_is_the_nograin_export_not_global(tmp_path, monkeypatch):
    loaded = []
    real_load = ingest_kit.load
    monkeypatch.setattr(ingest_kit, "load", lambda p: (loaded.append(str(p)), real_load(p))[1])
    def lightroom(src, g, grain=True):
        if not grain:
            return g
        with torch.no_grad():
            return _REAL_GRAIN(torch.from_numpy(g.astype(np.float32)), GRAIN, seed=5).numpy()
    look = _kit(tmp_path, GRAIN, lightroom, fixtures=True)
    assert look["full"]["status"] == "validated", look["full"]
    full_phase = [p for p in loaded if "__full__" in p or "__nograin__" in p]
    assert any("__nograin__" in p for p in full_phase)
