import sys
from pathlib import Path

LOOK_PACK = Path(__file__).resolve().parents[1]
REPO = LOOK_PACK.parents[1]
sys.path[:0] = [str(LOOK_PACK), str(REPO / "experiments/presets"), str(REPO / "experiments/presets/lr_kit"),
                str(REPO / "experiments/presets/look_pack"), str(REPO / "experiments/lut3d/reference")]
