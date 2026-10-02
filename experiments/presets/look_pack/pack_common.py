"""Shared helpers for the Look catalog and the Look pack.

The preset collection itself is private and lives outside the repository (default
~/Downloads/Presets - for lightly). Only the catalog (names, sources, categories, order) is
committed; LUTs derived from the presets are written to the git-ignored `out/` directory and are
reproducible from the collection plus the catalog.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
PRESETS = HERE.parent
sys.path[:0] = [str(PRESETS), str(PRESETS / "lr_kit"), str(PRESETS.parent / "lut3d/reference")]

import ia3dlut as ia  # noqa: E402
import lrsettings  # noqa: E402

DEFAULT_COLLECTION = Path.home() / "Downloads/Presets - for lightly"
LUT_DIMENSION = 33  # rendering contract (spec §4.1)

# Settings a LUT cannot carry: they vary across the image (spec §4.1, stage O3). A Look that uses
# them ships as its global part only, and the pack lists what was left out.
SPATIAL_OPERATORS = {
    "Clarity2012": "clarity",
    "Texture": "texture",
    "PostCropVignetteAmount": "vignette",
    "GrainAmount": "grain",
}
# Adaptive in Lightroom. The calibrated model folds them into the LUT as global approximations; the
# kit's global-only Lightroom variant removes them, so a HALD-derived LUT omits them instead.
ADAPTIVE_OPERATORS = {
    "Highlights2012": "highlights",
    "Shadows2012": "shadows",
    "Whites2012": "whites",
    "Blacks2012": "blacks",
    "Dehaze": "dehaze",
}


def display_name(preset_name: str) -> str:
    """The preset's own name, with runs of whitespace collapsed ("Nordic Tone  (10)" → "Nordic Tone (10)").

    Product-facing names are a separate decision (spec U8); until then the slider shows the preset's name.
    """
    return re.sub(r"\s+", " ", preset_name).strip()


def stable_look_id(name: str, source: str) -> str:
    """Order-independent ID: a readable slug plus a hash of the preset's source path.

    The kit's IDs ("warm.2.nordic-tone-10") embed category and stop, so they change whenever the
    catalog is reordered or relabelled; saved edits must not. This ID depends only on the preset.
    """
    slug = re.sub(r"[^a-z0-9]+", "-", display_name(name).lower()).strip("-")[:32].strip("-")
    digest = hashlib.sha256(source.encode("utf-8")).hexdigest()[:6]
    return f"{slug}-{digest}"


def _used(settings: dict, operators: dict[str, str]) -> list[str]:
    used = []
    for key, label in operators.items():
        try:
            value = float(settings.get(key, 0) or 0)
        except (TypeError, ValueError):
            value = 0.0
        if value != 0:
            used.append(label)
    return used


def operator_coverage(settings: dict, lut_source: str) -> dict[str, list[str]]:
    """What the Look's LUT leaves out, and what it only approximates globally, for this LUT source."""
    adaptive = _used(settings, ADAPTIVE_OPERATORS)
    if lut_source == "lightroom-hald":
        return {"omitted": _used(settings, SPATIAL_OPERATORS) + adaptive, "approximatedGlobally": []}
    return {"omitted": _used(settings, SPATIAL_OPERATORS), "approximatedGlobally": adaptive}


def read_preset(collection: Path, source: str):
    """Parse one preset by its catalog source ("pack.zip -> member" or a relative path)."""
    if " -> " in source:
        archive, member = source.split(" -> ", 1)
        data = zipfile.ZipFile(collection / archive).read(member)
        ext = Path(member).suffix.lower()
    else:
        data = (collection / source).read_bytes()
        ext = Path(source).suffix.lower()
    parsed = lrsettings.parse_bytes(data, source, ext)
    if parsed.error:
        raise ValueError(f"cannot parse {source}: {parsed.error}")
    return parsed


def lr_model_lut(settings: dict) -> np.ndarray:
    """Approximate global LUT[c,b,g,r] from the calibrated Lightroom model (held-out median ΔE00 4.8)."""
    import torch
    import lr_model as lm

    calib = lm.Calib()
    constants = json.load(open(PRESETS / "calibration_natural.json"))["constants"]
    calib.load_state_dict({k: torch.tensor(v) for k, v in constants.items()})
    baked = lm.bake_lut(lm.Preset(settings, wb_mode="rendered"), calib, dim=LUT_DIMENSION)  # [b,g,r,3]
    return np.moveaxis(baked, -1, 0).astype(np.float32)


def apply_lut(lut: np.ndarray, rgb01: np.ndarray) -> np.ndarray:
    return np.clip(ia.apply_lut_reference(lut, rgb01.astype(np.float32), binsize_numerator=1.0), 0, 1)


def lut_bytes(lut: np.ndarray) -> bytes:
    """Contract encoding shared with the apps: 33³ interleaved RGBA float32, red fastest."""
    if lut.shape != (3, LUT_DIMENSION, LUT_DIMENSION, LUT_DIMENSION):
        raise ValueError(f"LUT shape {lut.shape}")
    return ia.export_lut_rgba_float32(lut)
