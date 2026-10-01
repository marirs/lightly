"""Contract rule test (Codex M1 finding 3): two-stage LUT boundary behaviour.

Rule (rendering contract v1): every LUT stage clamps its INPUT to [0,1] (clamp-to-edge, as GPU texture
addressing does) and may produce any output; the final output is clamped once at encode. A baked LUT is
B(g) = Look(clamp(Auto(g))) sampled on the 33^3 grid and applied as B(clamp(x)).
This test samples baked vs unbaked equivalence on 8 Auto LUTs. NOTE: sampling understated the worst case;
see test_lut_composition_exhaustive.py (up to 6/255), which is why the contract requires two LUT passes. Run: python -m pytest test_lut_composition.py -q -s
"""
import glob, json, os
import numpy as np
import ia3dlut as ia

HERE = os.path.dirname(os.path.abspath(__file__))
rng = np.random.default_rng(0)


def apply(lut, x):
    return ia.apply_lut_reference(lut, np.clip(x, 0, 1).astype(np.float32), binsize_numerator=1.0)


def bake(first, second):
    g = np.moveaxis(ia.identity_lut(), 0, -1)  # [b,g,r,3] grid of input colours
    out = apply(second, apply(first, g.reshape(-1, 1, 3))).reshape(g.shape)
    return np.moveaxis(out, -1, 0).astype(np.float32)


def look_lut():
    """A strong creative LUT (S-curve + warm/teal split) so composition error is not trivially small."""
    g = np.moveaxis(ia.identity_lut(), 0, -1)
    y = g ** 1.1
    y = y + 0.12 * np.sin(np.pi * (y - 0.5)) * 0.5
    y[..., 0] += 0.06 * (y.mean(-1) - 0.4); y[..., 2] -= 0.06 * (y.mean(-1) - 0.4)
    return np.moveaxis(y, -1, 0).astype(np.float32)


def auto_luts():
    model = ia.load_reference_model(os.path.join(HERE, "upstream/pretrained_models/sRGB"))
    for meta in sorted(glob.glob(os.path.join(HERE, "../golden/*/meta.json")))[:8]:
        w = np.array(json.load(open(meta))["weights_deploy"], np.float32)
        yield os.path.basename(os.path.dirname(meta)), ia.fuse_luts(model.basis_luts, w)


def test_auto_luts_exercise_out_of_range():
    lo = min(l.min() for _, l in auto_luts()); hi = max(l.max() for _, l in auto_luts())
    assert lo < 0 and hi > 1, (lo, hi)


def test_baked_matches_two_stage_within_tolerance():
    x = np.concatenate([rng.uniform(0, 1, (20000, 1, 3)), rng.uniform(-0.2, 1.3, (5000, 1, 3))]).astype(np.float32)
    L2 = look_lut()
    worst = 0.0
    for stem, L1 in auto_luts():
        two = np.clip(apply(L2, apply(L1, x)), 0, 1)
        baked = np.clip(apply(bake(L1, L2), x), 0, 1)
        err = np.abs(two - baked).max() * 255
        p99 = np.percentile(np.abs(two - baked) * 255, 99)
        worst = max(worst, err)
        print(f"{stem:20s} max {err:.2f}/255  p99 {p99:.2f}/255")
    # Sampled check only (8 LUTs, random colours). Not a contract tolerance: see the exhaustive test.
    assert worst <= 2.0, worst


def test_clamp_rule_is_what_makes_inputs_defined():
    L1 = next(auto_luts())[1]
    x = np.array([[[1.0, 1.0, 1.0]]], np.float32)
    y = apply(L1, x)
    # stage 2 must see the clamped value, identical to sampling exactly at the cube edge
    assert np.allclose(apply(look_lut(), y), apply(look_lut(), np.clip(y, 0, 1)))
