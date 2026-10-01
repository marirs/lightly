"""Build the Lightroom export kit for the provisional shortlist.

Usage: python make_kit.py [preset_root] -> experiments/presets/lr_kit/kit/ (git-ignored; zip it to hand over)

kit/
  README.md                       step-by-step Lightroom Classic instructions (generated, see README_TEMPLATE)
  identity/hald_64_srgb16.tif     identity HALD CLUT, level 8 (64^3 colours, 512x512), 16-bit, sRGB ICC embedded
  photos/                         the 22 test photos (copied from experiments/lut3d/photos)
  presets/original/<look_id>.<ext> the shortlisted presets exactly as found in the collection
  presets/full/<look_id>__full.xmp      generated COMPLETE preset (every look-relevant key explicit)
  presets/global/<look_id>__global.xmp  generated: complete, with adaptive-tone, local and spatial sliders neutral
  shortlist.json, manifest.json   look ids, sources, sha256 of every kit file
Export targets the user fills (see README):
  exports/hald/<look_id>__global.tif                    global-only variant on the identity HALD
  exports/photos/<look_id>__global__<photo_stem>.jpg    global-only variant on each input photo
  exports/photos/<look_id>__full__<photo_stem>.jpg      full Look on each input photo
  exports/photos/none__<photo_stem>.jpg                 no preset (neutral baseline)
"""
from __future__ import annotations

import hashlib, json, re, shutil, sys, uuid
from pathlib import Path
from xml.sax.saxutils import quoteattr
import numpy as np
import tifffile
from PIL import ImageCms
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lrsettings  # noqa: E402

HERE = Path(__file__).parent
PRESETS = HERE.parent
ROOT = Path.home() / "Downloads/Presets - for lightly"  # overridden by the first non-flag CLI argument
KIT = HERE / "kit"
HALD_LEVEL = 8  # cube size 64, image 512x512

# Zeroed for the "global" HALD variant: these act spatially or adaptively, so on a synthetic HALD image they
# would not represent what they do to photographs. Their effect is measured separately on the photo exports.
# Neutralised in the GLOBAL-ONLY variant (Codex finding 7): everything Lightroom applies adaptively or spatially,
# including the adaptive tone sliders, so the HALD captures only pixel-independent colour/tone. These operators
# are re-added (as Lightly's own implementations) in the full-recipe validation.
LOCAL_KEYS = {"Highlights2012": "0", "Shadows2012": "0", "Whites2012": "0", "Blacks2012": "0",
              "Clarity2012": "0", "Texture": "0", "Dehaze": "0", "PostCropVignetteAmount": "0", "GrainAmount": "0",
              "Sharpness": "0", "LuminanceSmoothing": "0", "ColorNoiseReduction": "0", "VignetteAmount": "0"}


_BANDS = ("Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta")
_LINEAR = ["0, 0", "255, 255"]
# Lightroom's neutral value for every look-relevant develop key (rendered/JPEG input). Kit presets set ALL of
# these explicitly, so applying one can never inherit a previous Look's values (Codex finding 5).
DEVELOP_DEFAULTS = {
    **{k: "0" for k in ("IncrementalTemperature", "IncrementalTint", "Exposure2012", "Contrast2012", "Highlights2012",
                        "Shadows2012", "Whites2012", "Blacks2012", "Texture", "Clarity2012", "Dehaze", "Vibrance", "Saturation",
                        "ParametricShadows", "ParametricDarks", "ParametricLights", "ParametricHighlights",
                        "RedHue", "RedSaturation", "GreenHue", "GreenSaturation", "BlueHue", "BlueSaturation", "ShadowTint",
                        "SplitToningShadowHue", "SplitToningShadowSaturation", "SplitToningHighlightHue",
                        "SplitToningHighlightSaturation", "SplitToningBalance",
                        "ColorGradeShadowHue", "ColorGradeShadowSat", "ColorGradeShadowLum", "ColorGradeMidtoneHue",
                        "ColorGradeMidtoneSat", "ColorGradeMidtoneLum", "ColorGradeHighlightHue", "ColorGradeHighlightSat",
                        "ColorGradeHighlightLum", "ColorGradeGlobalHue", "ColorGradeGlobalSat", "ColorGradeGlobalLum",
                        "ColorGradeBalance", "PostCropVignetteAmount", "PostCropVignetteHighlightContrast", "GrainAmount",
                        "Sharpness", "LuminanceSmoothing", "ColorNoiseReduction", "VignetteAmount")},
    **{f"{a}Adjustment{b}": "0" for a in ("Hue", "Saturation", "Luminance") for b in _BANDS},
    **{f"GrayMixer{b}": "0" for b in _BANDS},
    "ParametricShadowSplit": "25", "ParametricMidtoneSplit": "50", "ParametricHighlightSplit": "75",
    "ColorGradeBlending": "50", "ConvertToGrayscale": "False", "PostCropVignetteMidpoint": "50",
    "PostCropVignetteFeather": "50", "PostCropVignetteRoundness": "0", "PostCropVignetteStyle": "1",
    "GrainSize": "25", "GrainFrequency": "50", "ToneCurveName2012": "Custom",
    "ToneCurvePV2012": _LINEAR, "ToneCurvePV2012Red": _LINEAR, "ToneCurvePV2012Green": _LINEAR, "ToneCurvePV2012Blue": _LINEAR,
}


GRAIN_KEYS = ("GrainAmount", "GrainSize", "GrainFrequency", "GrainSeed")


def needs_nograin(settings: dict) -> bool:
    """Looks with grain need a matching grain-free render: the full Look with ONLY grain disabled."""
    try:
        return float(str(settings.get("GrainAmount", "0")).replace("+", "")) != 0
    except ValueError:
        return False


def kit_preset_settings(settings: dict, variant: str) -> dict:
    """Complete preset for the kit: Lightroom neutral defaults, overlaid with the preset's own values, and for the
    'global' variant with the local/spatial keys forced neutral. Non-develop keys are passed through."""
    out = dict(DEVELOP_DEFAULTS)
    out.update({k: v for k, v in settings.items() if isinstance(v, (str, list))})
    if variant == "global":
        out.update({k: DEVELOP_DEFAULTS.get(k, "0") for k in LOCAL_KEYS})
    elif variant == "nograin":
        # Same as full except grain: the like-for-like grain-free reference for grain measurement.
        out.update({k: DEVELOP_DEFAULTS[k] for k in GRAIN_KEYS if k in DEVELOP_DEFAULTS})
    elif variant != "full":
        raise ValueError(variant)
    return out


# Small pilot to check the Lightroom workflow end to end before the full run (26 exports):
#  - s1-vibes: a vendor original that omits many keys (checks the complete-preset XMPs import and apply)
#  - c4-teals: grain + vignette (checks spatial operators and grain evidence)
#  - Display P3 and Adobe RGB photos (colour management), a deep-skin portrait, and the smooth fixture card.
PILOT = {"looks": ["natural.1.s1-vibes", "film.2.c4-teals"],
         "photos": ["landscape_01", "wellexposed_02", "portrait_deep_01", "fixture_smooth"]}

PILOT_BANNER = """> **PILOT KIT.** This is a small subset: 2 Looks and 4 inputs, 26 exports (4 neutral; per Look 1 identity + 4 global + 4 full; plus 4 no-grain for the grain Look), about 15 minutes. Its purpose is to check that:
> - Lightroom imports and applies the generated presets;
> - the export settings and file naming are right;
> - the neutral baseline passes;
> - ingest runs end to end.
>
> Run it first and report anything that differs from these instructions, especially any preset that fails to import. Then run the full kit.

"""


class KitHasExportsError(RuntimeError):
    """Raised instead of touching a kit that already holds Lightroom exports or ingest results."""


# Only these folders are produced by the generator; anything else in a kit (exports/, results/) is user data.
GENERATED_DIRS = ("identity", "photos", "presets")


def prepare_kit_dir(kit: Path, new_version: bool = False) -> Path:
    """Return the directory to generate into. Never deletes exports or results (Codex finding 3).

    - kit without exports/results: generated folders are rebuilt in place.
    - kit with exports/results: refuse, unless new_version=True, which returns a fresh kit-vN sibling.
    """
    has_user_data = any(p.is_file() for d in ("exports", "results") for p in (kit / d).rglob("*")) if kit.exists() else False
    if has_user_data:
        if not new_version:
            raise KitHasExportsError(f"{kit} contains Lightroom exports or results; rerun with --new-version to write a fresh kit")
        n = 2
        while (kit.parent / f"{kit.name}-v{n}").exists():
            n += 1
        kit = kit.parent / f"{kit.name}-v{n}"
    kit.mkdir(parents=True, exist_ok=True)
    for d in GENERATED_DIRS:
        if (kit / d).exists():
            shutil.rmtree(kit / d)
    return kit


def look_id(rec):
    slug = re.sub(r"[^a-z0-9]+", "-", rec["name"].lower()).strip("-")[:32]
    return f"{rec['category']}.{rec['stop']}.{slug}"


def hald_identity(level=HALD_LEVEL) -> np.ndarray:
    """Standard HALD CLUT: cube N = level^2, image side level^3; pixel index = r + g*N + b*N^2 (row-major)."""
    n = level * level
    side = level ** 3
    idx = np.arange(side * side)
    r, g, b = idx % n, (idx // n) % n, idx // (n * n)
    rgb = np.stack([r, g, b], -1).astype(np.float64) / (n - 1)
    return np.round(rgb * 65535).astype(np.uint16).reshape(side, side, 3)


def write_hald(path: Path):
    icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    tifffile.imwrite(path, hald_identity(), photometric="rgb", extratags=[(34675, "B", len(icc), icc, True)])


def write_fixtures(photos_dir: Path, only=None):
    """Controlled cards added to the kit's inputs (re-review issue 1): grain can only be measured where the image
    itself is smooth, and real photos may not have enough smooth area.
      fixture_smooth   flat patches (greys + muted colours) with gentle gradients -> grain evidence
      fixture_textured fine high-frequency texture -> checks that image detail is not mistaken for grain
    """
    photos_dir.mkdir(parents=True, exist_ok=True)
    from PIL import Image as _Image
    h, w = 800, 1200
    y, x = np.mgrid[0:h, 0:w] / np.array([h, w])[:, None, None]
    cards = {}
    patches = [(0.18, 0.18, 0.18), (0.35, 0.35, 0.35), (0.5, 0.5, 0.5), (0.65, 0.65, 0.65), (0.8, 0.8, 0.8),
               (0.55, 0.42, 0.35), (0.35, 0.45, 0.55), (0.45, 0.55, 0.40)]
    smooth = np.zeros((h, w, 3))
    for i, c in enumerate(patches):
        r0, c0 = (i // 4) * (h // 2), (i % 4) * (w // 4)
        smooth[r0:r0 + h // 2, c0:c0 + w // 4] = c
    smooth = smooth * (0.92 + 0.08 * x[..., None])  # gentle gradient so it is not perfectly flat
    cards["fixture_smooth"] = smooth
    # Strong detail at several scales everywhere: no smooth area, so it can never supply grain evidence.
    tex = 0.5 + 0.3 * np.sin(2 * np.pi * x * 160) * np.sin(2 * np.pi * y * 110) + 0.15 * np.sin(2 * np.pi * (x * 61 + y * 43))
    cards["fixture_textured"] = np.stack([tex, tex * 0.95 + 0.03, tex * 0.9 + 0.05], -1)
    for name, img in cards.items():
        if only is None or name in only:
            _Image.fromarray(np.clip(img * 255 + 0.5, 0, 255).astype(np.uint8)).save(photos_dir / f"{name}.jpg", quality=100, subsampling=0)


def write_inputs(kit: Path):
    """Record the kit's complete input set (photo stems + sha256, HALD sha256). Ingest validates against THIS
    list, not against whatever files happen to remain in the folder (Codex finding 6)."""
    photos = {p.stem: sha(p) for p in sorted((kit / "photos").glob("*.jpg"))}
    hald = kit / "identity/hald_64_srgb16.tif"
    # Preset files are evidence too: what Lightroom rendered must be exactly what ingest models (re-review issue 3).
    presets = {str(p.relative_to(kit)): sha(p) for v in ("full", "global", "nograin") for p in sorted((kit / "presets" / v).glob("*.xmp"))}
    json.dump({"photos": photos, "hald_sha256": sha(hald) if hald.exists() else None, "presets": presets},
              open(kit / "inputs.json", "w"), indent=1)


def settings_to_xmp(settings: dict, name: str) -> str:
    """Write a Lightroom develop preset XMP from parsed crs settings (scalars as attributes, curves as rdf:Seq)."""
    attrs, seqs = [], []
    for k, v in sorted(settings.items()):
        if k in ("Name", "Group", "UUID", "PresetType", "Cluster", "SupportsAmount", "SupportsColor", "SupportsMonochrome",
                 "SupportsHighDynamicRange", "SupportsNormalDynamicRange", "SupportsSceneReferred", "SupportsOutputReferred"):
            continue
        if isinstance(v, list) and all(isinstance(x, str) for x in v):
            items = "".join(f"<rdf:li>{x}</rdf:li>" for x in v)
            seqs.append(f"   <crs:{k}><rdf:Seq>{items}</rdf:Seq></crs:{k}>")
        elif isinstance(v, (str, int, float)):
            attrs.append(f"   crs:{k}={quoteattr(str(v))}")
        # nested structs (masks, Look tables) are excluded by eligibility; nothing else to write
    head = "\n".join([f'   crs:PresetType="Normal"', f'   crs:UUID="{uuid.uuid4().hex.upper()}"', '   crs:SupportsAmount="False"',
                      '   crs:SupportsColor="True"', '   crs:SupportsMonochrome="True"'] + attrs)
    return f"""<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
{head}>
   <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">{name}</rdf:li></rdf:Alt></crs:Name>
   <crs:Group><rdf:Alt><rdf:li xml:lang="x-default">Lightly export kit</rdf:li></rdf:Alt></crs:Group>
{chr(10).join(seqs)}
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
"""


def sha(p: Path):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main(new_version: bool = False, pilot: bool = False) -> Path:
    global KIT
    if pilot and KIT.name == "kit":
        KIT = KIT.parent / "kit-pilot"
    KIT = prepare_kit_dir(KIT, new_version)
    shortlist = json.load(open(PRESETS / "shortlist.json"))
    looks = [rec for cat in shortlist.values() for rec in cat["looks"]]
    if pilot:
        looks = [rec for rec in looks if look_id(rec) in PILOT["looks"]]
    for d in ("identity", "photos", "presets/original", "presets/full", "presets/global", "presets/nograin", "exports/hald", "exports/photos"):
        (KIT / d).mkdir(parents=True, exist_ok=True)
    write_hald(KIT / "identity/hald_64_srgb16.tif")
    for jpg in sorted((PRESETS.parent / "lut3d/photos").glob("*.jpg")):
        if not pilot or jpg.stem in PILOT["photos"]:
            shutil.copy2(jpg, KIT / "photos" / jpg.name)
    write_fixtures(KIT / "photos", only=[p for p in PILOT["photos"] if p.startswith("fixture_")] if pilot else None)
    by_source = {}
    for p in lrsettings.walk(ROOT):
        by_source[p.source] = p
    entries = []
    for rec in looks:
        lid = look_id(rec)
        p = by_source[rec["source"]]
        src_name = rec["source"].split(" -> ")[-1]
        ext = Path(src_name).suffix.lower()
        orig_path = KIT / "presets/original" / f"{lid}{ext}"
        if " -> " in rec["source"]:
            import zipfile
            zpath, member = rec["source"].split(" -> ")
            orig_path.write_bytes(zipfile.ZipFile(ROOT / zpath).read(member))
        else:
            shutil.copy2(ROOT / rec["source"], orig_path)
        identity_keys = {"Name", "UUID", "Group", "PresetType", "Cluster", "SupportsAmount", "SupportsColor", "SupportsMonochrome"}
        variants = ("full", "global") + (("nograin",) if needs_nograin(p.settings) else ())
        for variant in variants:
            g = kit_preset_settings(p.settings, variant)
            path = KIT / "presets" / variant / f"{lid}__{variant}.xmp"
            path.write_text(settings_to_xmp(g, f"{lid} [{variant}]"))
            # Round-trip check: the generated XMP must parse back to the same develop values.
            back = lrsettings.parse_xmp_text(path.read_text())
            mism = [k for k, v in g.items() if k not in identity_keys and not k.startswith("Supports") and back.get(k) != v]
            assert not mism, (lid, variant, mism[:5])
        entries.append({"look_id": lid, **{k: rec[k] for k in ("category", "stop", "name", "source")},
                        "original_file": str(orig_path.relative_to(KIT)), "full_xmp": f"presets/full/{lid}__full.xmp",
                        "global_xmp": f"presets/global/{lid}__global.xmp",
                        **({"nograin_xmp": f"presets/nograin/{lid}__nograin.xmp"} if needs_nograin(p.settings) else {}),
                        "zeroed_for_global": sorted(k for k in LOCAL_KEYS if k in p.settings and str(p.settings[k]).strip("+") not in ("0", "0.00"))})
    json.dump(entries, open(KIT / "shortlist.json", "w"), indent=1)
    write_inputs(KIT)
    n_inputs = len(list((KIT / "photos").glob("*.jpg")))
    (KIT / "README.md").write_text((PILOT_BANNER if pilot else "") + (HERE / "README_TEMPLATE.md").read_text().replace("{{N}}", str(n_inputs)).replace("{{LOOK_TABLE}}", "\n".join(
        f"| `{e['look_id']}` | {e['category']} | {e['stop']} | {e['name']} | `{e['original_file']}` |" for e in entries)))
    manifest = {str(f.relative_to(KIT)): sha(f) for f in sorted(KIT.rglob("*")) if f.is_file()}
    json.dump(manifest, open(KIT / "manifest.json", "w"), indent=1)
    print(f"kit: {len(entries)} looks, {len(manifest)} files -> {KIT}")
    return KIT


if __name__ == "__main__":
    positional = [a for a in sys.argv[1:] if not a.startswith("--")]
    if positional:
        ROOT = Path(positional[0])
    main(new_version="--new-version" in sys.argv, pilot="--pilot" in sys.argv)
