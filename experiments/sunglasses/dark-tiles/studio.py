"""Dark-mode tile pictures re-rendered from the pack with studio rim lighting (render_lsg.swift, LSG_STUDIO=1) and
lenses with a sky reflection, same framing as build_sunglasses.thumbnail. Writes studio/<id>.png (git-ignored)."""
import json, math, os, subprocess, sys
from pathlib import Path
import numpy as np
from PIL import Image

R = Path(__file__).resolve().parents[3]; PACK = R / "shared/sunglasses/out"; OUT = Path(__file__).resolve().parent / "studio"
OUT.mkdir(exist_ok=True); renderer = sys.argv[1]
t = math.radians(22); ex = (math.cos(t), 0, -math.sin(t)); ez = (math.sin(t), 0, math.cos(t))
for p in json.load(open(PACK / "sunglasses.json"))["pairs"]:
    tmp = OUT / "_t"
    args = [renderer, str(PACK), p["id"], str(tmp), "480", "240", "240", "112", "2700", *map(str, (*ex, 0, 1, 0, *ez))]
    env = dict(os.environ, LSG_STUDIO="1")
    for kind in ("frame", "lens"): subprocess.run(args + [kind], check=True, capture_output=True, env=env)
    fr = Image.open(f"{tmp}.frame.png").convert("RGBA"); ln = np.asarray(Image.open(f"{tmp}.lens.png").convert("RGBA"), np.float32)
    L = ln[..., 0] / 255 * ln[..., 3] / 255; H, W = L.shape
    # Lens: dark glass with a cool sky reflection across its top third, so the lens shape reads on dark.
    g = np.clip(1 - np.linspace(0, 1, H) / 0.45, 0, 1)[:, None] ** 1.5
    rgb = np.stack([np.full((H, W), 30.) + g * 150, np.full((H, W), 34.) + g * 162, np.full((H, W), 40.) + g * 185], -1)
    lens = Image.fromarray(np.dstack([rgb.clip(0, 255), L * 240]).astype(np.uint8), "RGBA"); lens.alpha_composite(fr)
    lens = lens.crop(lens.getbbox()); lens.thumbnail((200, 100), Image.LANCZOS); lens.save(OUT / f"{p['id']}.png")
    for kind in ("frame", "lens"): Path(f"{tmp}.{kind}.png").unlink(missing_ok=True)
print("rendered", OUT)
