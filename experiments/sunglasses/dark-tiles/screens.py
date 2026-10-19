"""Full iPhone dark-mode screens with the pair row redrawn per variant (mock.py tiles over a real capture)."""
import sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont
sys.path.insert(0, str(Path(__file__).resolve().parent))
import importlib.util
spec = importlib.util.spec_from_file_location("mock", Path(__file__).resolve().parent / "mock.py"); mock = importlib.util.module_from_spec(spec)
import builtins
spec.loader.exec_module(mock)
cap = Image.open(sys.argv[1]).convert("RGBA")
order = ["Pilot", "Aviator", "Bridge", "Wayfarer", "Sport", "Round"]
byname = {p["name"]: p for p in mock.pairs}
panel = cap.getpixel((20, 1950))[:3]
def screen(variant):
    im = cap.copy()
    d = ImageDraw.Draw(im); d.rectangle([0, 1860, im.width, 2046], fill=panel + (255,))
    for i, n in enumerate(order):
        t = mock.tile(byname[n], variant, selected=(n == "Aviator"))
        if variant == "old":
            t = mock.tile(byname[n], "plain", selected=(n == "Aviator"))
        im.alpha_composite(t, (48 + 222 * i, 1872))
    # The row's trailing fade, as the app draws it.
    a = np.asarray(im).astype(np.float32); x0 = im.width - 160
    w = np.clip((np.arange(im.width) - x0) / 160, 0, 1)[None, :, None] * 0.88
    a[1860:2046, :, :3] = a[1860:2046, :, :3] * (1 - w) + np.array(panel)[None, None, :] * w
    return Image.fromarray(a.astype(np.uint8))
labels = [("old", "Before any change"), ("now", "Light backing (rejected)"), ("studio", "A · Studio-lit pictures"), ("studio2", "B · A + spotlit tile")]
shots = [screen(v) for v, _ in labels]
W = shots[0].width // 3; H = shots[0].height // 3
sheet = Image.new("RGB", (W * 4 + 60, H + 90), (40, 40, 40)); d = ImageDraw.Draw(sheet)
f = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 30)
for i, (s, (_, l)) in enumerate(zip(shots, labels)):
    sheet.paste(s.convert("RGB").resize((W, H), Image.LANCZOS), (i * (W + 20), 80)); d.text((i * (W + 20) + 10, 22), l, font=f, fill=(240, 240, 240))
sheet.save(Path(__file__).resolve().parent / "screens.png")
for (v, _), s in zip(labels, shots): s.convert("RGB").crop((0, 1500, s.width, 2300)).save(Path(__file__).resolve().parent / f"row-{v}.png")
print("ok")
