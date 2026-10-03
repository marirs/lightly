"""Shared paths and the demonstration photo set for the depth experiment."""
import pathlib

import numpy as np
from PIL import Image, ImageOps

DEPTH_ROOT = pathlib.Path(__file__).resolve().parent
REPO_ROOT = DEPTH_ROOT.parents[1]
PHOTOS_DIR = REPO_ROOT / "experiments" / "lut3d" / "photos"  # Unsplash Licence, see MANIFEST.csv there
MODELS_DIR = DEPTH_ROOT / "models"
CACHE_DIR = DEPTH_ROOT / "cache"
RESULTS_DIR = DEPTH_ROOT / "results"
SHEETS_DIR = pathlib.Path.home() / ".codex" / "artifacts" / "lightly" / "v1" / "depth"

# Working resolution of the reference renderer (long side, px). All blur radii in the renderer are
# expressed relative to the long side, so preview and export look the same at any resolution.
WORKING_LONG_SIDE = 1600

# Demonstration set: chosen for real depth range (near subject + far background), bokeh highlights
# (night), continuous depth (alley, meadow) and subjects that Vision can separate.
DEMO_PHOTOS = [
    "portrait_deep_02",   # man, trees and railing behind
    "portrait_medium_02", # woman close to a shutter wall (shallow scene depth)
    "portrait_light_01",  # woman, wall receding to the left
    "backlit_02",         # person in a meadow, trees, sun highlight
    "night_01",           # street at night: point-light highlights for bokeh shapes
    "wellexposed_03",     # alley: continuous depth from foreground to vanishing point
    "landscape_01",       # flowers in front, mountains far away
]
# Backgrounds used for the replacement-then-blur case.
REPLACEMENT_BACKGROUNDS = ["landscape_02", "wellexposed_02"]


def load_working_image(stem: str) -> np.ndarray:
    """sRGB image as float32 HxWx3 in [0,1], EXIF-orientation applied, long side = WORKING_LONG_SIDE."""
    cached = CACHE_DIR / "src" / f"{stem}.png"
    if not cached.exists():
        cached.parent.mkdir(parents=True, exist_ok=True)
        image = ImageOps.exif_transpose(Image.open(PHOTOS_DIR / f"{stem}.jpg")).convert("RGB")
        scale = WORKING_LONG_SIDE / max(image.size)
        image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
        image.save(cached)
    return np.asarray(Image.open(cached).convert("RGB"), dtype=np.float32) / 255.0


def load_subject_matte(stem: str, shape: tuple) -> np.ndarray | None:
    """Vision foreground matte in [0,1] (see subject_mask.swift), or None when there is no subject."""
    path = CACHE_DIR / "masks" / f"{stem}.png"
    if not path.exists():
        return None
    matte = Image.open(path).convert("L")
    if matte.size != (shape[1], shape[0]):
        matte = matte.resize((shape[1], shape[0]), Image.BILINEAR)
    return np.asarray(matte, dtype=np.float32) / 255.0
