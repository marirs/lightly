"""Digests that bind a validation report to exactly what was measured.

ingest_kit writes these next to each Look's results; build_look_pack recomputes them for what it is
about to ship and promotes a Look only when they match. Without the binding, a report about one LUT
could promote a different LUT (Codex review of d5690dd: an all-black LUT stayed "validated").

- lut:      the exact LUT bytes in the pack encoding (33³ RGBA float32, red fastest).
- recipe:   the ORIGINAL preset's develop settings (identity fields such as Name/UUID removed), so
            an edited preset invalidates evidence even if the LUT happens to come out the same.
- renderer: the code and constants Lightly's full recipe depends on (approximation model, spatial
            operators and their calibration). Changing them changes the full-recipe render, so
            full-recipe evidence is stale until re-measured. Global-colour evidence does not depend
            on it: that comparison applies only the LUT.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Fields that name or file a preset but do not change pixels.
IDENTITY_KEYS = {"Name", "UUID", "Group", "PresetType", "Cluster", "Version", "ProcessVersion",
                 "SupportsAmount", "SupportsColor", "SupportsMonochrome", "SupportsHighDynamicRange",
                 "SupportsNormalDynamicRange", "SupportsSceneReferred", "SupportsOutputReferred"}
RENDERER_FILES = ("lr_model.py", "calibration_natural.json", "calibration_spatial_natural.json")


def lut_digest(lut_bytes: bytes) -> str:
    return hashlib.sha256(lut_bytes).hexdigest()


def recipe_digest(settings: dict) -> str:
    pixel_settings = {k: v for k, v in settings.items() if k not in IDENTITY_KEYS}
    canonical = json.dumps(pixel_settings, sort_keys=True, separators=(",", ":"), ensure_ascii=False, default=str)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def renderer_digest(root: Path = HERE) -> str:
    h = hashlib.sha256()
    for name in RENDERER_FILES:
        h.update(name.encode())
        h.update((root / name).read_bytes())
    return h.hexdigest()


def evidence_block(lut_bytes: bytes, settings: dict) -> dict:
    return {"lutSha256": lut_digest(lut_bytes), "recipeSha256": recipe_digest(settings),
            "rendererSha256": renderer_digest()}
