"""Classify every non-default develop parameter of every preset into a fidelity class.

A preset is never marked "converted" unless every non-default parameter is `modelled`, `spatial` or
`not-a-look`. Anything `approximated` is listed. Anything `unsupported` makes the preset `partial`.

Usage: python classify.py "<preset root>" -> conversion_report.json, conversion_summary.md (printed)
"""
import collections, json, re, sys
from pathlib import Path
import lrsettings

MODELLED = set("""IncrementalTemperature IncrementalTint Exposure2012 Contrast2012 Vibrance Saturation
ParametricShadows ParametricDarks ParametricLights ParametricHighlights ParametricShadowSplit ParametricMidtoneSplit ParametricHighlightSplit
ToneCurvePV2012 ToneCurvePV2012Red ToneCurvePV2012Green ToneCurvePV2012Blue
RedHue RedSaturation GreenHue GreenSaturation BlueHue BlueSaturation ShadowTint
SplitToningShadowHue SplitToningShadowSaturation SplitToningHighlightHue SplitToningHighlightSaturation SplitToningBalance
ColorGradeShadowHue ColorGradeShadowSat ColorGradeShadowLum ColorGradeMidtoneHue ColorGradeMidtoneSat ColorGradeMidtoneLum
ColorGradeHighlightHue ColorGradeHighlightSat ColorGradeHighlightLum ColorGradeGlobalHue ColorGradeGlobalSat ColorGradeGlobalLum
ColorGradeBlending ColorGradeBalance ConvertToGrayscale""".split()) | {f"{a}Adjustment{b}" for a in ("Hue", "Saturation", "Luminance")
    for b in ("Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta")} | {f"GrayMixer{b}" for b in
    ("Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta")}

APPROXIMATED = {
    "Highlights2012": "local tone mapping in Lightroom; modelled as a global curve",
    "Shadows2012": "local tone mapping in Lightroom; modelled as a global curve",
    "Whites2012": "adaptive in Lightroom; modelled as a global curve",
    "Blacks2012": "adaptive in Lightroom; modelled as a global curve",
    "Dehaze": "spatially varying in Lightroom; modelled as a global veil removal + curve",
    "Temperature": "absolute Kelvin applies to raw only; Lightroom ignores it on JPEG/HEIC, so Lightly ignores it on rendered photos (DNG validation uses a calibrated mapping)",
    "Tint": "absolute tint applies to raw only; ignored on rendered photos, as Lightroom does",
}
SPATIAL = {"PostCropVignetteAmount", "PostCropVignetteMidpoint", "PostCropVignetteFeather", "PostCropVignetteRoundness",
           "PostCropVignetteStyle", "PostCropVignetteHighlightContrast", "GrainAmount", "GrainSize", "GrainFrequency", "GrainSeed"}
UNSUPPORTED = {
    "Clarity2012": "local contrast (multi-scale); needs a spatial operator",
    "Texture": "fine-scale local contrast; needs a spatial operator",
    "Look": "creative profile (RGB table); table decoding not implemented",
    "PointColors": "Point Color (targeted colour ranges); not implemented",
    "Brightness": "PV2010 slider (legacy process version)", "Shadows": "PV2010 slider", "Contrast": "PV2010 slider", "Exposure": "PV2010 slider",
    "Clarity": "PV2010 slider", "FillLight": "PV2010 slider", "HighlightRecovery": "PV2010 slider",
    "ToneCurve": "PV2010 tone curve", "ToneCurveName": "PV2010 tone curve name",
    "CurveRefineSaturation": "tone-curve saturation refinement",
}
UNSUPPORTED_PREFIX = {"Local": "local adjustment (masks)", "Mask": "local adjustment (masks)", "Correction": "local adjustment (masks)",
                      "GradientBased": "graduated filter", "CircularGradientBased": "radial filter", "PaintBased": "brush adjustment",
                      "Table_": "embedded RGB table (creative profile)"}
NOT_A_LOOK_PREFIX = ("Sharpen", "Sharpness", "LuminanceSmoothing", "LuminanceNoise", "ColorNoise", "Lens", "Perspective", "Crop", "AutoLateralCA",
                     "Defringe", "ChromaticAberration", "VignetteAmount", "VignetteMidpoint", "Upright", "HasCrop", "orientation", "LensBlur",
                     "GrainSeed", "HDREditMode", "OverrideLookVignette", "DepthMapInfo", "Src", "Dst", "ShouldDelete", "IsSignal", "Filter",
                     "OrderIndex", "MinDisplay", "MinEdit", "Enable", "ToggleStyle", "Images", "CompressedSettings", "AllowFilters", "Stubbed", "ISODependent", "Title")
METADATA = {"Name", "Group", "UUID", "SupportsAmount", "SupportsAmount2", "SupportsColor", "SupportsMonochrome", "SupportsHighDynamicRange",
            "SupportsNormalDynamicRange", "SupportsSceneReferred", "SupportsOutputReferred", "CameraModelRestriction", "Copyright", "ContactInfo",
            "Version", "PresetType", "Cluster", "Description", "HasSettings", "AlreadyApplied", "RawFileName", "ShortName", "SortName", "Amount",
            "ProcessVersion", "CompatibleVersion", "WhiteBalance", "ToneCurveName2012", "CameraProfileDigest", "ShowInPresets", "ShowInQuickActions",
            "What", "Preset", "Parameters", "AutoWhiteVersion", "RequiresRGBTables", "AsShotTemperature", "AsShotTint", "ColorVariance"}
NEUTRAL = {"0", "+0", "0.0", "+0.00", "0.00", "-0", "", "False", "None", "false"}
# Defaults that are not zero in Lightroom
DEFAULTS = {"ParametricShadowSplit": "25", "ParametricMidtoneSplit": "50", "ParametricHighlightSplit": "75", "ColorGradeBlending": "50",
            "PostCropVignetteMidpoint": "50", "PostCropVignetteFeather": "50", "PostCropVignetteRoundness": "0", "PostCropVignetteStyle": "1",
            "GrainSize": "25", "GrainFrequency": "50", "CameraProfile": "Embedded", "CurveRefineSaturation": "100",
            "LocalCurveRefineSaturation": "100"}


def is_default(k, v):
    if isinstance(v, list):
        if all(isinstance(x, str) for x in v):
            if v in (["0, 0", "255, 255"],) or all(re.fullmatch(r"\s*-1(\.0+)?(,\s*-1(\.0+)?)*\s*", x or "") for x in v):
                return True
        return len(v) == 0
    if isinstance(v, dict):
        return not v
    sv = str(v).strip()
    return sv in NEUTRAL or DEFAULTS.get(k) == sv.lstrip("+")


def classify_key(k, v, process_version):
    if k in METADATA:
        return "metadata", None
    if k == "CameraProfile":
        return ("modelled", None) if str(v) in ("Embedded", "Adobe Standard", "Default Color") else ("unsupported", f"camera profile '{v}'")
    if k in MODELLED:
        return "modelled", None
    if k in APPROXIMATED:
        return "approximated", APPROXIMATED[k]
    if k in SPATIAL:
        return "spatial", "carried as Look spatial parameter (vignette/grain), not baked into the LUT"
    legacy = {"Brightness", "Shadows", "Contrast", "Exposure", "Clarity", "FillLight", "HighlightRecovery", "ToneCurve", "ToneCurveName"}
    if k in legacy and process_version.split(".")[0] in ("10", "11", "15"):
        # Lightroom writes PV2010 keys into PV2012+ presets but does not use them.
        return "not-a-look", "legacy PV2010 key, inactive under process version 2012+"
    if k in UNSUPPORTED:
        return "unsupported", UNSUPPORTED[k]
    for pfx, why in UNSUPPORTED_PREFIX.items():
        if k.startswith(pfx):
            return "unsupported", why
    if k.startswith(NOT_A_LOOK_PREFIX):
        return "not-a-look", "detail/geometry/UI setting; intentionally not applied"
    return "unsupported", "unrecognised key (no mapping defined)"


def classify(p):
    s = p.settings
    pv = str(s.get("ProcessVersion", ""))
    found = collections.defaultdict(dict)
    for k, v in s.items():
        if is_default(k, v):
            continue
        cls, why = classify_key(k, v, pv)
        if cls == "metadata":
            continue
        found[cls][k] = why
    if pv and pv.split(".")[0] not in ("10", "11", "15"):  # PV2010/2003 sliders are different semantics
        found["unsupported"]["ProcessVersion"] = f"process version {pv} (pre-2012)"
    status = "partial" if found.get("unsupported") else ("approximated" if found.get("approximated") else "converted")
    return {"source": p.source, "kind": p.kind, "name": p.name, "status": status,
            **{c: sorted(found[c]) for c in ("modelled", "approximated", "spatial", "unsupported", "not-a-look") if found.get(c)},
            "reasons": {k: why for c in ("approximated", "unsupported") for k, why in found.get(c, {}).items()}}


if __name__ == "__main__":
    root = Path(sys.argv[1])
    report, errors = [], []
    for p in lrsettings.walk(root):
        if p.error:
            errors.append({"source": p.source, "error": p.error}); continue
        report.append(classify(p))
    status = collections.Counter(r["status"] for r in report)
    unsup = collections.Counter(k for r in report for k in r.get("unsupported", []))
    approx = collections.Counter(k for r in report for k in r.get("approximated", []))
    json.dump({"presets": report, "parse_errors": errors}, open("conversion_report.json", "w"), indent=1)
    lines = [f"# Preset conversion classification", "", f"Files parsed: {len(report)} (+{len(errors)} parse errors, listed in conversion_report.json)", "",
             "| Status | Presets | Meaning |", "|---|---|---|",
             f"| converted | {status['converted']} | every non-default parameter modelled (or spatial / not-a-look) |",
             f"| approximated | {status['approximated']} | modelled, but uses at least one approximated (local-in-Lightroom) parameter |",
             f"| partial | {status['partial']} | at least one unsupported parameter; never marked converted |", "",
             "Unsupported parameters (presets affected):", ""] + [f"- `{k}`: {n}" for k, n in unsup.most_common(30)] + ["", "Approximated parameters (presets affected):", ""] + [f"- `{k}`: {n}" for k, n in approx.most_common()]
    open("conversion_summary.md", "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))
