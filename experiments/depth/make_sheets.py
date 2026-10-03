"""Demonstration sheets for depth-based Focus & Blur -> ~/.codex/artifacts/lightly/v1/depth/.

  01..07  per photo: depth, matte, CoC maps; focus NEAR and FAR x every style (Lens round/hex/heart/
          star, Soft, Swirl, Motion). The white ring marks the tap point.
  08      background replacement, then the same Focus & Blur (flat plane and own-depth placement).
  09      why depth (not just a subject mask), and why layered compositing (halo ablation).
  10      depth-of-field controls: Focus depth and Blur sweeps.
  11      highlight-aware bokeh shapes on point lights (night), with and without highlight expansion.

Depth: Depth Anything V2 Small (Apache-2.0) at 518x392 / 392x518. Subject: Apple Vision matte.
"""

import json
import multiprocessing
import os
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw

import common
import refocus
import sheet_utils
from refocus import FocusBlurParams

DEPTH_CANDIDATE = "da2_small"
TILE_WIDTH = 420
# Tap points (normalised x, y): near, far. Chosen by looking at the photo, then verified by the
# printed focal disparity (near must be high, far low).
TAPS = {
    "portrait_deep_02": [(0.50, 0.35), (0.88, 0.20)],
    "portrait_medium_02": [(0.50, 0.45), (0.12, 0.15)],
    "portrait_light_01": [(0.50, 0.42), (0.06, 0.25)],
    "backlit_02": [(0.33, 0.60), (0.12, 0.30)],
    "night_01": [(0.50, 0.93), (0.50, 0.40)],
    "wellexposed_03": [(0.50, 0.93), (0.50, 0.55)],
    "landscape_01": [(0.50, 0.92), (0.50, 0.15)],
}
STYLE_VARIANTS = [
    ("Lens · round", dict(style="lens", bokeh="round")),
    ("Lens · hex", dict(style="lens", bokeh="hex")),
    ("Lens · heart", dict(style="lens", bokeh="heart")),
    ("Lens · star", dict(style="lens", bokeh="star")),
    ("Soft · glow 50", dict(style="soft", style_amount=50)),
    ("Swirl · 50", dict(style="swirl", style_amount=50)),
    ("Motion · 0°", dict(style="motion", style_amount=50)),
]
BLUR = 70.0
FOCUS_DEPTH = 25.0


def load_scene_inputs(stem: str):
    image = common.load_working_image(stem)
    matte = common.load_subject_matte(stem, image.shape)
    raw = np.load(common.CACHE_DIR / "depth" / DEPTH_CANDIDATE / f"{stem}.npy")
    return image, matte, refocus.upsample_disparity(raw, image)


def mark_tap(image: np.ndarray, tap) -> Image.Image:
    pil = sheet_utils.to_pil(image)
    draw = ImageDraw.Draw(pil)
    x, y = tap[0] * pil.width, tap[1] * pil.height
    radius = max(10, pil.width // 60)
    for width, colour in ((6, (0, 0, 0)), (3, (255, 255, 255))):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), outline=colour, width=width)
    return pil


def coc_visual(coc: np.ndarray, radius_max: float) -> np.ndarray:
    """Behind the focal band = blue, in front = orange, sharp = black."""
    magnitude = np.abs(coc) / max(radius_max, 1e-6)
    out = np.zeros(coc.shape + (3,), np.float32)
    out[..., 2] = np.where(coc < 0, magnitude, 0)
    out[..., 0] = np.where(coc > 0, magnitude, 0)
    out[..., 1] = np.where(coc > 0, magnitude * 0.55, magnitude * 0.35)
    return out


def photo_sheet(stem: str) -> dict:
    image, matte, disparity = load_scene_inputs(stem)
    scene = refocus.build_scene(image, disparity, matte)
    header = [sheet_utils.tile(image, f"{stem} (original)", TILE_WIDTH),
              sheet_utils.tile(sheet_utils.colourise_disparity(disparity), "depth: DA-V2 Small", TILE_WIDTH),
              sheet_utils.tile(matte if matte is not None else np.zeros(image.shape[:2]),
                               "Vision subject matte" if matte is not None else "no subject: depth only", TILE_WIDTH)]
    rows, focal_values = [], []
    for label, tap in zip(("NEAR", "FAR"), TAPS[stem]):
        row = []
        for variant_label, overrides in STYLE_VARIANTS:
            params = FocusBlurParams(target_x=tap[0], target_y=tap[1], blur=BLUR, focus_depth=FOCUS_DEPTH, **overrides)
            rendered, diagnostics = refocus.render(scene, params)
            row.append(sheet_utils.tile(mark_tap(rendered, tap), f"focus {label} · {variant_label}", TILE_WIDTH))
        focal_values.append(round(diagnostics["focal_disparity"], 3))
        header.append(sheet_utils.tile(coc_visual(diagnostics["coc_background"], diagnostics["radius_max_px"]),
                                       f"CoC, focus {label} (d={focal_values[-1]:.2f})", TILE_WIDTH))
        rows.append(row)
    title = (f"{stem} — depth-based refocus, Blur {BLUR:.0f}, Focus depth {FOCUS_DEPTH:.0f}. "
             f"Row 2 focus NEAR, row 3 focus FAR (ring = tap). CoC: blue behind / orange in front of focus")
    index = 1 + list(TAPS).index(stem)
    sheet_utils.grid([header] + rows, title).save(common.SHEETS_DIR / f"{index:02d}_{stem}.jpg", quality=86)
    return {"stem": stem, "focal_disparity_near_far": focal_values}


def replacement_sheet() -> None:
    rows = []
    # far_background_tap: a point on the replacement (matte = 0 there) far away in its own depth.
    for subject_stem, background_stem, far_background_tap in (("portrait_deep_02", "landscape_02", (0.80, 0.12)),
                                                              ("portrait_medium_02", "wellexposed_02", (0.50, 0.20))):
        image, matte, disparity = load_scene_inputs(subject_stem)
        background = common.load_working_image(background_stem)
        background_disparity = np.load(common.CACHE_DIR / "depth" / DEPTH_CANDIDATE / f"{background_stem}.npy")
        background_disparity = refocus.upsample_disparity(background_disparity, background)
        flat = refocus.build_scene(image, disparity, matte, replacement_srgb=background)
        own = refocus.build_scene(image, disparity, matte, replacement_srgb=background,
                                  replacement_disparity=background_disparity)
        subject_tap, background_tap = TAPS[subject_stem][0], TAPS[subject_stem][1]
        variants = [
            ("replaced, Blur 0", flat, FocusBlurParams(*subject_tap, blur=0)),
            ("plane · focus subject · Lens", flat, FocusBlurParams(*subject_tap, blur=BLUR, focus_depth=FOCUS_DEPTH)),
            ("plane · focus subject · Swirl", flat, FocusBlurParams(*subject_tap, blur=BLUR, focus_depth=FOCUS_DEPTH, style="swirl")),
            ("plane · focus background · Lens", flat, FocusBlurParams(*background_tap, blur=BLUR, focus_depth=FOCUS_DEPTH)),
            ("own depth · focus subject · Lens", own, FocusBlurParams(*subject_tap, blur=BLUR, focus_depth=FOCUS_DEPTH)),
            ("own depth · focus far bg · hex", own, FocusBlurParams(*far_background_tap, blur=BLUR, focus_depth=FOCUS_DEPTH, bokeh="hex")),
        ]
        row = []
        for label, scene, params in variants:
            rendered, _ = refocus.render(scene, params)
            row.append(sheet_utils.tile(mark_tap(rendered, (params.target_x, params.target_y)), label, TILE_WIDTH))
        row.append(sheet_utils.tile(sheet_utils.colourise_disparity(own.background.disparity * (1 - matte)
                                                                    + own.subject.disparity * matte),
                                    "composited depth (own-depth bg)", TILE_WIDTH))
        rows.append(row)
    sheet_utils.grid(rows, "Background replacement, then the same depth-based Focus & Blur. 'plane' = replacement is a flat plane "
                           "at the original background's depth; 'own depth' = replacement's DA-V2 depth remapped behind the subject").save(
        common.SHEETS_DIR / "08_replacement_then_blur.jpg", quality=86)


def naive_single_pass(image: np.ndarray, disparity: np.ndarray, params: FocusBlurParams) -> np.ndarray:
    """Common shortcut: blend each pixel between sharp and a uniformly blurred copy by its CoC."""
    radius_max = refocus.max_coc_radius_px(params.blur, max(image.shape[:2]))
    focal = float(np.median(disparity[int(params.target_y * (image.shape[0] - 1)) - 5:int(params.target_y * (image.shape[0] - 1)) + 5,
                                      int(params.target_x * (image.shape[1] - 1)) - 5:int(params.target_x * (image.shape[1] - 1)) + 5]))
    coc = np.abs(refocus.signed_coc(disparity, focal, refocus.focus_half_width(params.focus_depth), radius_max)) / radius_max
    linear = refocus.srgb_to_linear(image)
    blurred = refocus.convolve(linear, refocus.bokeh_kernel("round", radius_max))
    return refocus.linear_to_srgb(linear * (1 - coc[..., None]) + blurred * coc[..., None])


def mask_only(image: np.ndarray, matte: np.ndarray, params: FocusBlurParams) -> np.ndarray:
    """What a subject mask alone can do: one uniform blur everywhere outside the subject."""
    radius_max = refocus.max_coc_radius_px(params.blur, max(image.shape[:2]))
    linear = refocus.srgb_to_linear(image)
    blurred = refocus.convolve(linear, refocus.bokeh_kernel("round", radius_max))
    return refocus.linear_to_srgb(linear * matte[..., None] + blurred * (1 - matte[..., None]))


def halo_leak(rendered: np.ndarray, clean_background: np.ndarray, matte: np.ndarray) -> float:
    """Mean |difference| (sRGB, x255) in a band just outside the subject between the render and the
    background blurred on its own. Anything the subject smeared into its surroundings shows up here."""
    long_side = max(matte.shape)
    inside = (matte > 0.5).astype(np.float32)
    band = (refocus.dilate(inside, round(0.03 * long_side)) > 0.5) & (refocus.dilate(inside, round(0.004 * long_side)) < 0.5)
    return float(np.abs(rendered - clean_background)[band].mean() * 255)


def ablation_sheet() -> None:
    rows, leaks = [], {}
    # (a) depth vs subject mask alone: the ground the person stands on is at her depth and must stay
    # sharp; a mask cannot know that, depth can.
    stem = "backlit_02"
    image, matte, disparity = load_scene_inputs(stem)
    params = FocusBlurParams(*TAPS[stem][0], blur=BLUR, focus_depth=FOCUS_DEPTH)
    ours, _ = refocus.render(refocus.build_scene(image, disparity, matte), params)
    rows.append([sheet_utils.tile(mask_only(image, matte, params), f"{stem}: subject mask only (uniform blur)", TILE_WIDTH),
                 sheet_utils.tile(ours, "depth: blur follows distance (ground at her depth sharp)", TILE_WIDTH),
                 sheet_utils.tile(sheet_utils.colourise_disparity(disparity), "depth used", TILE_WIDTH)])
    # (b) halo ablation: crops at the subject outline, plus a leak measurement in a band around it
    for stem, crop in (("portrait_deep_02", (0.12, 0.0, 0.42, 0.45)), ("portrait_medium_02", (0.05, 0.22, 0.55, 0.55))):
        image, matte, disparity = load_scene_inputs(stem)
        params = FocusBlurParams(*TAPS[stem][0], blur=90, focus_depth=FOCUS_DEPTH)
        scene = refocus.build_scene(image, disparity, matte)
        ours, diagnostics = refocus.render(scene, params)
        no_planes, _ = refocus.render(refocus.build_scene(image, disparity, None), params)
        naive = naive_single_pass(image, disparity, params)
        # Reference for the band: the (subject-free) background plane rendered alone, same focus.
        # Reference for the band: the subject-free background plane rendered alone at the SAME focal
        # disparity (the tap is on the subject, which this scene does not contain).
        clean, _ = refocus.render(refocus.Scene(scene.background, None), params,
                                  focal_override=diagnostics["focal_disparity"])
        leak = {name: round(halo_leak(img, clean, matte), 2) for name, img in
                (("naive_per_pixel", naive), ("layered_depth_only", no_planes), ("spec", ours))}
        leaks[stem] = leak

        def cut(img):
            h, w = img.shape[:2]
            return img[int(crop[1] * h):int(crop[3] * h), int(crop[0] * w):int(crop[2] * w)]
        rows.append([sheet_utils.tile(cut(naive), f"{stem}: naive per-pixel blend · leak {leak['naive_per_pixel']}", TILE_WIDTH),
                     sheet_utils.tile(cut(no_planes), f"layered, no subject plane · leak {leak['layered_depth_only']}", TILE_WIDTH),
                     sheet_utils.tile(cut(ours), f"layered + subject plane (spec) · leak {leak['spec']}", TILE_WIDTH)])
    sheet_utils.grid(rows, "Row 1: depth vs subject mask alone. Rows 2-3: halo ablation, Blur 90 "
                           "(leak = mean |Δ|x255 just outside the subject vs background blurred alone)").save(
        common.SHEETS_DIR / "09_depth_vs_mask_and_halo_ablation.jpg", quality=88)
    (common.RESULTS_DIR / "halo_leak.json").write_text(json.dumps(leaks, indent=2))
    print("halo leak", leaks, flush=True)


def dof_sweep_sheet() -> None:
    stem = "wellexposed_03"
    image, matte, disparity = load_scene_inputs(stem)
    scene = refocus.build_scene(image, disparity, matte)
    tap = (0.5, 0.75)
    rows = []
    for label, values, key in (("Focus depth", (0, 25, 50, 100), "focus_depth"), ("Blur", (20, 45, 70, 100), "blur")):
        row = []
        for value in values:
            kwargs = {"blur": BLUR, "focus_depth": FOCUS_DEPTH, key: value}
            rendered, diagnostics = refocus.render(scene, FocusBlurParams(*tap, **kwargs))
            row.append(sheet_utils.tile(mark_tap(rendered, tap), f"{label} {value} (band ±{diagnostics['half_width']:.2f}, "
                                                                 f"Rmax {diagnostics['radius_max_px']:.0f}px)", TILE_WIDTH))
        rows.append(row)
    sheet_utils.grid(rows, "Depth-of-field controls on a continuous-depth scene (focus at mid-alley). "
                           "Row 1: Focus depth at Blur 70. Row 2: Blur at Focus depth 25").save(
        common.SHEETS_DIR / "10_dof_controls.jpg", quality=86)


def highlight_sheet() -> None:
    stem = "night_01"
    image, matte, disparity = load_scene_inputs(stem)
    scene = refocus.build_scene(image, disparity, matte)
    tap = (0.5, 0.93)
    crop = (0.0, 0.2, 1.0, 0.65)
    rows = []
    for highlights in (True, False):
        row = []
        for shape in refocus.BOKEH_SHAPES:
            saved_gain = refocus.HIGHLIGHT_GAIN
            refocus.HIGHLIGHT_GAIN = saved_gain if highlights else 0.0
            rendered, _ = refocus.render(scene, FocusBlurParams(*tap, blur=100, focus_depth=10, bokeh=shape))
            refocus.HIGHLIGHT_GAIN = saved_gain
            h, w = rendered.shape[:2]
            row.append(sheet_utils.tile(rendered[int(crop[1] * h):int(crop[3] * h), int(crop[0] * w):int(crop[2] * w)],
                                        f"{shape} · highlight expansion {'on' if highlights else 'off'}", TILE_WIDTH))
        rows.append(row)
    sheet_utils.grid(rows, "Lens bokeh shapes on point lights (night_01, focus on the near road, Blur 100). "
                           "Row 1: spec (highlight-aware). Row 2: same without highlight expansion").save(
        common.SHEETS_DIR / "11_bokeh_highlights.jpg", quality=88)


def main() -> None:
    common.SHEETS_DIR.mkdir(parents=True, exist_ok=True)
    jobs = sys.argv[1:] or (list(TAPS) + ["replacement", "ablation", "dof", "highlights"])
    special = {"replacement": replacement_sheet, "ablation": ablation_sheet, "dof": dof_sweep_sheet,
               "highlights": highlight_sheet}
    with multiprocessing.Pool(int(os.environ.get("SHEET_PROCESSES", "3"))) as pool:
        results = pool.map(run_job, [(job, job in special) for job in jobs])
    focal = [r for r in results if r]
    if focal:
        (common.RESULTS_DIR / "sheet_focal_disparities.json").write_text(json.dumps(focal, indent=2))
        print(json.dumps(focal))


def run_job(job):
    name, is_special = job
    cv2.setNumThreads(2)
    if is_special:
        {"replacement": replacement_sheet, "ablation": ablation_sheet, "dof": dof_sweep_sheet,
         "highlights": highlight_sheet}[name]()
        print("done", name, flush=True)
        return None
    result = photo_sheet(name)
    print("done", name, result, flush=True)
    return result


if __name__ == "__main__":
    main()
