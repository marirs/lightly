"""Write shared/contracts/rendering-v2.json, the machine-readable half of rendering contract v2.

    python shared/contracts/build_rendering_v2.py          # rewrite the JSON
    python shared/contracts/build_rendering_v2.py --check  # exit 1 if the committed JSON is out of date

The stage/operator definitions live here as data; the calibrated constants are copied verbatim from
experiments/presets/calibration_natural.json and calibration_spatial_natural.json, and the experimental
constants from experiments/presets/lr_model.py, so the contract can never drift from the model the pack
is built and verified with. rendering-v2.md is the prose half (equations, rationale).
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent / "rendering-v2.json"
PRESETS = REPO / "experiments/presets"
# Revision within contract version 2; rendering-v2.md "Change log" lists what each one changed.
# 1 = contract fixes 1 (docs/v1/contract-fixes-1.md): background.focus constants, pull-push, grain colour/aliasing.
CONTRACT_REVISION = 1


def num(lo, hi, default, unit, note=None, integer=False):
    spec = {"type": "integer" if integer else "number", "min": lo, "max": hi, "default": default, "unit": unit}
    if note:
        spec["note"] = note
    return spec


def enum(values, default, note=None):
    spec = {"type": "enum", "values": list(values), "default": default}
    if note:
        spec["note"] = note
    return spec


SLIDER = "lightroom-slider"           # Lightroom's own units, usually -100…100
PERCENT = "percent"                   # 0…100
LONG_EDGE = "fraction-of-long-edge"   # resolution independent radius
FRAME = "fraction-of-frame"           # normalised position in the stage's frame, origin top-left

BANDS = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
CURVE = {"type": "curve", "note": "[[x, y], ...] in 0…255, x strictly increasing; 2 points linear, ≥3 natural cubic spline; "
                                  "end values held outside [x0, xN]; sampled to a 256-entry table, then linear lookup"}
BAND_ARRAY = {"type": "array", "items": num(-100, 100, 0, SLIDER), "length": 8, "order": BANDS}


def develop_global_operators():
    return [
        {"id": "calibration", "params": {k: num(-100, 100, 0, SLIDER) for k in
                                         ("redHue", "redSaturation", "greenHue", "greenSaturation", "blueHue", "blueSaturation")},
         "status": "calibrated", "equation": "rendering-v2.md#g1-calibration"},
        {"id": "whiteBalance", "params": {"temperature": num(-100, 100, 0, SLIDER, "IncrementalTemperature"),
                                          "tint": num(-100, 100, 0, SLIDER, "IncrementalTint")},
         "status": "calibrated", "equation": "rendering-v2.md#g2-white-balance"},
        {"id": "exposure", "params": {"ev": num(-5, 5, 0, "stops")}, "status": "calibrated", "equation": "rendering-v2.md#g3-exposure"},
        {"id": "shadowTint", "params": {"amount": num(-100, 100, 0, SLIDER)}, "status": "calibrated", "equation": "rendering-v2.md#g4-shadow-tint"},
        {"id": "toneSliders", "params": {k: num(-100, 100, 0, SLIDER) for k in ("contrast", "highlights", "shadows", "whites", "blacks")},
         "status": "calibrated-global-approximation", "equation": "rendering-v2.md#g5-basic-tone"},
        {"id": "dehaze", "params": {"amount": num(-100, 100, 0, SLIDER)}, "status": "calibrated-global-approximation",
         "equation": "rendering-v2.md#g5-basic-tone"},
        {"id": "parametricCurve", "params": {"shadows": num(-100, 100, 0, SLIDER), "darks": num(-100, 100, 0, SLIDER),
                                             "lights": num(-100, 100, 0, SLIDER), "highlights": num(-100, 100, 0, SLIDER),
                                             "shadowSplit": num(0, 100, 25, PERCENT), "midtoneSplit": num(0, 100, 50, PERCENT),
                                             "highlightSplit": num(0, 100, 75, PERCENT)},
         "status": "calibrated", "equation": "rendering-v2.md#g6-parametric-curve"},
        {"id": "toneCurve", "params": {"master": CURVE, "red": CURVE, "green": CURVE, "blue": CURVE},
         "note": "a channel that is absent is the identity", "status": "exact", "equation": "rendering-v2.md#g7-point-curves"},
        {"id": "hsl", "params": {"hue": BAND_ARRAY, "saturation": BAND_ARRAY, "luminance": BAND_ARRAY},
         "status": "calibrated", "equation": "rendering-v2.md#g8-hsl"},
        {"id": "vibranceSaturation", "params": {"vibrance": num(-100, 100, 0, SLIDER), "saturation": num(-100, 100, 0, SLIDER)},
         "status": "calibrated", "equation": "rendering-v2.md#g9-vibrance-saturation"},
        {"id": "colorGrading", "params": {
            **{zone: {"type": "object", "params": {"hue": num(0, 360, 0, "degrees"), "saturation": num(0, 100, 0, PERCENT),
                                                   "luminance": num(-100, 100, 0, SLIDER)}}
               for zone in ("shadows", "midtones", "highlights", "global")},
            "balance": num(-100, 100, 0, SLIDER), "blending": num(0, 100, 50, PERCENT)},
         "note": "legacy Split Toning is folded in by the generator (ColorGrade* wins, else SplitToning*)",
         "status": "calibrated", "equation": "rendering-v2.md#g10-colour-grading"},
        {"id": "grayscale", "params": {"mix": BAND_ARRAY}, "status": "calibrated", "equation": "rendering-v2.md#g11-grayscale"},
    ]


def develop_spatial_operators():
    return [
        {"id": "noiseReduction", "params": {"luminance": num(0, 100, 0, PERCENT), "luminanceDetail": num(0, 100, 50, PERCENT),
                                            "luminanceContrast": num(0, 100, 0, PERCENT), "color": num(0, 100, 0, PERCENT),
                                            "colorDetail": num(0, 100, 50, PERCENT), "colorSmoothness": num(0, 100, 50, PERCENT)},
         "status": "provisional-uncalibrated", "equation": "rendering-v2.md#s1-noise-reduction"},
        {"id": "clarity", "params": {"amount": num(-100, 100, 0, SLIDER)}, "status": "calibrated-not-validated",
         "equation": "rendering-v2.md#s2-clarity-and-texture"},
        {"id": "texture", "params": {"amount": num(-100, 100, 0, SLIDER)}, "status": "calibrated-not-validated",
         "equation": "rendering-v2.md#s2-clarity-and-texture"},
        {"id": "dehazeLocal", "params": {}, "status": "reserved",
         "note": "local (spatially varying) dehaze is not implemented; develop.global's dehaze approximation is used"},
        {"id": "sharpening", "params": {"amount": num(0, 150, 0, SLIDER), "radius": num(0.5, 3.0, 1.0, "lightroom-pixels-at-reference-long-edge"),
                                        "detail": num(0, 100, 25, PERCENT), "edgeMasking": num(0, 100, 0, PERCENT)},
         "status": "provisional-uncalibrated", "equation": "rendering-v2.md#s3-sharpening"},
    ]


def finishing_operators():
    return [
        {"id": "vignette", "params": {"amount": num(-100, 100, 0, SLIDER), "midpoint": num(0, 100, 50, PERCENT),
                                      "feather": num(0, 100, 50, PERCENT), "roundness": num(-100, 100, 0, SLIDER),
                                      "style": enum([1, 2, 3], 1, "1 highlight priority, 2 colour priority, 3 paint overlay"),
                                      "highlightContrast": num(0, 100, 0, PERCENT)},
         "status": "experimental-uncalibrated", "equation": "rendering-v2.md#f1-vignette"},
        {"id": "grain", "params": {"amount": num(0, 100, 0, PERCENT), "size": num(0, 100, 25, PERCENT),
                                   "roughness": num(0, 100, 50, PERCENT, "Lightroom GrainFrequency"),
                                   "seed": num(0, 4294967295, 0, "uint32", integer=True)},
         "status": "experimental-uncalibrated", "equation": "rendering-v2.md#f2-grain",
         "note": "revision 1: lightness only with chromaticity kept (a, b scaled with L); renders with fewer than 2 px per "
                 "grain cell are supersampled by s = ceil(2·cells/longEdge) and box-averaged"},
    ]


def focus_constants() -> dict:
    """background.focus constants (rendering-v2.md §7.1). Contract fixes 1 re-derived maxBlurRadius and the
    depth-of-field slope from the approved bg-* screens (docs/v1/contract-fixes-1.md §1)."""
    return {
        "maxBlurRadius": {"value": 0.06, "unit": LONG_EDGE, "note": "radius at blur 100 for the depth farthest from the focal plane"},
        "focusHalfWidthPerUnit": {"value": 0.5, "unit": "disparity", "note": "h = 0.5·depthOfField/100"},
        "defocusRange": {"definition": "S = max(d_f, 1 − d_f)",
                         "note": "c = sign(D − d_f)·clamp((|D − d_f| − h)/max(S − h, 1e-6), 0, 1)·R_max"},
        "subjectInFocus": "when the focus is on the subject (target null with a subject, or M(target) ≥ 0.5), the subject plane's CoC is 0",
        "layersPerSide": {"export": 8, "interactivePreview": 4},
        "subjectDepthCompression": 0.5,
        "replacementMinGap": 0.10,
        "highlightExpansion": {"threshold": 0.70, "gain": 0.85, "styles": ["lens", "swirl", "motion"]},
        "focusWindowHalfSize": {"value": 0.01, "unit": LONG_EDGE},
        "disparityNormalisation": "D = clamp((raw − p1)/(p99 − p1), 0, 1), then bilinear to the working size and a guided filter "
                                  "(grey guide, radius round(0.006·long edge) ≥ 2 px, ε 1e-3), clamped to [0, 1]",
        "pullPush": "pull: 2×2 box mean with edge padding of an odd row/column, α' = min(4α, 1), colour scaled by α'/α, "
                    "repeated until the level is 1×1; push: C_l += (1 − clamp(α_l, 0, 1))·bilinear_halfpixel(C_{l+1})",
    }


def stages():
    return [
        {"order": 1, "id": "auto", "frame": "source", "recipe": "editState.auto",
         "operators": [{"id": "autoLut", "params": {"strength": num(0, 1, 1, "fraction")},
                        "note": "ia3dlut fused 33³ LUT from the stored weights and guardrail (EditState schema 2); "
                                "out = in + strength·(LUT(in) − in). Skipped when modelVersion is no-model-in-build.",
                        "status": "existing"}]},
        {"order": 2, "id": "develop.global", "frame": "source", "recipe": "pack preset recipe.global, editState.look.strength",
         "operators": develop_global_operators(),
         "bake": {"lutDimension": 33, "grid": "linspace(0, 1, N) per axis", "layout": "[b][g][r][rgb], red fastest",
                  "interpolation": "trilinear", "amount": "out = in + strength·(LUT(in) − in)"},
         "override": "a Lightroom HALD LUT replaces the bake only when bound evidence validates it (rendering-v2.md §4.4)"},
        {"order": 3, "id": "develop.spatial", "frame": "source", "recipe": "pack preset recipe.spatial",
         "operators": develop_spatial_operators(),
         "amount": "amount-like parameters (noise reduction luminance/color, clarity, texture, sharpening amount) are multiplied by strength"},
        {"order": 4, "id": "edit.geometry", "frame": "source → frame", "recipe": "editState.tools.edit.geometry",
         "operators": [
             {"id": "quarterTurns", "params": {"quarterTurns": num(0, 3, 0, "90-degree clockwise turns", integer=True)}},
             {"id": "flip", "params": {"horizontal": {"type": "boolean", "default": False}, "vertical": {"type": "boolean", "default": False}},
              "note": "in the turned frame (what the user sees)"},
             {"id": "perspective", "params": {"vertical": num(-100, 100, 0, SLIDER), "horizontal": num(-100, 100, 0, SLIDER)},
              "note": "keystone about the frame centre; ±100 = the far edge scaled by 1 ∓ 0.3"},
             {"id": "straighten", "params": {"degrees": num(-45, 45, 0, "degrees, clockwise positive")},
              "note": "rotated about the centre and scaled by the smallest factor that leaves no empty corner"},
             {"id": "crop", "params": {"aspect": enum(["original", "free", "1:1", "4:5", "3:2", "16:9", "9:16"], "original"),
                                       "rect": {"type": "rect", "unit": FRAME, "default": [0, 0, 1, 1]}},
              "note": "rect [x, y, w, h] in the straightened frame; for a fixed aspect, w/h equals it in pixels"}]},
        {"order": 5, "id": "edit.adjust", "frame": "frame", "recipe": "editState.tools.edit.adjust",
         "operators": [
             {"id": "adjustColour", "maps": "develop.global model with: exposure.ev = exposure/50; toneSliders contrast, highlights, "
                                            "shadows = same values; whiteBalance temperature = temp, tint = tint; vibranceSaturation "
                                            "saturation, vibrance = same values (all other operators neutral)",
              "params": {k: num(-100, 100, 0, SLIDER) for k in ("exposure", "contrast", "highlights", "shadows", "temp", "tint",
                                                                 "saturation", "vibrance")},
              "status": "provisional-mapping"},
             {"id": "adjustDetail", "maps": "develop.spatial operators with: noiseReduction luminance = color = noise (other "
                                            "parameters at defaults); clarity.amount = clarity; sharpening amount = sharpness, "
                                            "radius 1.0, detail 25, edgeMasking 0",
              "params": {"sharpness": num(0, 100, 0, PERCENT), "clarity": num(-100, 100, 0, SLIDER), "noise": num(0, 100, 0, PERCENT)},
              "status": "provisional-mapping"}]},
        {"order": 6, "id": "edit.remove", "frame": "frame (strokes stored in source coordinates)", "recipe": "editState.tools.edit.remove",
         "operators": [{"id": "inpaint", "params": {"strokes": {"type": "array", "note": "see edit-recipe-v1 removeStroke"}},
                        "note": "each applied stroke's result patch is stored by digest and replayed, never recomputed silently; "
                                "blocked on dependency D4 (no on-device inpainting model)", "status": "blocked-D4"}]},
        {"order": 7, "id": "background.replace", "frame": "frame", "recipe": "editState.tools.background.replacement",
         "operators": [{"id": "replaceBackground",
                        "note": "subject matte (segmentation) composites the subject over the replacement (image, colour or gradient). "
                                "The replacement first receives the photo's global colour (auto, develop.global at strength, "
                                "adjustColour), as in the approved prototype; no spatial operator is applied to it.",
                        "params": {"x": num(0, 100, 50, PERCENT), "y": num(0, 100, 50, PERCENT), "scale": num(100, 200, 100, PERCENT)}}]},
        {"order": 8, "id": "background.focus", "frame": "frame", "recipe": "editState.tools.background.focus",
         "operators": [{"id": "depthBlur",
                        "params": {"blur": num(0, 100, 0, PERCENT), "depthOfField": num(0, 100, 40, PERCENT, "'Focus depth' slider"),
                                   "style": enum(["lens", "soft", "swirl", "motion"], "lens"),
                                   "bokeh": enum(["round", "hex", "heart", "star"], "round", "lens style only"),
                                   "styleAmount": num(0, 100, 50, PERCENT, "soft: glow, swirl: swirl, motion: direction (-180…180° = styleAmount·3.6−180)")},
                        "constants": focus_constants(),
                        "depthSources": {"embedded": "the photo's own depth/disparity map", "estimated": "Depth Anything V2 Small (D5)",
                                         "subject-matte": "no depth: the operator must not blur (blur 0 is enforced by the edit-recipe "
                                                          "reader); never a mask-only blur (depth-evaluation.md §R8)"},
                        "note": "rendering-v2.md §7.1 and docs/v1/depth-evaluation.md §6; executable reference experiments/depth/refocus.py. "
                                "The renderer works in disparity (1 near); the recipe stores depth (0 near), so disparity = 1 − depth. "
                                "Applies to the replaced background too (§R2.4 plane placement).",
                        "status": "calibrated-to-approved-prototype"}]},
        {"order": 9, "id": "portrait", "frame": "frame (faces stored in source coordinates)", "recipe": "editState.tools.portrait",
         "operators": [{"id": "faceRetouch", "params": {
             "skin.smoothing": num(0, 100, 0, PERCENT), "skin.blemishes": num(0, 100, 0, PERCENT), "skin.evenTone": num(0, 100, 0, PERCENT),
             "skin.keepTexture": num(0, 100, 85, PERCENT), "underEye.brighten": num(0, 100, 0, PERCENT), "underEye.softenLines": num(0, 100, 0, PERCENT),
             "eyes.brighten": num(0, 100, 0, PERCENT), "eyes.clarity": num(0, 100, 0, PERCENT), "teeth.brighten": num(0, 100, 0, PERCENT),
             "hair.definition": num(0, 100, 0, PERCENT), "hair.flyaways": num(0, 100, 0, PERCENT), "hair.shine": num(0, 100, 0, PERCENT)},
             "note": "per face, in face-region masks from landmarks; eye colour/shape and skin tone colour are never changed",
             "status": "provisional"}]},
        {"order": 10, "id": "effects", "frame": "frame", "recipe": "editState.tools.effects + preset recipe.finishing",
         "operators": [
             {"id": "lightLeak", "params": {"style": enum(["warm", "amber", "rose", "prism"], "warm"), "intensity": num(0, 100, 55, PERCENT),
                                            "x": num(0, 100, 18, PERCENT), "y": num(0, 100, 14, PERCENT), "rotation": num(-180, 180, 0, "degrees")},
              "status": "provisional"},
             {"id": "presetVignette", "operator": "vignette", "source": "preset recipe.finishing.vignette (amount × look strength)"},
             {"id": "userVignette", "operator": "vignette",
              "maps": "amount = −effects.vignette.amount, midpoint = size, feather = softness, roundness 0, style 1, highlightContrast 0"},
             {"id": "presetGrain", "operator": "grain", "source": "preset recipe.finishing.grain (amount × look strength)"},
             {"id": "userGrain", "operator": "grain",
              "maps": "amount, size, roughness from effects.grain; style fine: size × 0.7, film: size × 1.0, coarse: size × 1.5 (capped at 100); "
                      "seed from effects.grain.seed"}],
         "note": "user effects are added on top of the preset's own vignette/grain, never replace them (approved notice)"},
        {"order": 11, "id": "border", "frame": "frame → canvas", "recipe": "editState.tools.border",
         "operators": [{"id": "border", "params": {"type": enum(["none", "solid", "frame", "polaroid"], "none"),
                                                   "width": num(1, 15, 4, "percent-of-image-width"), "spacing": num(0, 12, 3, "percent-of-image-width")},
                        "note": "insets as fractions of the image width: solid [w, w, w]; frame [(w+s), (w+s), (w+s)] with a mat band s inside "
                                "a frame band w; polaroid [0.055, 0.055, 0.24] (side, top, bottom)"}]},
        {"order": 12, "id": "watermark", "frame": "canvas", "recipe": "editState.tools.watermark",
         "operators": [{"id": "watermark", "params": {"size": num(10, 80, 34, "size-units"), "opacity": num(0, 100, 85, PERCENT),
                                                      "position": num(0, 8, 8, "anchor index (row-major 3×3)", integer=True)},
                        "note": "height at size 34: signature 0.068, text font size 0.047, logo 0.079 of the image's short edge; "
                                "linear in size. Anchors at 6/50/94 % of the frame. On a border: centred in the bottom margin "
                                "(polaroid 6 %, other borders 1 % from the bottom)", "status": "provisional"}]},
    ]


def develop_model():
    calibration = json.loads((PRESETS / "calibration_natural.json").read_text())
    spatial = json.loads((PRESETS / "calibration_spatial_natural.json").read_text())
    sys.path.insert(0, str(PRESETS))
    import lr_model  # noqa: PLC0415 (only for its published experimental constants)
    experimental = {"VIGNETTE_K": lr_model.VIGNETTE_K, "GRAIN_K": lr_model.GRAIN_K, "GRAIN_REF_LONG": lr_model.GRAIN_REF_LONG}
    provisional = {"referenceLongEdgePx": 3000, "k_sharpen": 1.0, "sharpenDetailThreshold": 0.02, "sharpenEdgeScale": 0.05,
                   "nrLumaRadiusPx": 2.0, "nrDetailScale": 0.05, "nrColourRadiusPx": 4.0}
    body = {"constants": calibration["constants"], "curveMethod": calibration["curve_method"],
            "spatialConstants": spatial, "experimentalConstants": experimental, "provisionalConstants": provisional}
    canonical = json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
    return {"id": "lightly-develop-model", "version": 1,
            "source": "experiments/presets/lr_model.py (render, apply_local_contrast, apply_vignette, apply_grain)",
            "calibration": {"global": "experiments/presets/calibration_natural.json",
                            "spatial": "experiments/presets/calibration_spatial_natural.json",
                            "heldOutMedianDeltaE00": 4.8},
            "constantsSha256": hashlib.sha256(canonical).hexdigest(), **body}


def contract() -> dict:
    return {
        "contract": "lightly-rendering", "version": 2, "revision": CONTRACT_REVISION,
        "changeLog": "shared/contracts/rendering-v2.md#change-log",
        "prose": "shared/contracts/rendering-v2.md",
        "generatedBy": "shared/contracts/build_rendering_v2.py",
        "conventions": {
            "pixels": "sRGB-encoded floats in [0, 1] between stages; operators linearise internally where stated",
            "luma": [0.2126, 0.7152, 0.0722],
            "radii": LONG_EDGE + " of the stage's input image, so preview and export match",
            "coordinates": {"source": "oriented original, normalised [0, 1], origin top-left",
                            "frame": "after edit.geometry (turned, flipped, perspective, straightened, cropped)",
                            "canvas": "frame plus border"},
            "colours": "#RRGGBB, sRGB",
            "angles": "degrees",
        },
        "stages": stages(),
        "developModel": develop_model(),
        "lookVersion": {"definition": "first 12 hex digits of sha256 over the canonical JSON (sorted keys, no spaces) of "
                                      "{recipeVersion, recipe, developModel: {id, version, constantsSha256}, globalOverrideSha256}",
                        "semantics": "EditState schema 2 rules: lookId missing → unavailable; lookVersion differs → changed; "
                                     "never substitute"},
    }


def main(argv):
    text = json.dumps(contract(), indent=1, ensure_ascii=False) + "\n"
    if "--check" in argv:
        if not OUT.exists() or OUT.read_text() != text:
            print(f"{OUT} is out of date; run {Path(__file__).name}")
            return 1
        return 0
    OUT.write_text(text)
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
