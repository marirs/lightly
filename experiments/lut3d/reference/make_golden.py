"""Produce golden fixtures + desktop reference results for every test photo.

For each image (photos/*.jpg plus the upstream demo image) writes golden/<stem>/:
  source.png           oriented (EXIF applied), converted to 8-bit sRGB; the parity input for platforms
  input256.f32         1x3x256x256 float32 NCHW, deployment preprocessing (antialiased whole-frame resize)
  fused_lut.f32        33^3 RGBA float32 (red fastest) fused from the deployment weights
  reference.png        exact-grid trilinear application of fused_lut to source.png (8-bit, demo rounding)
  meta.json            weights (reference-path and deployment-path), colour info, timings, LUT range

Stages are separated so a platform mismatch can be localised:
  model parity:          platform(input256.f32) vs meta.weights_deploy
  preprocessing parity:  platform(source.png -> 256) -> weights vs meta.weights_deploy
  LUT application:       platform(source.png, fused_lut.f32) vs reference.png
"""
import io, json, os, sys, time
import numpy as np
from PIL import Image, ImageCms, ImageOps
import ia3dlut as ia

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, "..")
golden_dir = os.path.join(root, "golden")
os.makedirs(golden_dir, exist_ok=True)
model = ia.load_reference_model(os.path.join(here, "upstream/pretrained_models/sRGB"))
model_ac = ia.load_reference_model(os.path.join(here, "upstream/pretrained_models/sRGB"), align_corners=True)
SRGB = ImageCms.createProfile("sRGB")


def load_as_srgb(path):
    """Decode, apply EXIF orientation, convert embedded ICC -> sRGB (relative colorimetric). Returns (uint8 HxWx3, info)."""
    im = Image.open(path)
    info = {"mode": im.mode, "icc": None, "converted_from_icc": False}
    icc = im.info.get("icc_profile")
    im = ImageOps.exif_transpose(im).convert("RGB")
    if icc:
        src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        info["icc"] = ImageCms.getProfileDescription(src).strip()
        if "srgb" not in info["icc"].lower():
            im = ImageCms.profileToProfile(im, src, SRGB, renderingIntent=ImageCms.Intent.RELATIVE_COLORIMETRIC, outputMode="RGB")
            info["converted_from_icc"] = True
    return np.asarray(im), info


def process(path):
    stem = os.path.splitext(os.path.basename(path))[0]
    out = os.path.join(golden_dir, stem)
    os.makedirs(out, exist_ok=True)
    rgb, info = load_as_srgb(path)
    Image.fromarray(rgb).save(os.path.join(out, "source.png"))

    t0 = time.perf_counter()
    x256 = ia.prepare_256_antialiased(rgb)
    w_deploy = ia.predict_weights_from_256(model, x256)
    t_infer = time.perf_counter() - t0
    x256.astype(np.float32).tofile(os.path.join(out, "input256.f32"))

    w_ref = ia.predict_weights_reference(model, rgb)  # upstream path: bilinear from full res, no AA
    w_ref_ac = ia.predict_weights_reference(model_ac, rgb)
    # Training regime: FiveK 480p inputs. Downscale to 480 short side then the upstream path.
    h, w = rgb.shape[:2]
    s = 480 / min(h, w)
    rgb480 = np.asarray(Image.fromarray(rgb).resize((round(w * s), round(h * s)), Image.LANCZOS))
    w_480 = ia.predict_weights_reference(model, rgb480)

    lut = ia.fuse_luts(model.basis_luts, w_deploy)
    with open(os.path.join(out, "fused_lut.f32"), "wb") as f:
        f.write(ia.export_lut_rgba_float32(lut))

    t0 = time.perf_counter()
    result = ia.apply_lut_reference(lut, rgb.astype(np.float32) / 255.0, binsize_numerator=1.0)
    t_apply = time.perf_counter() - t0
    out8 = ia.to_uint8(result)
    Image.fromarray(out8).save(os.path.join(out, "reference.png"))

    clipped = float(((result < 0) | (result > 1)).any(axis=-1).mean())
    meta = {
        "stem": stem, "width": int(w), "height": int(h), "colour": info,
        "weights_deploy": w_deploy.tolist(), "weights_upstream_fullres": w_ref.tolist(),
        "weights_upstream_fullres_align_corners": w_ref_ac.tolist(), "weights_upstream_480p": w_480.tolist(),
        "fused_lut_min": float(lut.min()), "fused_lut_max": float(lut.max()),
        "fraction_pixels_clipped_by_lut": clipped,
        "mean_abs_change_8bit": float(np.abs(out8.astype(np.int16) - rgb.astype(np.int16)).mean()),
        "desktop_numpy_cpu": {"preprocess_plus_infer_s": t_infer, "apply_lut_fullres_s": t_apply,
                              "note": "numpy/torch CPU on Apple M4 desktop; NOT representative of phones"},
    }
    json.dump(meta, open(os.path.join(out, "meta.json"), "w"), indent=2)
    print(f"{stem:24s} {w}x{h} w_deploy={np.round(w_deploy,3)} w_up={np.round(w_ref,3)} w_480={np.round(w_480,3)} change={meta['mean_abs_change_8bit']:.1f}")


if __name__ == "__main__":
    paths = sys.argv[1:] or sorted(
        [os.path.join(root, "photos", p) for p in os.listdir(os.path.join(root, "photos")) if p.lower().endswith((".jpg", ".jpeg"))]
    ) + [os.path.join(here, "upstream/demo_images/sRGB/a1629.jpg")]
    for p in paths:
        process(p)
