"""Expected outputs of the develop.spatial and finishing operators, from shared/look-pack/reference_model.py.

The shared golden set (shared/fixtures/look-pack) covers develop.global only; these vectors let the
Kotlin port of the spatial and finishing operators be checked against the same reference. Run with any
Python that has NumPy (the reference model needs nothing else):

    python android/core-develop/src/test/resources/spatial/generate.py

Writes, next to this file: input-<w>x<h>.u8 (RGB uint8) and <case>-<w>x<h>.u16 (RGB, round(value·65535)
as uint16 LE: 1.5e-5 resolution, far below the tolerances), plus cases.json.
"""
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[5]
sys.path.insert(0, str(REPO / "shared/look-pack"))
import reference_model as rm  # noqa: E402

model = rm.load_develop_constants()
SPATIAL, PROVISIONAL, EXPERIMENTAL = model["spatialConstants"], model["provisionalConstants"], model["experimentalConstants"]


def test_image(width, height):
    """Smooth gradients, edges and seeded noise: something for every operator to act on."""
    y, x = np.mgrid[0:height, 0:width].astype(np.float64)
    rng = np.random.default_rng(20261003)
    r = 0.5 + 0.35 * np.sin(x / 7.0) * np.cos(y / 11.0)
    g = 0.15 + 0.7 * (x / width)
    b = np.where((x // 16 + y // 16) % 2 == 0, 0.25, 0.7)
    rgb = np.stack([r, g, b], -1) + rng.normal(0, 0.03, (height, width, 3))
    return np.clip(np.round(np.clip(rgb, 0, 1) * 255), 0, 255).astype(np.uint8)


NR = {"luminance": 60, "luminanceDetail": 40, "luminanceContrast": 20, "color": 50, "colorDetail": 50, "colorSmoothness": 60}
SHARP = {"amount": 80, "radius": 1.2, "detail": 30, "edgeMasking": 40}
VIG = {"amount": -35, "midpoint": 40, "feather": 60, "roundness": 20, "highlightContrast": 30}
GRAIN = {"amount": 40, "size": 30, "roughness": 45, "seed": 1571121214}


def cases(rgb):
    out = {}
    out["noise-reduction"] = rm.apply_noise_reduction(rgb, NR, PROVISIONAL)
    out["clarity-texture"] = rm.apply_clarity_texture(rgb, 45.0, 30.0, SPATIAL)
    out["clarity-negative"] = rm.apply_clarity_texture(rgb, -60.0, 0.0, SPATIAL)
    out["sharpening"] = rm.apply_sharpening(rgb, SHARP, PROVISIONAL)
    for style in (1, 2, 3):
        out[f"vignette-style{style}"] = rm.apply_vignette(rgb, {**VIG, "style": style}, EXPERIMENTAL)
    out["vignette-lighten"] = rm.apply_vignette(rgb, {**VIG, "amount": 40, "roundness": -50, "style": 1}, EXPERIMENTAL)
    out["grain"] = rm.apply_grain(rgb, GRAIN, EXPERIMENTAL)
    combined = rm.apply_noise_reduction(rgb, NR, PROVISIONAL, 0.7)
    combined = rm.apply_clarity_texture(combined, 45.0, 30.0, SPATIAL, 0.7)
    combined = rm.apply_sharpening(combined, SHARP, PROVISIONAL, 0.7)
    combined = rm.apply_vignette(combined, {**VIG, "style": 1}, EXPERIMENTAL, 0.7)
    out["combined-strength-0.7"] = rm.apply_grain(combined, GRAIN, EXPERIMENTAL, 0.7)
    return out


def main():
    manifest = {"generator": "generate.py", "nr": NR, "sharpening": SHARP, "vignette": VIG, "grain": GRAIN, "images": []}
    for width, height in ((96, 64), (192, 128)):
        u8 = test_image(width, height)
        (HERE / f"input-{width}x{height}.u8").write_bytes(u8.tobytes())
        rgb = u8.astype(np.float64) / 255.0
        names = []
        for name, result in cases(rgb).items():
            assert np.isfinite(result).all(), name
            encoded = np.round(np.clip(result, 0, 1) * 65535).astype("<u2")
            (HERE / f"{name}-{width}x{height}.u16").write_bytes(encoded.tobytes())
            names.append(name)
        manifest["images"].append({"width": width, "height": height, "cases": names})
    (HERE / "cases.json").write_text(json.dumps(manifest, indent=1) + "\n")


if __name__ == "__main__":
    main()
