"""convert: settings -> recipe and a complete coverage record (nothing silently dropped). No private files needed."""
import struct
import zlib

import pytest

import classify
import convert

BASE = {"ProcessVersion": "11.0", "Exposure2012": "+0.40", "Contrast2012": "+20", "Highlights2012": "-30",
        "Clarity2012": "+15", "GrainAmount": "20", "PostCropVignetteAmount": "-25", "Name": "Test", "UUID": "X",
        "SupportsAmount": "True", "Version": "15.4"}


def run(settings, iso_keys=None, preset_id="look-test"):
    recipe, operators, malformed = convert.build_recipe(settings, preset_id)
    return recipe, operators, convert.coverage(settings, operators, malformed, iso_keys)


def codes(cov, kind):
    return {entry["code"]: entry["keys"] for entry in cov[kind]}


def test_operators_follow_the_contract_order_and_recipe_sections():
    recipe, operators, _ = run(BASE)
    assert operators == ["exposure", "toneSliders", "clarity", "vignette", "grain"]
    assert set(recipe) == {"global", "spatial", "finishing"}
    assert recipe["global"]["exposure"] == {"ev": 0.4}
    assert recipe["finishing"]["vignette"]["style"] == 1 and recipe["finishing"]["grain"]["size"] == 25


def test_every_non_default_setting_is_accounted_for():
    settings = {**BASE, "Temperature": "5600", "Tint": "+10", "CameraProfile": "Adobe Standard", "LensProfileEnable": "1",
                "VignetteAmount": "+13", "CurveRefineSaturation": "72", "SomethingNew": "3", "ToneCurveName": "Custom",
                "ParametricShadowSplit": "30"}  # split without parametric sliders: no pixel effect
    _, operators, cov = run(settings)
    consumed = {k for op in operators for k in convert.OPERATOR_KEYS[op]}
    recorded = {k for kind in cov for entry in cov[kind] for k in entry["keys"]}
    for key, value in settings.items():
        if classify.is_default(key, value) or key in classify.METADATA or key in convert.EXTRA_METADATA:
            continue
        no_effect = key == "ParametricShadowSplit"
        assert key in consumed or key in recorded or no_effect, key
    assert codes(cov, "unsupported") == {"lens-vignetting": ["VignetteAmount"], "curve-refine-saturation": ["CurveRefineSaturation"],
                                         "unrecognised": ["SomethingNew"]}
    assert codes(cov, "notApplied")["absolute-white-balance"] == ["Temperature", "Tint"]
    assert {"code": "absolute-white-balance", "keys": ["Temperature", "Tint"], "assumption": True} in cov["notApplied"]
    assert codes(cov, "notApplied")["legacy-pv2010-inactive"] == ["ToneCurveName"]


def test_masks_are_unsupported_and_their_nested_keys_are_not_listed_separately():
    settings = {**BASE, "MaskGroupBasedCorrections": [{"What": "Correction"}], "What": "Correction", "CorrectionAmount": "1",
                "LocalExposure2012": "0.12", "MaskName": "Brush 1", "Dabs": ["d 0.1"]}
    _, _, cov = run(settings)
    assert codes(cov, "unsupported") == {"local-adjustments": ["MaskGroupBasedCorrections"]}
    assert convert.completeness(cov) == "incomplete"


def test_profiles_creative_stub_unsupported_raw_base_not_applied():
    _, _, cov = run({**BASE, "Look": {"Name": "Vintage 01", "Stubbed": "true"}, "Amount": "1", "Stubbed": "true"})
    assert codes(cov, "unsupported") == {"creative-profile": ["Look:Vintage 01"]}
    _, _, cov = run({**BASE, "Look": {"Name": "Adobe Color", "Stubbed": "true"}, "Amount": "1"})
    assert codes(cov, "notApplied") == {"raw-base-profile": ["Look:Adobe Color"]}
    assert cov["unsupported"] == []
    _, _, cov = run({**BASE, "CameraProfile": "Agfa Vista 800 - C"})
    assert codes(cov, "unsupported") == {"camera-profile": ["CameraProfile"]}
    _, _, cov = run({**BASE, "Look": {"Name": ""}})
    assert cov["unsupported"] == [] and "raw-base-profile" not in codes(cov, "notApplied")


def test_process_versions():
    _, _, cov = run({**BASE, "ProcessVersion": "6.7"})
    assert "process-version-2012" in codes(cov, "approximated")
    _, _, cov = run({**BASE, "ProcessVersion": "5.7", "FillLight": "20"})
    assert codes(cov, "unsupported") == {"process-version-2010": ["FillLight", "ProcessVersion"]}
    _, _, cov = run({**BASE, "ProcessVersion": "15.4", "ToneCurve": ["0, 0", "64, 56", "255, 255"]})
    assert codes(cov, "notApplied")["legacy-pv2010-inactive"] == ["ToneCurve"]


def test_iso_adaptive_presets_record_the_varying_settings():
    xmp = ('<crs:ISODependent><rdf:Seq><rdf:li crs:ISO="100" crs:Shadows2012="+18" crs:Sharpness="61"/>'
           '<rdf:li crs:ISO="6400" crs:Shadows2012="+13" crs:Sharpness="33"/></rdf:Seq></crs:ISODependent>')
    keys = convert.iso_dependent_keys(xmp)
    assert keys == ["Shadows2012", "Sharpness"]
    _, _, cov = run({**BASE, "ISODependent": ["", ""]}, keys)
    assert codes(cov, "approximated")["iso-adaptive"] == ["ISODependent:Shadows2012", "ISODependent:Sharpness"]


def _encode_adobe_table(payload: bytes) -> str:
    alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#"
    raw = struct.pack("<I", len(payload)) + zlib.compress(payload)
    out = []
    for start in range(0, len(raw), 4):
        chunk = raw[start:start + 4]
        value = int.from_bytes(chunk.ljust(4, b"\0"), "little")
        digits = [(value // 85 ** i) % 85 for i in range(5)]
        out.append("".join(alphabet[d] for d in digits[:len(chunk) + 1]))
    return "".join(out)


@pytest.mark.parametrize("denoise,code", [("False", "enhance-filter-off"), ("True", "enhance-filter")])
def test_enhance_filter_is_decoded_not_guessed(denoise, code):
    payload = f'<x:xmpmeta><rdf:Description crs:Details="False" crs:SuperResolution="1/1" crs:Denoise="{denoise}"/></x:xmpmeta>'.encode()
    table = _encode_adobe_table(payload)
    assert convert.decode_adobe_table(table) == payload
    _, _, cov = run({**BASE, "FilterList": {"Filters": []}, "Table_ABC": table, "CompressedSettings": "ABC"})
    kind = "notApplied" if code == "enhance-filter-off" else "unsupported"
    assert code in codes(cov, kind)


def test_malformed_curve_is_unsupported_not_dropped():
    recipe, _, cov = run({**BASE, "ToneCurvePV2012Red": ["0, 0", "garbage"]})
    assert "toneCurve" not in recipe["global"]
    assert codes(cov, "unsupported") == {"malformed-tone-curve": ["ToneCurvePV2012Red"]}


def test_completeness_classes_are_separate_from_validation():
    _, _, cov = run({"ProcessVersion": "11.0", "Exposure2012": "+0.4", "ToneCurvePV2012": ["0, 0", "128, 140", "255, 255"]})
    assert convert.completeness(cov) == "complete"
    _, _, cov = run(BASE)
    assert convert.completeness(cov) == "approximate"


def test_grain_seed_comes_from_the_preset_or_its_id():
    recipe, _, _ = run({**BASE, "GrainSeed": "3774781898"})
    assert recipe["finishing"]["grain"]["seed"] == 3774781898
    a, _, _ = run(BASE, preset_id="look-a")
    b, _, _ = run(BASE, preset_id="look-b")
    assert a["finishing"]["grain"]["seed"] != b["finishing"]["grain"]["seed"]
    assert a == run(BASE, preset_id="look-a")[0]


XMP = """<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
   crs:ProcessVersion="11.0" crs:Exposure2012="+0.40" crs:VignetteAmount="+13" crs:Temperature="5600">
   <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>128, 140</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
   <crs:MaskGroupBasedCorrections>
    <rdf:Seq><rdf:li><rdf:Description crs:What="Correction" crs:LocalExposure2012="0.5" crs:Exposure2012="+3">
     <crs:CorrectionMasks><rdf:Seq><rdf:li><rdf:Description crs:What="Mask/Paint" crs:MaskValue="1"/></rdf:li></rdf:Seq></crs:CorrectionMasks>
    </rdf:Description></rdf:li></rdf:Seq>
   </crs:MaskGroupBasedCorrections>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
"""


def test_unconverted_settings_are_kept_verbatim():
    import lrsettings
    settings = lrsettings.parse_xmp_text(XMP)
    _, operators, cov = run(settings)
    verbatim = convert.unconverted_verbatim(XMP, settings, cov)
    assert verbatim["VignetteAmount"] == {"attribute": "+13"}
    assert verbatim["Temperature"] == {"attribute": "5600"}
    element = verbatim["MaskGroupBasedCorrections"]["element"]
    assert element.startswith("<crs:MaskGroupBasedCorrections>") and element.endswith("</crs:MaskGroupBasedCorrections>")
    assert element in XMP


def test_a_nested_value_overriding_a_consumed_setting_is_detected():
    import lrsettings
    settings = lrsettings.parse_xmp_text(XMP)  # the mask's crs:Exposure2012="+3" is merged over the preset's +0.40
    _, operators, _ = run(settings)
    assert convert.check_no_nested_override(settings, XMP, operators) == ["Exposure2012"]
