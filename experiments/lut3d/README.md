# experiments/lut3d — Image-Adaptive 3D LUT feasibility (M1)

This experiment is isolated from the production app (`Lightly/`, `Tests/`, `project.yml`), and nothing here is linked into it. The pretrained weights are **research-only** (MIT-Adobe FiveK), so they and every artefact converted from them are git-ignored and must not be bundled in any app build (see `docs/m1/licensing.md`).

Findings are in `docs/m1/lut-feasibility.md`.

## Layout

| Path | Committed? | Contents |
|---|---|---|
| `reference/ia3dlut.py` | yes | Python port (classifier, trilinear, fusion, strength, experimental guardrails, local exposure) |
| `reference/fetch_reference.sh` | yes | Clones upstream at `b491f6d` and verifies weight sha256s → `reference/upstream/` (ignored) |
| `reference/verify_port.py` | yes | Port vs upstream C kernel compiled verbatim |
| `reference/convert.py` | yes | → `models/` Core ML fp32/fp16, ONNX, basis LUT bin, `MODEL_CARD.json` |
| `reference/make_golden.py` | yes | → `golden/<stem>/` (source.png, input256.f32, fused_lut.f32, reference.png, meta.json) — ignored, ~600 MB |
| `reference/compare.py` | yes | → `report/sheets/*.jpg`, `report/auto_stats.csv` |
| `reference/desktop_parity.py` | yes | → `report/desktop_parity.json` |
| `reference/faces.swift` | yes | Apple Vision face boxes → `golden/faces.json` |
| `reference/evaluate.py` | yes | Scene rubric → `report/eval_rubric.csv`, `report/eval_sheets/*.jpg` |
| `photos/MANIFEST.csv` | yes | 22 Unsplash test photos: source URL, photographer, licence, sha256 (JPEGs ignored) |
| `ios/` | yes (sources) | LUTBench harness + `run_ios.sh` |
| `android/` | yes (sources) | LUTBench harness + `run_android.sh` |
| `results/` | yes (JSON only) | Per-device harness results |

## Reproduce

```bash
python3.11 -m venv .venv && .venv/bin/pip install torch==2.5.1 torchvision==0.20.1 coremltools==8.3 onnx onnxruntime pillow numpy scikit-image opencv-python-headless
cd reference
./fetch_reference.sh
../.venv/bin/python verify_port.py <path/to/libtri.dylib>   # build: see header of verify_port.py
../.venv/bin/python convert.py
# download photos listed in photos/MANIFEST.csv (download_url column) into photos/
../.venv/bin/python make_golden.py
swiftc -O faces.swift -o /tmp/faces && /tmp/faces ../golden
../.venv/bin/python compare.py && ../.venv/bin/python desktop_parity.py && ../.venv/bin/python evaluate.py
```

To build `libtri.dylib`, extract `TriLinearForwardCpu` from `upstream/trilinear_cpp/src/trilinear.cpp`, prepend `#include <math.h>`, then run `clang -O2 -shared -fPIC -o libtri.dylib tri.c`.
