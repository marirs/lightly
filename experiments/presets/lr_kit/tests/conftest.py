import sys
from pathlib import Path

KIT_DIR = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(KIT_DIR), str(KIT_DIR.parent), str(KIT_DIR.parents[1] / "lut3d/reference")]
