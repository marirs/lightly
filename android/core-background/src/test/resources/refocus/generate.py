"""Reference vectors for the Kotlin port of experiments/depth/refocus.py (the numpy-only parts).

refocus.py imports cv2 and scipy at module level; neither is needed for the kernels, the signed
circle of confusion or the highlight curve, and neither is installed in the venvs available here, so
this script provides empty stand-ins for those two imports. Everything computed below is plain NumPy.

    python android/core-background/src/test/resources/refocus/generate.py
"""
import json
import sys
import types
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[5]
for name in ("cv2", "scipy", "scipy.fft"):
    sys.modules.setdefault(name, types.ModuleType(name))
sys.modules["scipy"].fft = sys.modules["scipy.fft"]
sys.path.insert(0, str(REPO / "experiments/depth"))
import refocus as rf  # noqa: E402

out = {"kernels": {}, "coc": [], "highlights": []}
for shape in rf.BOKEH_SHAPES:
    for radius in (3.0, 7.3):
        k = rf.bokeh_kernel(shape, radius)
        out["kernels"][f"{shape}-{radius}"] = {"size": k.shape[0], "values": [round(float(v), 9) for v in k.ravel()]}
k = rf.motion_kernel(6.0, 30.0)
out["kernels"]["motion-6.0-30"] = {"size": k.shape[0], "values": [round(float(v), 9) for v in k.ravel()]}
k = rf.gaussian_kernel(5.0)
out["kernels"]["gaussian-5.0"] = {"size": k.shape[0], "values": [round(float(v), 9) for v in k.ravel()]}
for d, f, h, r in [(0.9, 0.5, 0.1, 20.0), (0.1, 0.5, 0.1, 20.0), (0.55, 0.5, 0.1, 20.0), (0.0, 1.0, 0.3, 33.0)]:
    out["coc"].append({"disparity": d, "focal": f, "halfWidth": h, "radiusMax": r,
                       "coc": float(rf.signed_coc(np.array([d], np.float32), f, h, r)[0])})
pixels = np.array([[[0.2, 0.4, 0.6], [0.8, 0.5, 0.1], [1.0, 1.0, 1.0], [0.95, 0.72, 0.1]]], np.float32)
expanded = rf.expand_highlights(pixels)
out["highlights"] = {"input": pixels.ravel().tolist(), "expanded": [float(v) for v in expanded.ravel()],
                     "roundTrip": [float(v) for v in rf.compress_highlights(expanded).ravel()]}
(HERE / "vectors.json").write_text(json.dumps(out) + "\n")
print("wrote", HERE / "vectors.json")
