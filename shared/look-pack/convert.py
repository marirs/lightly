"""Convert one preset's Lightroom develop settings into a pack recipe plus its complete coverage record.

Nothing is dropped silently: every non-default setting ends up in exactly one place (rendering-v2.md §3):
- consumed by a recipe operator (listed in `operators`), possibly with an `approximated` record;
- `unsupported`: changes how the photo looks but Lightly cannot render it (the rest of the preset renders);
- `notApplied`: deliberately not part of a Look on a rendered photo (lens corrections, raw-only settings,
  inactive legacy keys). Entries resting on an unverified assumption say so (`assumption: true`).
Metadata (names, UUIDs, support flags) is not a setting and is not recorded.

The global numbers are read through `lr_model.Preset`, the same parser the calibrated model uses, so the
recipe carries exactly what the model reads; `build_pack.verify_recipe` re-renders both ways to prove it.
"""
from __future__ import annotations

import hashlib
import re
import struct
import sys
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PRESETS_EXPERIMENTS = REPO / "experiments/presets"
if str(PRESETS_EXPERIMENTS) not in sys.path:
    sys.path.insert(0, str(PRESETS_EXPERIMENTS))

import classify  # noqa: E402  (is_default / metadata rules shared with the coverage report)
import lr_model  # noqa: E402

RECIPE_VERSION = 1

GLOBAL_OPERATORS = ("calibration", "whiteBalance", "exposure", "shadowTint", "toneSliders", "dehaze",
                    "parametricCurve", "toneCurve", "hsl", "vibranceSaturation", "colorGrading", "grayscale")
SPATIAL_OPERATORS = ("noiseReduction", "clarity", "texture", "sharpening")
# Carried by the preset, evaluated in stage `effects` in frame coordinates (rendering-v2.md §4.2).
FINISHING_OPERATORS = ("vignette", "grain")
ALL_OPERATORS = GLOBAL_OPERATORS + SPATIAL_OPERATORS + FINISHING_OPERATORS

HSL_BANDS = lr_model.HSL_BANDS  # Red, Orange, ... in recipe array order
CURVE_KEYS = {"master": "ToneCurvePV2012", "red": "ToneCurvePV2012Red", "green": "ToneCurvePV2012Green",
              "blue": "ToneCurvePV2012Blue"}

# Keys each operator consumes (for the coverage bookkeeping; numbers come from lr_model.Preset).
OPERATOR_KEYS = {
    "calibration": ("RedHue", "RedSaturation", "GreenHue", "GreenSaturation", "BlueHue", "BlueSaturation"),
    "whiteBalance": ("IncrementalTemperature", "IncrementalTint"),
    "exposure": ("Exposure2012",),
    "shadowTint": ("ShadowTint",),
    "toneSliders": ("Contrast2012", "Highlights2012", "Shadows2012", "Whites2012", "Blacks2012"),
    "dehaze": ("Dehaze",),
    "parametricCurve": ("ParametricShadows", "ParametricDarks", "ParametricLights", "ParametricHighlights",
                        "ParametricShadowSplit", "ParametricMidtoneSplit", "ParametricHighlightSplit"),
    "toneCurve": tuple(CURVE_KEYS.values()),
    "hsl": tuple(f"{kind}Adjustment{band}" for kind in ("Hue", "Saturation", "Luminance") for band in HSL_BANDS),
    "vibranceSaturation": ("Vibrance", "Saturation"),
    "colorGrading": ("ColorGradeShadowHue", "ColorGradeShadowSat", "ColorGradeShadowLum", "ColorGradeMidtoneHue",
                     "ColorGradeMidtoneSat", "ColorGradeMidtoneLum", "ColorGradeHighlightHue", "ColorGradeHighlightSat",
                     "ColorGradeHighlightLum", "ColorGradeGlobalHue", "ColorGradeGlobalSat", "ColorGradeGlobalLum",
                     "ColorGradeBalance", "ColorGradeBlending", "SplitToningShadowHue", "SplitToningShadowSaturation",
                     "SplitToningHighlightHue", "SplitToningHighlightSaturation", "SplitToningBalance"),
    "grayscale": ("ConvertToGrayscale",) + tuple(f"GrayMixer{band}" for band in HSL_BANDS),
    "noiseReduction": ("LuminanceSmoothing", "LuminanceNoiseReductionDetail", "LuminanceNoiseReductionContrast",
                       "ColorNoiseReduction", "ColorNoiseReductionDetail", "ColorNoiseReductionSmoothness"),
    "clarity": ("Clarity2012",),
    "texture": ("Texture",),
    "sharpening": ("Sharpness", "SharpenRadius", "SharpenDetail", "SharpenEdgeMasking"),
    "vignette": ("PostCropVignetteAmount", "PostCropVignetteMidpoint", "PostCropVignetteFeather",
                 "PostCropVignetteRoundness", "PostCropVignetteStyle", "PostCropVignetteHighlightContrast"),
    "grain": ("GrainAmount", "GrainSize", "GrainFrequency", "GrainSeed"),
}
KEY_OPERATOR = {key: op for op, keys in OPERATOR_KEYS.items() for key in keys}

# Every code a preset can carry, with its one reason. The manifest publishes this table once; each preset
# lists {code, keys} so the record per preset stays small but complete.
COVERAGE_CODES = {
    # approximated: rendered, by an approximation
    "adaptive-tone-global": ("approximated", "Lightroom applies Highlights/Shadows/Whites/Blacks adaptively (locally); "
                             "Lightly applies the calibrated global curve"),
    "dehaze-global": ("approximated", "Lightroom's Dehaze varies across the image; Lightly applies the calibrated "
                      "global veil-removal approximation (local dehaze is reserved, not implemented)"),
    "local-contrast-calibrated": ("approximated", "Clarity/Texture use Lightly's local-contrast operator, calibrated "
                                  "against Lightroom renders but not validated"),
    "sharpening-provisional": ("approximated", "Sharpening uses a provisional Lightly unsharp mask; not calibrated"),
    "noise-reduction-provisional": ("approximated", "Noise reduction uses a provisional Lightly smoothing operator; "
                                    "not calibrated"),
    "vignette-uncalibrated": ("approximated", "Post-crop vignette follows Lightroom's controls with uncalibrated constants"),
    "grain-uncalibrated": ("approximated", "Grain follows Lightroom's controls with uncalibrated constants and a "
                           "portable random field (not Lightroom's grain pattern)"),
    "iso-adaptive": ("approximated", "ISO-adaptive preset: Lightroom interpolates these settings by the photo's ISO; "
                     "Lightly applies the preset's fixed values (ISO interpolation not implemented)"),
    "process-version-2012": ("approximated", "Process version 6.7 (PV2012) is rendered with the model calibrated on "
                             "process versions 10/11 (Version 5/6); the difference is unmeasured"),
    # unsupported: changes the look, not rendered
    "local-adjustments": ("unsupported", "Local adjustments (masks, gradients, brushes) cannot be converted; "
                          "the rest of the preset renders"),
    "creative-profile": ("unsupported", "Creative profile referenced without its embedded table (a stub), so it "
                         "cannot be rendered"),
    "camera-profile": ("unsupported", "Camera profile that is not a standard raw base profile; not rendered"),
    "lens-vignetting": ("unsupported", "Manual lens-vignetting correction (VignetteAmount); not converted"),
    "curve-refine-saturation": ("unsupported", "Tone-curve saturation refinement; not modelled"),
    "point-color": ("unsupported", "Point Color (targeted colour ranges); not implemented"),
    "process-version-2010": ("unsupported", "Process version before 6.7 (PV2010 or older); its tone sliders are not "
                             "converted"),
    "enhance-filter": ("unsupported", "Enhance filter (Denoise / Super Resolution / Raw Details) that changes pixels"),
    "malformed-tone-curve": ("unsupported", "Tone curve that cannot be parsed"),
    "unrecognised": ("unsupported", "Setting with no mapping defined"),
    # notApplied: deliberately not part of a Look on a rendered (JPEG/HEIC) photo
    "absolute-white-balance": ("notApplied", "Absolute Temperature/Tint apply to raw files; Lightroom uses the "
                               "incremental values on rendered photos (assumption, unverified)"),
    "raw-base-profile": ("notApplied", "Standard raw base profile (Default Color / Adobe Standard / Camera Standard, or the "
                         "Adobe Color profile Look); raw profiles do not apply to rendered photos (assumption, unverified)"),
    "lens-corrections": ("notApplied", "Lens profile, chromatic aberration and defringe corrections are camera/lens "
                         "repairs, not part of a Look"),
    "geometry": ("notApplied", "Crop, perspective and upright are per-photo geometry, not part of a Look"),
    "enhance-filter-off": ("notApplied", "Enhance filter entry with Denoise, Super Resolution and Raw Details all off "
                           "(decoded): no pixel effect"),
    "legacy-pv2010-inactive": ("notApplied", "Legacy PV2010 key written alongside PV2012+ settings; Lightroom does "
                               "not use it under process version 2012+"),
}
ASSUMPTION_CODES = {"absolute-white-balance", "raw-base-profile"}

RAW_BASE_PROFILES = {"Default Color", "Adobe Standard", "Camera Standard", "Adobe Color"}
LEGACY_PV2010_KEYS = {"Brightness", "Shadows", "Contrast", "Exposure", "Clarity", "FillLight", "HighlightRecovery",
                      "ToneCurve", "ToneCurveName"}
PV2012_OR_LATER = ("6.7", "10", "11", "15")
# Containers whose nested rdf:Description values lrsettings merges into the top level (it walks every
# Description). Their nested keys are attributed to the container, never treated as global settings.
MASK_CONTAINERS = ("MaskGroupBasedCorrections", "GradientBasedCorrections", "CircularGradientBasedCorrections",
                   "PaintBasedCorrections", "RetouchAreas")
MASK_NESTED_KEYS = {"What", "Dabs", "Radius", "Flow", "CenterWeight", "ZeroX", "ZeroY", "FullX", "FullY", "Top", "Left",
                    "Bottom", "Right", "Angle", "Midpoint", "Roundness", "Feather", "Flipped", "Masks", "SizeX", "SizeY",
                    "Alpha", "Version", "Invert"}
MASK_NESTED_PREFIXES = ("Local", "Mask", "Correction", "Range", "Origin")
LOOK_NESTED_KEYS = {"Amount", "Stubbed", "Cluster", "Parameters"}
FILTER_KEYS_PREFIX = ("FilterList", "AllowFilters", "FilterID", "Src", "Dst", "ShouldDelete", "IsSignal", "OrderIndex",
                      "MinDisplay", "MinEdit", "Images", "CompressedSettings", "Title", "Table_",
                      "Reference", "BlendType")
LENS_PREFIX = ("Lens", "AutoLateralCA", "Defringe", "ChromaticAberration", "PerspectiveUpright", "LensManual")
GEOMETRY_PREFIX = ("Crop", "HasCrop", "Perspective", "Upright", "orientation")
EXTRA_METADATA = {"OverrideLookVignette", "HDREditMode", "SupportsAmount2"}
# Lightroom defaults that classify.is_default does not know (no pixel effect at these values).
EXTRA_DEFAULTS = {"DefringePurpleHueLo": "30", "DefringePurpleHueHi": "70", "DefringeGreenHueLo": "40",
                  "DefringeGreenHueHi": "60", "PerspectiveScale": "100"}

# Lightroom defaults for the spatial keys (rendered input).
SPATIAL_DEFAULTS = {
    "SharpenRadius": 1.0, "SharpenDetail": 25.0, "SharpenEdgeMasking": 0.0,
    "LuminanceNoiseReductionDetail": 50.0, "LuminanceNoiseReductionContrast": 0.0,
    "ColorNoiseReductionDetail": 50.0, "ColorNoiseReductionSmoothness": 50.0,
    "PostCropVignetteMidpoint": 50.0, "PostCropVignetteFeather": 50.0, "PostCropVignetteRoundness": 0.0,
    "PostCropVignetteStyle": 1.0, "PostCropVignetteHighlightContrast": 0.0,
    "GrainSize": 25.0, "GrainFrequency": 50.0,
}


def number(value: float):
    """Integers as JSON integers, everything else unchanged (the model must see the exact value)."""
    value = float(value)
    return int(value) if value.is_integer() and abs(value) < 2 ** 53 else value


def _f(settings: dict, key: str, default: float = 0.0) -> float:
    return lr_model._f(settings, key, SPATIAL_DEFAULTS.get(key, default))


def curve_points(raw) -> list | None:
    """Recipe form of a Lightroom point curve, normalised as lr_model.curve_lut reads it (sorted, last x wins).

    Returns None for an absent or identity curve. Raises ValueError for a malformed one.
    """
    if not isinstance(raw, list) or len(raw) < 2:
        if raw in (None, "", []):
            return None
        raise ValueError(f"tone curve {raw!r}")
    try:
        unique = {float(p.split(",")[0]): float(p.split(",")[1]) for p in raw}
    except (ValueError, IndexError, AttributeError) as error:
        raise ValueError(f"tone curve {raw!r}") from error
    points = sorted(unique.items())
    if len(points) == 2 and points[0] == (0.0, 0.0) and points[1] == (255.0, 255.0):
        return None
    if len(points) < 2:
        raise ValueError(f"tone curve with a single distinct x: {raw!r}")
    return [[number(x), number(y)] for x, y in points]


# ------------------------------------------------------------------ recipe

def build_recipe(settings: dict, preset_id: str) -> tuple[dict, list[str], list[str]]:
    """(recipe, operators in pipeline order, malformed curve keys)."""
    preset = lr_model.Preset(settings, wb_mode="rendered")
    v = preset.v
    g: dict = {}
    if any(v[k] for k in OPERATOR_KEYS["calibration"]):
        g["calibration"] = {"redHue": number(v["RedHue"]), "redSaturation": number(v["RedSaturation"]),
                            "greenHue": number(v["GreenHue"]), "greenSaturation": number(v["GreenSaturation"]),
                            "blueHue": number(v["BlueHue"]), "blueSaturation": number(v["BlueSaturation"])}
    if v["IncrementalTemperature"] or v["IncrementalTint"]:
        g["whiteBalance"] = {"temperature": number(v["IncrementalTemperature"]), "tint": number(v["IncrementalTint"])}
    if v["Exposure2012"]:
        g["exposure"] = {"ev": number(v["Exposure2012"])}
    if v["ShadowTint"]:
        g["shadowTint"] = {"amount": number(v["ShadowTint"])}
    if any(v[k] for k in OPERATOR_KEYS["toneSliders"]):
        g["toneSliders"] = {"contrast": number(v["Contrast2012"]), "highlights": number(v["Highlights2012"]),
                            "shadows": number(v["Shadows2012"]), "whites": number(v["Whites2012"]),
                            "blacks": number(v["Blacks2012"])}
    if v["Dehaze"]:
        g["dehaze"] = {"amount": number(v["Dehaze"])}
    if any(v[k] for k in ("ParametricShadows", "ParametricDarks", "ParametricLights", "ParametricHighlights")):
        s1, s2, s3 = preset.splits
        g["parametricCurve"] = {"shadows": number(v["ParametricShadows"]), "darks": number(v["ParametricDarks"]),
                                "lights": number(v["ParametricLights"]), "highlights": number(v["ParametricHighlights"]),
                                "shadowSplit": number(s1 * 100), "midtoneSplit": number(s2 * 100),
                                "highlightSplit": number(s3 * 100)}
    curves, malformed = {}, []
    for channel, key in CURVE_KEYS.items():
        try:
            points = curve_points(settings.get(key))
        except ValueError:
            malformed.append(key)
            continue
        if points is not None:
            curves[channel] = points
    if curves:
        g["toneCurve"] = curves
    hue = [number(v[f"HueAdjustment{b}"]) for b in HSL_BANDS]
    sat = [number(v[f"SaturationAdjustment{b}"]) for b in HSL_BANDS]
    lum = [number(v[f"LuminanceAdjustment{b}"]) for b in HSL_BANDS]
    if any(hue + sat + lum):
        g["hsl"] = {"hue": hue, "saturation": sat, "luminance": lum}
    if v["Vibrance"] or v["Saturation"]:
        g["vibranceSaturation"] = {"vibrance": number(v["Vibrance"]), "saturation": number(v["Saturation"])}
    grading = preset.grading
    zones = {"shadows": ("sh_hue", "sh_sat", "sh_lum"), "midtones": ("mid_hue", "mid_sat", "mid_lum"),
             "highlights": ("hi_hue", "hi_sat", "hi_lum"), "global": ("gl_hue", "gl_sat", "gl_lum")}
    if any(grading[s] or grading[l] for _, s, l in zones.values()):  # lr_model applies a zone only if sat or lum
        g["colorGrading"] = {name: {"hue": number(grading[h]), "saturation": number(grading[s]),
                                    "luminance": number(grading[l])} for name, (h, s, l) in zones.items()}
        g["colorGrading"].update(balance=number(grading["balance"]), blending=number(grading["blending"]))
    if preset.gray:
        g["grayscale"] = {"mix": [number(x) for x in preset.gray_mix]}

    spatial: dict = {}
    if _f(settings, "LuminanceSmoothing") or _f(settings, "ColorNoiseReduction"):
        spatial["noiseReduction"] = {
            "luminance": number(_f(settings, "LuminanceSmoothing")),
            "luminanceDetail": number(_f(settings, "LuminanceNoiseReductionDetail")),
            "luminanceContrast": number(_f(settings, "LuminanceNoiseReductionContrast")),
            "color": number(_f(settings, "ColorNoiseReduction")),
            "colorDetail": number(_f(settings, "ColorNoiseReductionDetail")),
            "colorSmoothness": number(_f(settings, "ColorNoiseReductionSmoothness"))}
    if _f(settings, "Clarity2012"):
        spatial["clarity"] = {"amount": number(_f(settings, "Clarity2012"))}
    if _f(settings, "Texture"):
        spatial["texture"] = {"amount": number(_f(settings, "Texture"))}
    if _f(settings, "Sharpness"):
        spatial["sharpening"] = {"amount": number(_f(settings, "Sharpness")),
                                 "radius": number(_f(settings, "SharpenRadius")),
                                 "detail": number(_f(settings, "SharpenDetail")),
                                 "edgeMasking": number(_f(settings, "SharpenEdgeMasking"))}
    finishing: dict = {}
    if _f(settings, "PostCropVignetteAmount"):
        finishing["vignette"] = {
            "amount": number(_f(settings, "PostCropVignetteAmount")),
            "midpoint": number(_f(settings, "PostCropVignetteMidpoint")),
            "feather": number(_f(settings, "PostCropVignetteFeather")),
            "roundness": number(_f(settings, "PostCropVignetteRoundness")),
            "style": int(_f(settings, "PostCropVignetteStyle")),
            "highlightContrast": number(_f(settings, "PostCropVignetteHighlightContrast"))}
    if _f(settings, "GrainAmount"):
        seed = settings.get("GrainSeed")
        try:
            seed = int(str(seed)) & 0xFFFFFFFF
        except (TypeError, ValueError):
            # No seed in the preset: a fixed seed per preset, so the grain is the same on every render.
            seed = int(hashlib.sha256(preset_id.encode()).hexdigest()[:8], 16)
        finishing["grain"] = {"amount": number(_f(settings, "GrainAmount")), "size": number(_f(settings, "GrainSize")),
                              "roughness": number(_f(settings, "GrainFrequency")), "seed": seed}
    recipe = {"global": g, "spatial": spatial, "finishing": finishing}
    operators = [op for op in ALL_OPERATORS if op in g or op in spatial or op in finishing]
    return recipe, operators, malformed


# ------------------------------------------------------------------ coverage

def decode_adobe_table(encoded: str) -> bytes:
    """Decode a crs:Table_<digest> value: Adobe's base-85 alphabet, 4-byte length, then zlib."""
    alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#"
    lookup = {c: i for i, c in enumerate(alphabet)}
    raw = bytearray()
    for start in range(0, len(encoded), 5):
        group = encoded[start:start + 5]
        value = sum(lookup[c] * 85 ** i for i, c in enumerate(group))
        raw += struct.pack("<I", value & 0xFFFFFFFF)[:len(group) - 1 if len(group) < 5 else 4]
    length = struct.unpack("<I", bytes(raw[:4]))[0]
    data = zlib.decompress(bytes(raw[4:]))
    if len(data) != length:
        raise ValueError("table length mismatch")
    return data


def enhance_filter_is_off(settings: dict) -> bool:
    """True when every embedded filter table decodes to Enhance with Denoise, Super Resolution and Details off."""
    tables = [v for k, v in settings.items() if k.startswith("Table_")]
    if not tables:
        return False
    for value in tables:
        try:
            text = decode_adobe_table(str(value)).decode("utf-8", "ignore")
        except (ValueError, zlib.error, KeyError, struct.error):
            return False
        flags = dict(re.findall(r'crs:(\w+)="([^"]*)"', text))
        if flags.get("Denoise", "False") != "False" or flags.get("Details", "False") != "False" \
                or flags.get("SuperResolution", "1/1") != "1/1":
            return False
    return True


def _process_version_code(process_version: str) -> str | None:
    if not process_version:
        return None
    if process_version == "6.7":
        return "process-version-2012"
    if process_version.split(".")[0] in ("10", "11", "15"):
        return None
    return "process-version-2010"


def iso_dependent_keys(xmp_text: str) -> list[str]:
    """Settings an ISO-adaptive preset varies by ISO (crs:ISODependent). lrsettings keeps only empty strings for
    these list items (their values are attributes), so they are read from the XMP text here."""
    start = xmp_text.find("<crs:ISODependent")
    if start < 0:
        return []
    block = xmp_text[start:xmp_text.find("</crs:ISODependent>", start)]
    return sorted(set(re.findall(r"crs:(\w+)=", block)) - {"ISO"})


def coverage(settings: dict, operators: list[str], malformed_curves: list[str],
             iso_keys: list[str] | None = None) -> dict:
    """Assign every non-default setting to an operator or a coverage code. Returns the three lists."""
    found: dict[str, set] = {}

    def record(code: str, key: str):
        found.setdefault(code, set()).add(key)

    process_version = str(settings.get("ProcessVersion", ""))
    pv_code = _process_version_code(process_version)
    if pv_code:
        record(pv_code, "ProcessVersion")
    pv2012 = process_version.startswith(PV2012_OR_LATER)
    has_masks = any(not classify.is_default(k, settings.get(k)) for k in MASK_CONTAINERS if k in settings)
    look = settings.get("Look")
    filter_off = enhance_filter_is_off(settings)

    for key, value in settings.items():
        if classify.is_default(key, value) or key in classify.METADATA or key in EXTRA_METADATA \
                or EXTRA_DEFAULTS.get(key) == str(value).lstrip("+"):
            continue
        if key in malformed_curves:
            record("malformed-tone-curve", key)
            continue
        operator = KEY_OPERATOR.get(key)
        if operator is not None:
            if operator not in operators:
                continue  # e.g. a split or hue whose operator is neutral: no pixel effect
            if key in ("Highlights2012", "Shadows2012", "Whites2012", "Blacks2012"):
                record("adaptive-tone-global", key)
            elif operator == "dehaze":
                record("dehaze-global", key)
            elif operator in ("clarity", "texture"):
                record("local-contrast-calibrated", key)
            elif operator in ("sharpening", "noiseReduction", "vignette", "grain"):
                record({"sharpening": "sharpening-provisional", "noiseReduction": "noise-reduction-provisional",
                        "vignette": "vignette-uncalibrated", "grain": "grain-uncalibrated"}[operator], key)
            continue
        if key in ("Temperature", "Tint"):
            record("absolute-white-balance", key)
        elif key == "CameraProfile":
            record("raw-base-profile" if value in RAW_BASE_PROFILES else "camera-profile", key)
        elif key == "Look":
            # A Look that is not a parsed structure is still recorded, never dropped.
            name = look.get("Name") if isinstance(look, dict) else str(look)
            if name in RAW_BASE_PROFILES:
                record("raw-base-profile", f"Look:{name}")
            elif name:  # an empty Look element (<crs:Look crs:Name=""/>) selects nothing
                record("creative-profile", f"Look:{name}")
        elif key in LOOK_NESTED_KEYS and isinstance(look, dict) and key in look:
            continue  # merged from the Look's own Description; recorded with the Look
        elif key in MASK_CONTAINERS:
            record("local-adjustments", key)
        elif has_masks and (key in MASK_NESTED_KEYS or key.startswith(MASK_NESTED_PREFIXES)):
            continue  # merged from a mask's Description; recorded with its container
        elif key.startswith(FILTER_KEYS_PREFIX):
            record("enhance-filter-off" if filter_off else "enhance-filter", key if not key.startswith("Table_") else "Table_*")
        elif key == "ISODependent":
            for iso_key in iso_keys or ["ISODependent"]:
                record("iso-adaptive", f"ISODependent:{iso_key}")
        elif key == "PointColors":
            record("point-color", key)
        elif key == "VignetteAmount" or key == "VignetteMidpoint":
            record("lens-vignetting", key)
        elif key == "CurveRefineSaturation":
            record("curve-refine-saturation", key)
        elif key in LEGACY_PV2010_KEYS:
            record("legacy-pv2010-inactive" if pv2012 else "process-version-2010", key)
        elif key.startswith(LENS_PREFIX):
            record("lens-corrections", key)
        elif key.startswith(GEOMETRY_PREFIX):
            record("geometry", key)
        else:
            record("unrecognised", key)

    lists = {"approximated": [], "unsupported": [], "notApplied": []}
    for code in sorted(found):
        kind = COVERAGE_CODES[code][0]
        entry = {"code": code, "keys": sorted(found[code])}
        if code in ASSUMPTION_CODES:
            entry["assumption"] = True
        lists[kind].append(entry)
    return lists


# ------------------------------------------------------------------ strict top-level read (consistency check)

def top_level_settings(xmp_text: str) -> dict:
    """Only the preset's own rdf:Description (attributes and direct children), nothing nested.

    lrsettings merges every Description it finds (masks, Look, filters) into one dict. The builder uses that
    dict (it is what settingsSha256 and the evidence digest hash) but checks, with this strict read, that no
    nested value overwrote a setting a recipe operator consumes.
    """
    root = ET.fromstring(xmp_text.encode("utf-8"))
    rdf = "{http://www.w3.org/1999/02/22-rdf-syntax-ns#}"
    crs = "{http://ns.adobe.com/camera-raw-settings/1.0/}"
    rdf_root = root.find(f"{rdf}RDF") if root.tag != f"{rdf}RDF" else root
    out: dict = {}
    for description in rdf_root.findall(f"{rdf}Description"):
        for k, v in description.attrib.items():
            if k.startswith(crs):
                out[k[len(crs):]] = v
        for child in description:
            if child.tag.startswith(crs):
                seq = child.find(f"{rdf}Seq")
                out[child.tag[len(crs):]] = [li.text or "" for li in seq.findall(f"{rdf}li")] if seq is not None else "<nested>"
    return out


def check_no_nested_override(settings: dict, xmp_text: str, operators: list[str]) -> list[str]:
    """Keys consumed by an operator whose merged value differs from the preset's own top-level value."""
    strict = top_level_settings(xmp_text)
    consumed = {k for op in operators for k in OPERATOR_KEYS[op]}
    differs = {k for k in consumed if k in settings and k in strict and strict[k] != settings[k]}
    nested_only = {k for k in consumed if k in settings and k not in strict}  # came from a nested Description
    return sorted(differs | nested_only)


# ------------------------------------------------------------------ completeness and verbatim preservation

def completeness(cov: dict) -> str:
    """Recipe completeness, separate from validation (a represented setting is not a validated one).

    - incomplete:  some setting is not converted (an `unsupported` record exists);
    - approximate: everything is represented, some of it by an approximation (an `approximated` record);
    - complete:    every setting is converted to a Lightly operator with no recorded approximation.
    `notApplied` records do not lower completeness: they are not part of a Look on a rendered photo.
    """
    if cov["unsupported"]:
        return "incomplete"
    if cov["approximated"]:
        return "approximate"
    return "complete"


def _top_level_property_spans(xmp_text: str) -> tuple[dict, dict]:
    """Raw text of every property of the preset's own rdf:Description: (attributes, child elements).

    Attributes are returned as their XML-unescaped values; child elements as the exact source text
    (balanced on the element's own tag), so nested structures are preserved byte for byte.
    """
    attributes = top_level_settings_raw_attributes(xmp_text)
    elements: dict = {}
    start = xmp_text.find("<rdf:Description")
    body_start = xmp_text.find(">", start) + 1 if start >= 0 else 0
    position = body_start
    open_tag = re.compile(r"<crs:([A-Za-z0-9_]+)(?=[\s/>])")
    while True:
        match = open_tag.search(xmp_text, position)
        if not match:
            break
        name = match.group(1)
        end = _element_end(xmp_text, match.start(), name)
        elements.setdefault(name, xmp_text[match.start():end])
        position = end
    return attributes, elements


def _element_end(text: str, start: int, name: str) -> int:
    """End offset of the element <crs:name ...> starting at `start`, counting nested same-name elements."""
    tag_end = text.find(">", start)
    if text[tag_end - 1] == "/":
        return tag_end + 1
    depth, position = 1, tag_end + 1
    pattern = re.compile(rf"<crs:{name}(?=[\s/>])|</crs:{name}>")
    while depth:
        match = pattern.search(text, position)
        if match is None:
            return len(text)
        if match.group(0).startswith("</"):
            depth -= 1
            position = match.end()
        else:
            inner_end = text.find(">", match.start())
            if text[inner_end - 1] != "/":
                depth += 1
            position = inner_end + 1
    return position


def top_level_settings_raw_attributes(xmp_text: str) -> dict:
    root = ET.fromstring(xmp_text.encode("utf-8"))
    rdf = "{http://www.w3.org/1999/02/22-rdf-syntax-ns#}"
    crs = "{http://ns.adobe.com/camera-raw-settings/1.0/}"
    rdf_root = root.find(f"{rdf}RDF") if root.tag != f"{rdf}RDF" else root
    description = rdf_root.find(f"{rdf}Description")
    return {k[len(crs):]: v for k, v in description.attrib.items() if k.startswith(crs)}


def _source_property_names(record_key: str, settings: dict) -> list[str]:
    """Map a coverage record key to the preset's own property names ("Look:Vintage 01" -> Look, ...)."""
    if ":" in record_key:
        return [record_key.split(":", 1)[0]]
    if record_key == "Table_*":
        return sorted(k for k in settings if k.startswith("Table_"))
    return [record_key]


def unconverted_verbatim(xmp_text: str, settings: dict, cov: dict) -> dict:
    """Every unsupported or not-applied source property (and ISO-adaptive data), as found in the XMP.

    Kept so a later converter can use it without re-reading the private library. Values are
    {"attribute": "<unescaped value>"} or {"element": "<crs:...>...</crs:...>"} (exact source text), or
    {"nested": <lrsettings value>} for a key that only exists inside a nested Description.
    """
    attributes, elements = _top_level_property_spans(xmp_text)
    names: set = set()
    for kind in ("unsupported", "notApplied"):
        for record in cov[kind]:
            for key in record["keys"]:
                names.update(_source_property_names(key, settings))
    for record in cov["approximated"]:
        if record["code"] == "iso-adaptive":
            names.add("ISODependent")
    out: dict = {}
    for name in sorted(names):
        if name in attributes:
            out[name] = {"attribute": attributes[name]}
        elif name in elements:
            out[name] = {"element": elements[name]}
        elif name in settings:
            out[name] = {"nested": settings[name]}
    return out
