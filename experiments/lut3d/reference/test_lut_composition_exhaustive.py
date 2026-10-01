"""Exhaustive baked-vs-two-stage check (supersedes the sampled claim in M1 corrections).

Android foundation work found that random sampling on 8 Auto LUTs (max 1.64/255) understated the error: over a
dense colour grid and all 23 golden Auto LUTs, a single baked 33^3 LUT deviates by up to ~6/255 for Auto LUTs
with strong out-of-range output (portrait_deep_03 reaches 1.475). Contract consequence: Auto and Look are applied
as TWO LUT passes; baking is not allowed by default. This test records the measured worst cases.
Run: python -m pytest test_lut_composition_exhaustive.py -q -s
"""
import glob, json, os
import numpy as np
import ia3dlut as ia
from test_lut_composition import apply, bake, look_lut

HERE = os.path.dirname(os.path.abspath(__file__))


def all_auto_luts():
    model = ia.load_reference_model(os.path.join(HERE, "upstream/pretrained_models/sRGB"))
    for meta in sorted(glob.glob(os.path.join(HERE, "../golden/*/meta.json"))):
        w = np.array(json.load(open(meta))["weights_deploy"], np.float32)
        yield os.path.basename(os.path.dirname(meta)), ia.fuse_luts(model.basis_luts, w)


def dense_grid(n=64):
    v = np.linspace(0, 1, n, dtype=np.float32)
    b, g, r = np.meshgrid(v, v, v, indexing="ij")
    return np.stack([r, g, b], -1).reshape(-1, 1, 3)


def test_baking_is_not_within_2_over_255_for_every_auto_lut():
    x = dense_grid(); L2 = look_lut(); worst = {}
    for stem, L1 in all_auto_luts():
        two = np.clip(apply(L2, apply(L1, x)), 0, 1)
        baked = np.clip(apply(bake(L1, L2), x), 0, 1)
        worst[stem] = float(np.abs(ia.to_uint8(two).astype(int) - ia.to_uint8(baked).astype(int)).max())
    over = {k: v for k, v in worst.items() if v > 2}
    print("worst 8-bit baked-vs-two-stage per Auto LUT:", dict(sorted(worst.items(), key=lambda kv: -kv[1])[:5]))
    # The contract therefore requires two passes. If this ever becomes empty, baking could be reconsidered.
    assert over, "baking now within tolerance for all LUTs; revisit spec §4.1"
