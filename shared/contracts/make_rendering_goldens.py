"""Write the parity goldens for background.focus and grain (rendering-v2 revision 1).

    python shared/contracts/make_rendering_goldens.py          # rewrite shared/fixtures/rendering/
    python shared/contracts/make_rendering_goldens.py --check  # exit 1 if the committed files are out of date

Closes gap G5 (docs/v1/slice3-android.md, docs/v1/contract-fixes-1.md): depth-evaluation.md §R9 asks for
renderer goldens that take the disparity map as an input, so they do not depend on the depth model.
The expected values come from the executable references:
  - background.focus: experiments/depth/refocus.py (needs OpenCV and SciPy);
  - grain: shared/look-pack/reference_model.py.
Every array is a little-endian float32 file next to `index.json`, which records its shape and SHA-256.
The inputs are stored too, so a port never has to reproduce the synthetic scene generator.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "shared/fixtures/rendering"
sys.path[:0] = [str(REPO / "experiments/depth"), str(REPO / "shared/look-pack")]

import refocus  # noqa: E402
import reference_model  # noqa: E402

# Small enough to keep the fixtures light; at blur 100 the maximum radius is 0.06·144 = 8.6 px, enough for 8 layers.
SCENE_HEIGHT, SCENE_WIDTH = 144, 108


def synthetic_scene() -> dict[str, np.ndarray]:
    """A portrait-shaped test scene: a receding striped wall (disparity 0.05 -> 0.35 left to right), a red
    stripe, two point highlights for bokeh shapes, and an elliptical subject at disparity ~0.6 with a soft
    edge. Deterministic, no randomness."""
    yy, xx = np.mgrid[0:SCENE_HEIGHT, 0:SCENE_WIDTH].astype(np.float32)
    u, v = (xx + 0.5) / SCENE_WIDTH, (yy + 0.5) / SCENE_HEIGHT
    stripes = 0.5 + 0.25 * np.sign(np.sin(v * 2 * np.pi * 12))
    image = np.stack([stripes * 0.85, stripes * 0.88, stripes * 0.9], -1)
    red = (u > 0.18) & (u < 0.32)
    image[red] = [0.8, 0.08, 0.08]
    for cx, cy in ((0.15, 0.2), (0.82, 0.3)):
        image[(np.hypot(u - cx, v - cy) < 0.025)] = [1.0, 0.97, 0.9]
    distance = np.hypot((u - 0.5) / 0.22, (v - 0.62) / 0.3)
    matte = np.clip((1.15 - distance) / 0.3, 0, 1).astype(np.float32)
    subject_colour = np.stack([0.75 - 0.2 * v, 0.55 - 0.1 * v, 0.45 + 0 * v], -1)
    image = image * (1 - matte[..., None]) + subject_colour * matte[..., None]
    disparity = (0.05 + 0.3 * u).astype(np.float32)
    disparity = disparity * (1 - matte) + (0.6 + 0.1 * (v - 0.62)) * matte
    return {"image": image.astype(np.float32), "disparity": disparity.astype(np.float32), "matte": matte}


def replacement_image() -> np.ndarray:
    """A 60x80 vertical gradient with a horizon line, used as a replaced background (§R2.4)."""
    yy, xx = np.mgrid[0:60, 0:80].astype(np.float32)
    sky = np.stack([0.55 + 0 * yy, 0.7 + 0 * yy, 0.9 + 0 * yy], -1) * (1 - yy[..., None] / 120)
    ground = np.stack([0.3 + 0 * yy, 0.45 + 0 * yy, 0.25 + 0 * yy], -1)
    return np.where((yy < 34)[..., None], sky, ground).astype(np.float32)


FOCUS_CASES = [
    # name, params, uses matte, uses replacement
    ("lens-round-subject", dict(target_x=0.5, target_y=0.6, blur=100, focus_depth=40, style="lens", bokeh="round"), True, False),
    ("lens-hex-background", dict(target_x=0.85, target_y=0.15, blur=100, focus_depth=25, style="lens", bokeh="hex"), True, False),
    ("lens-heart-depth-only", dict(target_x=0.1, target_y=0.5, blur=100, focus_depth=10, style="lens", bokeh="heart"), False, False),
    ("lens-star-subject", dict(target_x=0.5, target_y=0.6, blur=90, focus_depth=0, style="lens", bokeh="star"), True, False),
    ("soft-subject", dict(target_x=0.5, target_y=0.6, blur=100, focus_depth=40, style="soft", style_amount=50), True, False),
    ("swirl-subject", dict(target_x=0.5, target_y=0.6, blur=100, focus_depth=40, style="swirl", style_amount=60), True, False),
    ("motion-subject", dict(target_x=0.5, target_y=0.6, blur=100, focus_depth=40, style="motion", style_amount=75), True, False),
    ("replaced-lens-subject", dict(target_x=0.5, target_y=0.6, blur=100, focus_depth=40, style="lens", bokeh="round"), True, True),
    ("lens-blur-55-default", dict(target_x=0.5, target_y=0.6, blur=55, focus_depth=40, style="lens", bokeh="round"), True, False),
]

GRAIN_CASES = [
    # name, height, width, params. Grain has hundreds of cells per long edge, so only the 480 px size-100 case
    # renders without supersampling (factor 1); the others exercise factors 3, 5 and 50.
    ("size100-no-supersampling", 480, 360, {"amount": 80, "size": 100, "roughness": 100, "seed": 123456789}),
    ("portrait13-glow-preview", 480, 320, {"amount": 55, "size": 25, "roughness": 59, "seed": 3343035603}),
    ("fine-size0", 360, 480, {"amount": 30, "size": 0, "roughness": 0, "seed": 7}),
    ("thumbnail", 24, 18, {"amount": 55, "size": 25, "roughness": 59, "seed": 3343035603}),
]
GRAIN_CROP = (slice(40, 104), slice(24, 88))   # stored 64x64 window of the larger cases (rows, columns)


def grain_input(height: int, width: int) -> np.ndarray:
    """R = 0.35 + 0.5·x/W, G = 0.25 + 0.4·x/W, B = 0.2 + 0.3·y/H (pixel indices), plus a saturated red block
    [0, H div 3) x [0, W div 3) of (0.75, 0.2, 0.15): chromaticity must survive the grain."""
    yy, xx = np.mgrid[0:height, 0:width].astype(np.float64)
    image = np.stack([0.35 + 0.5 * xx / width, 0.25 + 0.4 * xx / width, 0.2 + 0.3 * yy / height], -1)
    image[: height // 3, : width // 3] = [0.75, 0.2, 0.15]
    return image


class Files:
    def __init__(self):
        self.blobs: dict[str, bytes] = {}

    def array(self, name: str, values: np.ndarray) -> dict:
        data = np.ascontiguousarray(values, dtype="<f4")
        self.blobs[name] = data.tobytes()
        return {"file": name, "shape": list(data.shape), "sha256": hashlib.sha256(self.blobs[name]).hexdigest()}


def rounded(values, digits=7):
    return [round(float(v), digits) for v in np.ravel(values)]


def scalar_vectors() -> dict:
    disparity = np.linspace(0, 1, 21, dtype=np.float32)
    coc = [{"focal": f, "depthOfField": dof, "blur": 55, "longEdge": 1600,
            "halfWidth": refocus.focus_half_width(dof), "defocusRange": refocus.defocus_range(f),
            "radiusMaxPx": float(refocus.max_coc_radius_px(55, 1600)),
            "disparity": rounded(disparity),
            "signedCocPx": rounded(refocus.signed_coc(disparity, f, refocus.focus_half_width(dof), refocus.max_coc_radius_px(55, 1600)), 5)}
           for f, dof in ((0.458, 40), (0.05, 25), (0.9, 100), (0.5, 0))]
    linear = np.array([[[0.1, 0.2, 0.3], [0.7, 0.5, 0.2], [0.85, 0.9, 0.95], [1.0, 1.0, 1.0], [1.0, 0.2, 0.0]]], np.float32)
    expanded = refocus.expand_highlights(linear)
    return {"signedCoc": coc,
            "highlights": {"linear": [rounded(p) for p in linear[0]], "expanded": [rounded(p, 6) for p in expanded[0]],
                           "roundTrip": [rounded(p, 6) for p in refocus.compress_highlights(expanded)[0]]}}


def kernels(files: Files) -> list:
    out = []
    for shape in refocus.BOKEH_SHAPES:
        for radius in (2.5, 6.0):
            out.append({"kind": "bokeh", "shape": shape, "radius": radius, **files.array(f"kernel-{shape}-{radius}.f32", refocus.bokeh_kernel(shape, radius))})
    out.append({"kind": "gaussian", "radius": 4.0, **files.array("kernel-gaussian-4.0.f32", refocus.gaussian_kernel(4.0))})
    out.append({"kind": "motion", "radius": 4.0, "directionDegrees": 30.0, **files.array("kernel-motion-4.0-30.f32", refocus.motion_kernel(4.0, 30.0))})
    return out


def pull_push_cases(files: Files) -> list:
    yy, xx = np.mgrid[0:37, 0:29].astype(np.float32)
    colour = np.stack([xx / 28, yy / 36, 0.5 + 0 * xx], -1)
    cases = []
    # A large hole (only the outer 3 px are covered): the fill must come from the border colours, never black (G7).
    ring = np.zeros((37, 29), np.float32)
    ring[:3], ring[-3:], ring[:, :3], ring[:, -3:] = 1, 1, 1, 1
    # Partial coverage everywhere plus an empty quadrant.
    partial = np.clip(0.2 + 0.8 * np.sin(xx / 5) ** 2, 0, 1) * ((xx < 15) | (yy < 18))
    for name, coverage in (("large-hole", ring), ("partial", partial.astype(np.float32))):
        filled = refocus.pull_push_fill(colour * coverage[..., None], coverage)
        cases.append({"name": name, "colour": files.array(f"pullpush-{name}-colour.f32", colour),
                      "coverage": files.array(f"pullpush-{name}-coverage.f32", coverage),
                      "expected": files.array(f"pullpush-{name}-expected.f32", filled)})
    return cases


def focus_cases(files: Files, scene_inputs: dict) -> list:
    replacement = replacement_image()
    out = []
    for name, params, with_matte, with_replacement in FOCUS_CASES:
        scene = refocus.build_scene(scene_inputs["image"], scene_inputs["disparity"],
                                    scene_inputs["matte"] if with_matte else None,
                                    replacement_srgb=replacement if with_replacement else None)
        focus = refocus.FocusBlurParams(**params)
        rendered, diagnostics = refocus.render(scene, focus)
        out.append({"name": name, "params": params, "matte": with_matte, "replacement": with_replacement,
                    "focalDisparity": round(diagnostics["focal_disparity"], 6),
                    "subjectInFocus": bool(with_matte and refocus.focus_is_on_subject(scene, focus.target_x, focus.target_y)),
                    "radiusMaxPx": round(float(diagnostics["radius_max_px"]), 6), "halfWidth": round(diagnostics["half_width"], 6),
                    "expected": files.array(f"focus-{name}.f32", rendered)})
    return out


def grain_cases(files: Files) -> list:
    experimental = reference_model.load_develop_constants()["experimentalConstants"]
    out = []
    for name, height, width, params in GRAIN_CASES:
        image = grain_input(height, width)
        noise = reference_model.grain_noise(height, width, params, experimental)
        grained = reference_model.apply_grain(image, params, experimental)
        window = GRAIN_CROP if height > 104 and width > 88 else (slice(None), slice(None))
        crop = None if window[0].start is None else [window[0].start, window[1].start, 64, 64]
        out.append({"name": name, "height": height, "width": width, "params": params, "input": "grain_input (see generator)",
                    "supersampling": reference_model.grain_supersampling(
                        max(8, int(round(experimental["GRAIN_REF_LONG"] / (1 + 4 * params["size"] / 100)))), max(height, width)),
                    "crop": crop, "noise": files.array(f"grain-{name}-noise.f32", noise[window]),
                    "expected": files.array(f"grain-{name}-expected.f32", grained[window])})
    return out


def build() -> dict[str, bytes]:
    files = Files()
    scene_inputs = synthetic_scene()
    contract = json.loads((REPO / "shared/contracts/rendering-v2.json").read_text())
    index = {
        "format": "lightly-rendering-goldens", "formatVersion": 1,
        "renderingContract": {"version": contract["version"], "revision": contract["revision"]},
        "generatedBy": "shared/contracts/make_rendering_goldens.py",
        "arrays": "little-endian float32, row-major; images are HxWx3 sRGB-encoded in [0, 1] unless named otherwise",
        "tolerances": {
            "scalars": "signedCoc, halfWidth, radiusMax, focalDisparity, highlights: max abs 1e-4 (px for CoC)",
            "kernels": "max abs 1e-5 per tap",
            "pullPush": "max abs 1e-4",
            "focusRender": "ΔE00 mean ≤ 1.0 and p99 ≤ 4 against `expected` (depth-evaluation.md §R9)",
            "grain": "noise max abs 1e-4; expected max abs 2e-4 (inside `crop` [row, column, height, width] when set)",
        },
        "backgroundFocus": {
            "constants": next(s for s in contract["stages"] if s["id"] == "background.focus")["operators"][0]["constants"],
            "scene": {name: files.array(f"scene-{name}.f32", value) for name, value in scene_inputs.items()},
            "replacement": files.array("scene-replacement.f32", replacement_image()),
            "sceneNote": "disparity is already at the working size (no guided filter); matte in [0, 1]; the replacement is "
                         "placed by §R2.4 'plane' (cover fit, scale 1)",
            "scalars": scalar_vectors(),
            "kernels": kernels(files),
            "pullPush": pull_push_cases(files),
            "renders": focus_cases(files, scene_inputs),
        },
        "grain": grain_cases(files),
    }
    blobs = {"index.json": (json.dumps(index, indent=1, ensure_ascii=False) + "\n").encode()}
    blobs.update(files.blobs)
    return blobs


def main(argv) -> int:
    blobs = build()
    if "--check" in argv:
        stale = [n for n, data in blobs.items() if not (OUT / n).exists() or (OUT / n).read_bytes() != data]
        if stale:
            print("out of date:", ", ".join(stale))
            return 1
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    for name, data in blobs.items():
        (OUT / name).write_bytes(data)
    print(f"wrote {len(blobs)} files to {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
