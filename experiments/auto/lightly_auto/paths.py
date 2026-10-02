"""Repository locations and the bridge to the M1 reference port (experiments/lut3d/reference/ia3dlut.py).

The reference port is reused, not copied, so the training pipeline and the evaluation runner share the
exact deployment preprocessing (pinned antialiased resize) and LUT layout that the apps' golden tests use.
"""
from __future__ import annotations

import os
import sys

AUTO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(os.path.dirname(AUTO_ROOT))
LUT3D_ROOT = os.path.join(REPO_ROOT, "experiments", "lut3d")
LUT3D_REFERENCE_DIR = os.path.join(LUT3D_ROOT, "reference")
GOLDEN_DIR = os.path.join(LUT3D_ROOT, "golden")
FACES_JSON = os.path.join(GOLDEN_DIR, "faces.json")
# Research-only (FiveK expert C) weights. Used only by the internal research baseline arm.
RESEARCH_WEIGHTS_DIR = os.path.join(LUT3D_REFERENCE_DIR, "upstream", "pretrained_models", "sRGB")
PROTOCOL_JSON = os.path.join(AUTO_ROOT, "PROTOCOL.json")
PROTOCOL_LOCK = os.path.join(AUTO_ROOT, "PROTOCOL.lock")
RUNS_DIR = os.path.join(AUTO_ROOT, "runs")
RESULTS_DIR = os.path.join(AUTO_ROOT, "results")

if LUT3D_REFERENCE_DIR not in sys.path:
    sys.path.insert(0, LUT3D_REFERENCE_DIR)

import ia3dlut  # noqa: E402  (import after sys.path setup is the point of this module)

__all__ = ["ia3dlut", "AUTO_ROOT", "REPO_ROOT", "GOLDEN_DIR", "FACES_JSON", "RESEARCH_WEIGHTS_DIR",
           "PROTOCOL_JSON", "PROTOCOL_LOCK", "RUNS_DIR", "RESULTS_DIR"]
