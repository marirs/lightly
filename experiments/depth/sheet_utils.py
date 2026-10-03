"""Small helpers for labelled contact sheets (PIL only)."""
import numpy as np
from PIL import Image, ImageDraw, ImageFont

LABEL_HEIGHT = 34


def _font(size: int):
    for path in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def to_pil(image: np.ndarray) -> Image.Image:
    if image.ndim == 2:
        image = np.repeat(image[..., None], 3, axis=2)
    return Image.fromarray((np.clip(image, 0, 1) * 255).round().astype(np.uint8))


def colourise_disparity(disparity: np.ndarray) -> np.ndarray:
    """Near = warm/bright, far = dark blue (perceptually ordered 'inferno'-like ramp, no matplotlib)."""
    stops = np.array([[0.00, 0.00, 0.02], [0.23, 0.05, 0.45], [0.70, 0.17, 0.40],
                      [0.98, 0.55, 0.04], [0.99, 1.00, 0.64]], dtype=np.float32)
    position = np.clip(disparity, 0, 1) * (len(stops) - 1)
    lower = np.floor(position).astype(int).clip(0, len(stops) - 2)
    fraction = (position - lower)[..., None]
    return stops[lower] * (1 - fraction) + stops[lower + 1] * fraction


def tile(image, label: str, width: int) -> Image.Image:
    pil = image if isinstance(image, Image.Image) else to_pil(image)
    pil = pil.resize((width, round(pil.height * width / pil.width)), Image.LANCZOS)
    canvas = Image.new("RGB", (width, pil.height + LABEL_HEIGHT), (250, 250, 248))
    canvas.paste(pil, (0, LABEL_HEIGHT))
    ImageDraw.Draw(canvas).text((6, 7), label, fill=(20, 20, 20), font=_font(17))
    return canvas


def grid(rows: list[list[Image.Image]], title: str | None = None, gap: int = 6) -> Image.Image:
    row_heights = [max(t.height for t in row) for row in rows]
    width = max(sum(t.width for t in row) + gap * (len(row) - 1) for row in rows)
    title_height = 48 if title else 0
    sheet = Image.new("RGB", (width + 2 * gap, sum(row_heights) + gap * (len(rows) + 1) + title_height), "white")
    if title:
        ImageDraw.Draw(sheet).text((gap + 4, 10), title, fill=(0, 0, 0), font=_font(24))
    y = gap + title_height
    for row, height in zip(rows, row_heights):
        x = gap
        for t in row:
            sheet.paste(t, (x, y))
            x += t.width + gap
        y += height + gap
    return sheet
