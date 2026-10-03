"""background.focus and grain: the revision-1 fixes and the committed parity goldens (shared/fixtures/rendering).

Run: python -m pytest shared/contracts/tests -q   (needs OpenCV and SciPy for experiments/depth/refocus.py)
"""
import json
import sys
from pathlib import Path

import numpy as np
import pytest

CONTRACTS = Path(__file__).resolve().parents[1]
REPO = CONTRACTS.parents[1]
GOLDENS = REPO / "shared/fixtures/rendering"
sys.path[:0] = [str(CONTRACTS), str(REPO / "experiments/depth")]

pytest.importorskip("cv2")
pytest.importorskip("scipy")
import make_rendering_goldens  # noqa: E402
import refocus  # noqa: E402


# --- G7: pull-push fills a large hole from its neighbours ----------------------------------------------

def test_large_hole_fills_from_its_neighbours_not_black():
    """Only the top and bottom 10 rows are covered (83 % hole). The first reference stopped the pyramid at a
    4 px short side, left that level's empty cells at 0 and filled the hole with near-black (0.0017)."""
    height, width = 120, 90
    colour = np.broadcast_to(np.array([0.8, 0.4, 0.2], np.float32), (height, width, 3))
    coverage = np.zeros((height, width), np.float32)
    coverage[:10], coverage[-10:] = 1, 1
    filled = refocus.pull_push_fill(colour * coverage[..., None], coverage)
    assert np.allclose(filled, [0.8, 0.4, 0.2], atol=1e-5)


def test_hole_takes_the_colour_of_the_nearer_neighbour():
    height, width = 64, 64
    colour = np.zeros((height, width, 3), np.float32)
    colour[:, :4] = [1, 0, 0]
    colour[:, -4:] = [0, 0, 1]
    coverage = np.zeros((height, width), np.float32)
    coverage[:, :4], coverage[:, -4:] = 1, 1
    filled = refocus.pull_push_fill(colour * coverage[..., None], coverage)
    assert filled[32, 10, 0] > filled[32, 10, 2] and filled[32, 53, 2] > filled[32, 53, 0]
    assert filled[:, 4:-4].sum(-1).min() > 0.9   # never darker than the neighbours mixed


def test_pull_push_keeps_covered_pixels_and_handles_odd_sizes():
    rng = np.random.default_rng(3)
    colour = rng.random((37, 29, 3)).astype(np.float32)
    coverage = np.ones((37, 29), np.float32)
    assert np.allclose(refocus.pull_push_fill(colour, coverage), colour, atol=1e-6)


# --- B1: circle of confusion ---------------------------------------------------------------------------

def test_farthest_depth_from_the_focal_plane_gets_the_full_radius():
    radius_max = refocus.max_coc_radius_px(100, 1000)
    assert radius_max == pytest.approx(60.0)
    for focal in (0.2, 0.458, 0.9):
        h = refocus.focus_half_width(40)
        far_end = 0.0 if focal >= 0.5 else 1.0
        assert abs(refocus.signed_coc(np.array([far_end], np.float32), focal, h, radius_max)[0]) == pytest.approx(radius_max)


def test_blur_still_follows_real_depth():
    """One scale for both sides: blur grows linearly with disparity distance beyond the band (no flat mask blur)."""
    focal, h, radius_max = 0.6, refocus.focus_half_width(40), 50.0
    disparity = np.array([0.6, 0.45, 0.3, 0.15, 0.0, 0.9], np.float32)
    coc = refocus.signed_coc(disparity, focal, h, radius_max)
    span = 0.6 - 0.2
    assert coc[0] == 0 and coc[1] == 0                              # inside the sharp band
    assert coc[2] == pytest.approx(-(0.3 - 0.2) / span * radius_max)
    assert coc[3] == pytest.approx(-(0.45 - 0.2) / span * radius_max)
    assert coc[4] == pytest.approx(-radius_max)
    assert coc[5] == pytest.approx((0.3 - 0.2) / span * radius_max)   # same distance in front, same radius


def test_focus_on_the_subject_keeps_the_whole_subject_sharp():
    inputs = make_rendering_goldens.synthetic_scene()
    scene = refocus.build_scene(inputs["image"], inputs["disparity"], inputs["matte"])
    params = refocus.FocusBlurParams(target_x=0.5, target_y=0.6, blur=100, focus_depth=0)
    rendered, _ = refocus.render(scene, params)
    solid = inputs["matte"] > 0.999
    assert np.abs(rendered[solid] - inputs["image"][solid]).max() < 2e-3


# --- G5: the committed goldens are what the references produce ----------------------------------------

def _strip_digests(value):
    if isinstance(value, dict):
        return {k: _strip_digests(v) for k, v in value.items() if k != "sha256"}
    if isinstance(value, list):
        return [_strip_digests(v) for v in value]
    return value


def test_goldens_are_current():
    """Arrays are compared with a tolerance (FFT results may differ in the last bits across machines);
    run make_rendering_goldens.py after any change to refocus.py or reference_model.apply_grain."""
    blobs = make_rendering_goldens.build()
    committed_index = json.loads((GOLDENS / "index.json").read_text())
    assert _strip_digests(json.loads(blobs["index.json"])) == _strip_digests(committed_index)
    for name, data in blobs.items():
        if name == "index.json":
            continue
        committed = np.frombuffer((GOLDENS / name).read_bytes(), "<f4")
        assert np.allclose(np.frombuffer(data, "<f4"), committed, atol=1e-5), name
