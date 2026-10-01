"""Classify every non-default develop parameter of every preset.

Statuses are kept separate: parsed / parameter coverage / validation. Nothing is called "converted".
`modelled` is derived from the keys the renderer actually reads (renderer_read_keys), not a hand list.

Usage: python classify.py "<preset root>" -> conversion_report.json, conversion_summary.md (printed)
"""
import collections, json, re, sys
from pathlib import Path
import lrsettings

class _RecordingDict(dict):
    """dict that records every key the renderer reads, so 'modelled' means 'actually consumed'."""

    def __init__(self, *a, **k):
        super().__init__(*a, **k); self.read = set()

    def get(self, key, default=None):
        self.read.add(key); return super().get(key, default)

    def __getitem__(self, key):
        self.read.add(key); return super().__getitem__(key)


def renderer_read_keys():
    """Keys lr_model.Preset reads for a RENDERED (JPEG/HEIC) input. Derived at runtime, not hand-listed."""
    import lr_model
    probe = _RecordingDict()
    lr_model.Preset(probe, wb_mode="rendered")
    return probe.read


# Read by the renderer but deliberately not applied to rendered photos (raw-only in Lightroom).
IGNORED_ON_RENDERED = {"Temperature", "Tint"}
MODELLED = renderer_read_keys() - IGNORED_ON_RENDERED

APPROXIMATED = {
    "Highlights2012": "local tone mapping in Lightroom; modelled as a global curve",
    "Shadows2012": "local tone mapping in Lightroom; modelled as a global curve",
    "Whites2012": "adaptive in Lightroom; modelled as a global curve",
    "Blacks2012": "adaptive in Lightroom; modelled as a global curve",
    "Dehaze": "spatially varying in Lightroom; modelled as a global veil removal + curve",
    "Temperature": "not applied to rendered photos: ASSUMPTION (unverified) that Lightroom ignores absolute Kelvin on JPEG/HEIC",
    "Tint": "not applied to rendered photos: ASSUMPTION (unverified) that Lightroom ignores absolute tint on JPEG/HEIC",
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
        # Only 'Embedded' (the default for JPEG/HEIC) is neutral; the renderer never reads CameraProfile.
        return "not-implemented", f"camera profile '{v}' is not rendered"
    # Approximated wins over modelled: the renderer reads these keys, but Lightroom applies them locally.
    if k in APPROXIMATED:
        return "approximated", APPROXIMATED[k]
    if k in MODELLED:
        return "modelled", None
    if k in SPATIAL:
        return "not-implemented", "spatial Look parameter (vignette/grain): parsed and kept, renderer not implemented yet"
    if k in ("Clarity2012", "Texture"):
        return "experimental", "local contrast: experimental spatial operator (lr_model.apply_local_contrast), not validated"
    legacy = {"Brightness", "Shadows", "Contrast", "Exposure", "Clarity", "FillLight", "HighlightRecovery", "ToneCurve", "ToneCurveName"}
    if k in legacy and process_version.split(".")[0] in ("10", "11", "15"):
        # Lightroom writes PV2010 keys into PV2012+ presets but does not use them.
        return "not-a-look", "legacy PV2010 key, inactive under process version 2012+"
    if k in UNSUPPORTED:
        return "not-implemented", UNSUPPORTED[k]
    for pfx, why in UNSUPPORTED_PREFIX.items():
        if k.startswith(pfx):
            return "not-implemented", why
    if k.startswith(NOT_A_LOOK_PREFIX):
        return "not-a-look", "detail/geometry/UI setting; intentionally not applied"
    return "not-implemented", "unrecognised key (no mapping defined)"


def classify(p, validation=None):
    """Three independent statuses (Codex M1 finding 1):
      parsed      - always true here (parse failures are listed separately)
      coverage    - 'complete' only if every non-default parameter is modelled/approximated/not-a-look;
                    anything experimental or not-implemented makes it 'incomplete'
      validation  - 'none' unless a reference comparison exists; candidate DNG pairs are reported as
                    'candidate-reference' with their dE, never as validated
    """
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
    if pv and pv.split(".")[0] not in ("10", "11", "15"):
        found["not-implemented"]["ProcessVersion"] = f"process version {pv} (pre-2012)"
    coverage = "incomplete" if (found.get("not-implemented") or found.get("experimental")) else "complete"
    return {"source": p.source, "kind": p.kind, "name": p.name, "parsed": True, "coverage": coverage,
            "uses_approximation": bool(found.get("approximated")), "validation": validation or {"status": "none"},
            **{c: sorted(found[c]) for c in ("modelled", "approximated", "experimental", "not-implemented", "not-a-look") if found.get(c)},
            "reasons": {k: why for c in ("approximated", "experimental", "not-implemented") for k, why in found.get(c, {}).items()}}


if __name__ == "__main__":
    root = Path(sys.argv[1])
    report, errors = [], []
    for p in lrsettings.walk(root):
        if p.error:
            errors.append({"source": p.source, "error": p.error}); continue
        report.append(classify(p))
    cov = collections.Counter((r["coverage"], r["uses_approximation"]) for r in report)
    blockers = collections.Counter(k for r in report for k in r.get("not-implemented", []) + r.get("experimental", []))
    approx = collections.Counter(k for r in report for k in r.get("approximated", []))
    only_local = sum(1 for r in report if r["coverage"] == "incomplete" and set(r.get("not-implemented", [])) == set() and set(r.get("experimental", [])) <= {"Clarity2012", "Texture"})
    json.dump({"presets": report, "parse_errors": errors, "renderer_read_keys": sorted(MODELLED)}, open("conversion_report.json", "w"), indent=1)
    lines = ["# Preset parameter coverage", "",
             f"Parsed: {len(report)} presets (+{len(errors)} parse errors, listed in conversion_report.json). Validated against Lightroom: 0.", "",
             "| Coverage | Uses approximation | Presets |", "|---|---|---|",
             f"| complete | no | {cov[('complete', False)]} |", f"| complete | yes | {cov[('complete', True)]} |",
             f"| incomplete | - | {cov[('incomplete', False)] + cov[('incomplete', True)]} |", "",
             f"'complete' = every non-default parameter is read by the renderer (modelled or approximated) or is not a look parameter. It is NOT a fidelity claim.",
             f"Incomplete only because of experimental Clarity/Texture: {only_local}", "",
             "Not-implemented / experimental parameters (presets affected):", ""] + [f"- `{k}`: {n}" for k, n in blockers.most_common(30)] + \
            ["", "Approximated parameters (presets affected):", ""] + [f"- `{k}`: {n}" for k, n in approx.most_common()]
    open("conversion_summary.md", "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))
