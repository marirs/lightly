"""Dark-mode pair-row mock-ups (owner 2026-10-19: the white backing looked wrong). Real pack thumbnails, iOS metrics
at 3x: tile 66x54 pt, 14 pt corners, picture 52x22 pt, name 10.5 pt semibold. Writes variants.png."""
import json, sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageEnhance

R = Path(__file__).resolve().parents[3]; OUT = Path(__file__).resolve().parent
PACK = R / "shared/sunglasses/out"
pairs = sorted(json.load(open(PACK / "sunglasses.json"))["pairs"], key=lambda p: p["order"])
X = 3
SHEET = (0x17, 0x19, 0x1C); INK = (0xF2, 0xF3, 0xF0); INK2 = (0xA6, 0xAB, 0xA3); SEL = (0xCF, 0xF2, 0x6B)
FONT = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", int(10.5 * X)) if Path("/System/Library/Fonts/SFNS.ttf").exists() \
    else ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", int(10.5 * X))
TITLE = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", int(15 * X), index=1)
SUB = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", int(12 * X))

STUDIO = Path(__file__).resolve().parent / "studio"
def thumb(p, studio=False):
    return Image.open((STUDIO / f"{p['id']}.png") if studio else (PACK / p["thumbnail"])).convert("RGBA")

def fit(im, w, h):
    im = im.copy(); im.thumbnail((w, h), Image.LANCZOS)
    c = Image.new("RGBA", (w, h), (0, 0, 0, 0)); c.alpha_composite(im, ((w - im.width) // 2, (h - im.height) // 2)); return c

def rim(im, colour=(255, 255, 255), strength=0.55, radius=1.6):
    """A soft light outline hugging the frame's silhouette (behind it)."""
    a = (np.asarray(im.getchannel("A")) > 200).astype(np.float32)
    big = Image.fromarray((a * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(radius * X))
    g = np.clip(np.asarray(big).astype(np.float32) / 255 * 1.6, 0, 1) * strength
    halo = Image.new("RGBA", im.size, colour + (0,)); halo.putalpha(Image.fromarray((g * 255).astype(np.uint8)))
    halo.alpha_composite(im); return halo

def lift(im, amount=0.32):
    """Lifted shadows: black acetate reads as dark grey with its highlights, like a studio product shot."""
    rgb = np.asarray(im.convert("RGB")).astype(np.float32) / 255
    rgb = amount + (1 - amount) * rgb ** 0.8
    out = Image.fromarray((np.clip(rgb, 0, 1) * 255).astype(np.uint8)).convert("RGBA"); out.putalpha(im.getchannel("A")); return out

def spot(w, h, base, centre=(0x3A, 0x3E, 0x44)):
    """Tile surface with a soft spotlight from above the picture."""
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.sqrt(((xx - w / 2) / (w * 0.55)) ** 2 + ((yy - h * 0.38) / (h * 0.55)) ** 2)
    t = np.clip(1 - d, 0, 1) ** 1.6
    rgb = np.array(base) * (1 - t[..., None]) + np.array(centre) * t[..., None]
    return Image.fromarray(rgb.astype(np.uint8)).convert("RGBA")

def tile(p, variant, selected=False):
    w, h = 66 * X, 54 * X
    if variant == "spot":
        t = spot(w, h, SHEET)
    elif variant == "surface":
        t = Image.new("RGBA", (w, h), (0x2B, 0x2E, 0x33, 255))
    elif variant == "studio2":
        t = spot(w, h, (0x1C, 0x1E, 0x22), centre=(0x2C, 0x2F, 0x34))
    else:
        t = Image.new("RGBA", (w, h), SHEET + (255,))
    pic = fit(thumb(p, studio=variant.startswith("studio")), 52 * X, 22 * X) if p else None
    if pic is not None:
        if variant == "now":
            back = Image.new("RGBA", (56 * X, 26 * X), (0, 0, 0, 0))
            ImageDraw.Draw(back).rounded_rectangle([0, 0, back.width - 1, back.height - 1], 7 * X, fill=(0xF3, 0xF3, 0xF0, 230))
            t.alpha_composite(back, (5 * X, 6 * X))
        if variant == "rim": pic = rim(pic, strength=0.45, radius=1.0)
        if variant == "lift": pic = lift(pic)
        if variant == "spot": pic = rim(pic, strength=0.22, radius=2.2)
        t.alpha_composite(pic, (7 * X, 8 * X))
    else:
        ImageDraw.Draw(t).rectangle([17 * X, 18 * X, 49 * X, int(19.5 * X)], fill=(0x80, 0x85, 0x7D))
    d = ImageDraw.Draw(t)
    name = p["name"] if p else "None"
    tw = d.textlength(name, font=FONT); d.text(((w - tw) / 2, 34 * X), name, font=FONT, fill=INK if selected else INK2)
    mask = Image.new("L", (w, h), 0); ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], 14 * X, fill=255)
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0)); out.paste(t, (0, 0), mask)
    ImageDraw.Draw(out).rounded_rectangle([0, 0, w - 1, h - 1], 14 * X, outline=SEL if selected else (255, 255, 255, 28),
                                          width=2 * X if selected else X)
    return out

VARIANTS = [("now", "Now: light backing (rejected)"),
            ("studio", "A · Pairs re-rendered with studio rim light (dark mode set)"),
            ("studio2", "B · A + a soft spotlight on the tile"),
            ("rim", "C · Original pictures, thin light edge around each frame"),
            ("surface", "D · Original pictures on a lighter tile")]

rows = []
for key, label in VARIANTS:
    W = 16 * X + 6 * (66 * X) + 5 * 8 * X
    row = Image.new("RGBA", (W, 92 * X), SHEET + (255,))
    d = ImageDraw.Draw(row); d.text((16 * X, 8 * X), label, font=SUB, fill=INK)
    x = 16 * X
    for i, p in enumerate([None, pairs[1], pairs[2], pairs[4], pairs[5], pairs[6]]):
        row.alpha_composite(tile(p, key, selected=(i == 2)), (x, 30 * X)); x += 74 * X
    rows.append(row)
sheet = Image.new("RGB", (rows[0].width, sum(r.height for r in rows) + 4 * (len(rows) - 1)), (60, 60, 60))
y = 0
for r in rows: sheet.paste(r.convert("RGB"), (0, y)); y += r.height + 4
sheet.save(OUT / "variants.png")
print(OUT / "variants.png", sheet.size)
