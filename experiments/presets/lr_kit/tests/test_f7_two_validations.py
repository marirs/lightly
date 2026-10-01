"""Codex finding 7: separate global-transform validation from full-recipe validation, each with matching exports.

- Global: the HALD of the GLOBAL-ONLY preset gives the LUT; it is compared with Lightroom photo exports of the
  same global-only preset (`<look>__global__<photo>.jpg`).
- Full recipe: Lightly's complete recipe (global LUT + separated operators: approximated Highlights/Shadows/
  Whites/Blacks/Dehaze, experimental Clarity/Texture) is compared with exports of the FULL preset
  (`<look>__full__<photo>.jpg`). Operators Lightly does not implement block 'validated' and are listed.
"""
import json
import numpy as np, tifffile
from PIL import Image
import ingest_kit, make_kit, ia3dlut as ia
import torch, lr_model as lm


def test_global_variant_neutralises_adaptive_tone_and_local_ops():
    s = {"ProcessVersion": "11.0", "Highlights2012": "-40", "Shadows2012": "+30", "Whites2012": "+10", "Blacks2012": "-5",
         "Clarity2012": "+20", "Texture": "+10", "Dehaze": "+5", "GrainAmount": "20", "PostCropVignetteAmount": "-15",
         "Contrast2012": "+25", "Exposure2012": "+0.30"}
    g = make_kit.kit_preset_settings(s, "global")
    for k in ("Highlights2012", "Shadows2012", "Whites2012", "Blacks2012", "Clarity2012", "Texture", "Dehaze", "GrainAmount", "PostCropVignetteAmount"):
        assert g[k] in ("0", "+0"), k
    assert g["Contrast2012"] == "+25" and g["Exposure2012"] == "+0.30"


def _lut():
    g = np.moveaxis(ia.identity_lut(), 0, -1)
    return np.moveaxis(np.clip(g ** 0.9 * np.array([1.05, 1.0, 0.92]) + 0.02, 0, 1), -1, 0).astype(np.float32)


def _kit(tmp, full_settings, simulate_full, fixtures=False, textured_only=False, nograin_exports=True):
    kit = tmp / "kit"
    for d in ("photos", "exports/hald", "exports/photos", "presets/full"):
        (kit / d).mkdir(parents=True)
    L = _lut()
    hald = make_kit.hald_identity().astype(np.float32) / 65535; side = hald.shape[0]
    out = ia.apply_lut_reference(L, hald.reshape(-1, 1, 3), 1.0).reshape(side, side, 3)
    tifffile.imwrite(kit / "exports/hald/t.1.x__global.tif", np.round(np.clip(out, 0, 1) * 65535).astype(np.uint16))
    stems = [] if textured_only else ["portrait_deep_01", "sunset_02"]
    if fixtures or textured_only:
        make_kit.write_fixtures(kit / "photos", only=None if fixtures else ["fixture_textured"])
    for stem in stems:
        src = Image.open(make_kit.PRESETS.parent / f"lut3d/golden/{stem}/source.png").convert("RGB").resize((600, 400))
        src.save(kit / "photos" / f"{stem}.jpg", quality=100, subsampling=0)
    for stem in [p.stem for p in sorted((kit / "photos").glob("*.jpg"))]:
        s = np.asarray(Image.open(kit / "photos" / f"{stem}.jpg")).astype(np.float32) / 255
        glob_img = ia.apply_lut_reference(L, s, 1.0)
        Image.fromarray(ia.to_uint8(glob_img)).save(kit / f"exports/photos/t.1.x__global__{stem}.jpg", quality=100, subsampling=0)
        Image.fromarray(ia.to_uint8(simulate_full(s, glob_img))).save(kit / f"exports/photos/t.1.x__full__{stem}.jpg", quality=100, subsampling=0)
        if nograin_exports and make_kit.needs_nograin(full_settings):
            # Lightroom's full Look with only grain disabled. Simulators that add grain take grain=False.
            import inspect
            ng = simulate_full(s, glob_img, grain=False) if "grain" in inspect.signature(simulate_full).parameters else simulate_full(s, glob_img)
            Image.fromarray(ia.to_uint8(ng)).save(kit / f"exports/photos/t.1.x__nograin__{stem}.jpg", quality=100, subsampling=0)
        Image.fromarray(np.asarray(Image.open(kit / "photos" / f"{stem}.jpg"))).save(kit / f"exports/photos/none__{stem}.jpg", quality=100, subsampling=0)
    (kit / "identity").mkdir(exist_ok=True); make_kit.write_hald(kit / "identity/hald_64_srgb16.tif")
    variants = ["full", "global"] + (["nograin"] if make_kit.needs_nograin(full_settings) else [])
    for variant in variants:
        (kit / "presets" / variant).mkdir(parents=True, exist_ok=True)
        (kit / "presets" / variant / f"t.1.x__{variant}.xmp").write_text(
            make_kit.settings_to_xmp(make_kit.kit_preset_settings(full_settings, variant), f"t [{variant}]"))
    entry = {"look_id": "t.1.x", "category": "t", "stop": 1, "name": "x", "full_xmp": "presets/full/t.1.x__full.xmp",
             "global_xmp": "presets/global/t.1.x__global.xmp"}
    if "nograin" in variants:
        entry["nograin_xmp"] = "presets/nograin/t.1.x__nograin.xmp"
    json.dump([entry], open(kit / "shortlist.json", "w"))
    make_kit.write_inputs(kit)
    ingest_kit.main(kit)
    return json.load(open(kit / "results/report.json"))["looks"]["t.1.x"]


def test_full_recipe_includes_separated_operators(tmp_path):
    settings = {"ProcessVersion": "11.0", "Clarity2012": "+40"}
    S = ingest_kit.spatial_calibration()
    def lightroom_full(src, glob_img):  # pretend Lightroom = global LUT then the same local-contrast operator
        with torch.no_grad():
            return lm.apply_local_contrast(torch.from_numpy(glob_img.astype(np.float32)), 40, 0, S).numpy()
    look = _kit(tmp_path, settings, lightroom_full)
    assert look["global"]["status"] == "validated", look["global"]
    assert look["full"]["status"] == "validated", look["full"]
    assert look["full"]["unimplemented"] == []


def test_global_lut_alone_is_not_accepted_as_full_recipe(tmp_path):
    """The old ingest compared the global LUT with the full Lightroom Look. A Look using an operator Lightly cannot
    render must not validate even when the numbers match. (Originally exercised with grain; grain has since been
    implemented as an experimental operator, so a non-Embedded camera profile, still not rendered, is used.)"""
    settings = {"ProcessVersion": "11.0", "CameraProfile": "Adobe Standard"}
    look = _kit(tmp_path, settings, lambda s, g: g)  # numbers match the LUT exactly
    assert look["full"]["status"] != "validated"
    assert "CameraProfile" in look["full"]["unimplemented"]
