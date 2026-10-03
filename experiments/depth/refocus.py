"""Reference depth-based refocus renderer for Background > Focus & Blur.

This is the executable form of the algorithm specified in docs/v1/depth-evaluation.md
("Rendering specification"). Section numbers in comments (§R1..§R9) refer to that document. It is a
reference for parity, not a fast implementation: every per-layer blur is an FFT convolution at the
working resolution, whereas the apps gather at reduced resolution on the GPU (§R7 allows that).

Scene model (§R2). The photo is decomposed into at most two planes, each with colour, coverage
(alpha) and per-pixel disparity (larger = nearer, [0,1]):
  * background plane — opaque. Either the original photo with the subject region filled in from its
    surroundings, or the replacement background placed at a chosen disparity behind the subject.
  * subject plane — the subject's de-contaminated colour with the Vision/ML Kit matte as alpha.
Without a subject matte there is only the background plane (pure depth refocus).

Each plane is split into signed circle-of-confusion layers (§R4), blurred with the style kernel
(§R5) and composited back to front (§R6): the layers behind the focal band are accumulated and then
normalised (pull-push), which fills disocclusions from the same depth instead of smearing nearer
colours into them; that is what removes halos. The focal and in-front layers of each plane are
summed (not "over"-composited, see render()) with their spread alpha, so a blurred foreground stays
opaque inside and correctly turns semi-transparent at its edges.
"""
from __future__ import annotations

import dataclasses
import math

import cv2
import numpy as np
import scipy.fft

# ----------------------------------------------------------------------------------------- params

STYLES = ("lens", "soft", "swirl", "motion")
BOKEH_SHAPES = ("round", "hex", "heart", "star")


@dataclasses.dataclass
class FocusBlurParams:
    """UI state of Focus & Blur, mirroring the approved prototype (docs/ui/app/app.js `bg`)."""
    target_x: float = 0.5          # tap point, normalised image coordinates (origin top-left)
    target_y: float = 0.5
    blur: float = 55.0             # 0..100  "Blur"
    focus_depth: float = 40.0      # 0..100  "Focus depth" = depth of field (width of the sharp band)
    style: str = "lens"            # lens | soft | swirl | motion
    bokeh: str = "round"           # lens only: round | hex | heart | star
    style_amount: float = 50.0     # 0..100  soft: Glow, swirl: Swirl, motion: Direction (-180..180 via *3.6-180)


# Constants that both platforms must use (§R3, §R4). Radii are fractions of the image long side.
MAX_COC_FRACTION_OF_LONG_SIDE = 0.035   # blur 100 -> 3.5 % of the long side (56 px at 1600 px)
MAX_FOCUS_HALF_WIDTH = 0.30             # focus depth 100 -> sharp band of +-0.30 disparity
LAYERS_PER_SIDE = 8                     # signed CoC quantisation: 8 behind + focal + 8 in front
SUBJECT_DEPTH_COMPRESSION = 0.5         # subject disparity pulled half-way to its median
REPLACEMENT_MIN_GAP = 0.10              # a replacement background stays at least this far behind the subject
HIGHLIGHT_THRESHOLD = 0.70              # linear max-channel value where highlight expansion starts
HIGHLIGHT_GAIN = 0.85                   # expansion strength (1.0 linear maps to 1/(1-0.85) = 6.7)


def focus_half_width(focus_depth: float) -> float:
    return MAX_FOCUS_HALF_WIDTH * (np.clip(focus_depth, 0, 100) / 100.0) ** 1.5


def max_coc_radius_px(blur: float, long_side: int) -> float:
    return np.clip(blur, 0, 100) / 100.0 * MAX_COC_FRACTION_OF_LONG_SIDE * long_side


# --------------------------------------------------------------------------------- colour (§R1)

def srgb_to_linear(srgb: np.ndarray) -> np.ndarray:
    return np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4).astype(np.float32)


def linear_to_srgb(linear: np.ndarray) -> np.ndarray:
    linear = np.clip(linear, 0, 1)
    return np.where(linear <= 0.0031308, linear * 12.92, 1.055 * linear ** (1 / 2.4) - 0.055).astype(np.float32)


def expand_highlights(linear: np.ndarray) -> np.ndarray:
    """Invertible highlight expansion (§R1): clipped lights regain energy so bokeh balls stay bright.

    Applied to the max channel and scaled per pixel so hue is preserved. Below the threshold it is
    the identity, so midtones are not biased; `compress_highlights` is its exact inverse, so
    unblurred pixels round-trip unchanged.
    """
    peak = linear.max(axis=2, keepdims=True)
    u = np.clip((peak - HIGHLIGHT_THRESHOLD) / (1 - HIGHLIGHT_THRESHOLD), 0, 1)
    expanded_peak = np.where(peak > HIGHLIGHT_THRESHOLD,
                             HIGHLIGHT_THRESHOLD + (1 - HIGHLIGHT_THRESHOLD) * u / (1 - HIGHLIGHT_GAIN * u), peak)
    return (linear * expanded_peak / np.maximum(peak, 1e-6)).astype(np.float32)


def compress_highlights(expanded: np.ndarray) -> np.ndarray:
    peak = expanded.max(axis=2, keepdims=True)
    v = np.maximum(peak - HIGHLIGHT_THRESHOLD, 0) / (1 - HIGHLIGHT_THRESHOLD)
    compressed_peak = np.where(peak > HIGHLIGHT_THRESHOLD,
                               HIGHLIGHT_THRESHOLD + (1 - HIGHLIGHT_THRESHOLD) * v / (1 + HIGHLIGHT_GAIN * v), peak)
    return (expanded * compressed_peak / np.maximum(peak, 1e-6)).astype(np.float32)


# ----------------------------------------------------------------------------- fill (pull-push)

def pull_push_fill(premultiplied: np.ndarray, coverage: np.ndarray) -> np.ndarray:
    """Normalised fill of a partially covered image (§R6, Kraus & Strengert 2007 pull-push).

    `premultiplied` is HxWxC (colour already multiplied by coverage), `coverage` HxW in [0,1].
    Returns HxWxC un-premultiplied colour defined everywhere: where coverage is 1 it is the input,
    where coverage is partial it is normalised, where it is 0 it comes from coarser levels.
    """
    levels = [(premultiplied.astype(np.float32), coverage.astype(np.float32))]
    while min(levels[-1][1].shape) > 4:
        colour, alpha = levels[-1]
        h, w = alpha.shape
        size = ((w + 1) // 2, (h + 1) // 2)
        down_colour = cv2.resize(colour, size, interpolation=cv2.INTER_AREA)
        down_alpha = cv2.resize(alpha, size, interpolation=cv2.INTER_AREA)
        if down_colour.ndim == 2:
            down_colour = down_colour[..., None]
        # Re-normalise coverage per level so a half-covered region becomes fully covered one level up.
        gain = np.minimum(down_alpha * 4.0, 1.0) / np.maximum(down_alpha, 1e-6)
        levels.append((down_colour * gain[..., None], np.minimum(down_alpha * 4.0, 1.0)))
    colour, alpha = levels[-1]
    filled = colour / np.maximum(alpha, 1e-6)[..., None]
    for colour, alpha in reversed(levels[:-1]):
        h, w = alpha.shape
        upsampled = cv2.resize(filled, (w, h), interpolation=cv2.INTER_LINEAR)
        if upsampled.ndim == 2:
            upsampled = upsampled[..., None]
        clamped = np.clip(alpha, 0, 1)[..., None]
        filled = colour + (1 - clamped) * upsampled
    return filled.astype(np.float32)


def fill_masked(values: np.ndarray, valid_weight: np.ndarray) -> np.ndarray:
    """Replace low-weight pixels of `values` (HxW or HxWxC) with a smooth fill from valid ones."""
    squeeze = values.ndim == 2
    stack = values[..., None] if squeeze else values
    filled = pull_push_fill(stack * valid_weight[..., None], valid_weight)
    blended = stack * valid_weight[..., None] + filled * (1 - valid_weight[..., None])
    return blended[..., 0] if squeeze else blended


# ------------------------------------------------------------------------- depth refinement (§R2)

def guided_filter(guide: np.ndarray, source: np.ndarray, radius: int, epsilon: float) -> np.ndarray:
    """He et al. guided filter (grey guide). Snaps upsampled depth edges to image edges."""
    def box(x):
        return cv2.boxFilter(x, -1, (2 * radius + 1, 2 * radius + 1), borderType=cv2.BORDER_REFLECT)
    mean_i, mean_p = box(guide), box(source)
    variance_i = box(guide * guide) - mean_i * mean_i
    covariance_ip = box(guide * source) - mean_i * mean_p
    a = covariance_ip / (variance_i + epsilon)
    b = mean_p - a * mean_i
    return (box(a) * guide + box(b)).astype(np.float32)


def upsample_disparity(disparity: np.ndarray, image_srgb: np.ndarray) -> np.ndarray:
    """Model-resolution disparity -> working resolution, edge-aware (§R2.1)."""
    h, w = image_srgb.shape[:2]
    upsampled = cv2.resize(disparity.astype(np.float32), (w, h), interpolation=cv2.INTER_LINEAR)
    grey = cv2.cvtColor(image_srgb.astype(np.float32), cv2.COLOR_RGB2GRAY)
    radius = max(2, round(0.006 * max(h, w)))
    return np.clip(guided_filter(grey, upsampled, radius, 1e-3), 0, 1)


def dilate(mask: np.ndarray, radius_px: int) -> np.ndarray:
    if radius_px <= 0:
        return mask
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * radius_px + 1, 2 * radius_px + 1))
    return cv2.dilate(mask.astype(np.float32), kernel)


def erode(mask: np.ndarray, radius_px: int) -> np.ndarray:
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * radius_px + 1, 2 * radius_px + 1))
    return cv2.erode(mask.astype(np.float32), kernel)


@dataclasses.dataclass
class Plane:
    colour_linear: np.ndarray   # HxWx3, not premultiplied
    alpha: np.ndarray           # HxW
    disparity: np.ndarray       # HxW, [0,1], larger = nearer
    name: str


@dataclasses.dataclass
class Scene:
    background: Plane
    subject: Plane | None


def build_scene(image_srgb: np.ndarray, disparity_full: np.ndarray, matte: np.ndarray | None,
                replacement_srgb: np.ndarray | None = None,
                replacement_disparity: np.ndarray | None = None) -> Scene:
    """Decompose the photo into background/subject planes (§R2).

    Replacement placement (§R2.4). The nearest the replacement may come is
    `subject_median - REPLACEMENT_MIN_GAP`, so it always stays behind the subject.
      * replacement_disparity None -> flat plane at the ORIGINAL background's median disparity
        (so swapping the background keeps the blur the user already saw), capped as above.
      * otherwise the replacement's own estimated relative disparity in [0,1] is scaled into
        [0, subject_median - REPLACEMENT_MIN_GAP], keeping its own near/far structure.
    """
    h, w = image_srgb.shape[:2]
    long_side = max(h, w)
    linear = srgb_to_linear(image_srgb)
    if matte is None:
        return Scene(Plane(linear, np.ones((h, w), np.float32), disparity_full, "background"), None)

    matte = np.clip(matte, 0, 1).astype(np.float32)
    # Background colour behind the subject: exclude a band outside the matte, where colours are
    # still mixed with the subject, then fill from the remaining background.
    colour_band = dilate((matte > 0.02).astype(np.float32), round(0.004 * long_side))
    background_colour = fill_masked(linear, 1 - colour_band)
    # Background disparity: the model's depth bleeds across the outline by a few model pixels, so
    # exclude a wider band (~1.5 % of the long side) before filling.
    depth_band = dilate((matte > 0.02).astype(np.float32), round(0.015 * long_side))
    background_disparity = fill_masked(disparity_full, 1 - depth_band)

    # Subject disparity: sample only the eroded interior, fill outwards, then compress towards the
    # median so that the whole subject sits in a narrow band (no sharp face with blurred ears).
    interior = erode((matte > 0.5).astype(np.float32), round(0.01 * long_side))
    if interior.sum() < 50:
        interior = (matte > 0.5).astype(np.float32)
    subject_disparity_raw = fill_masked(disparity_full, interior)
    subject_median = float(np.median(disparity_full[interior > 0.5]))
    subject_disparity = subject_median + SUBJECT_DEPTH_COMPRESSION * (subject_disparity_raw - subject_median)

    # De-contaminated subject colour: solve I = M*F + (1-M)*B for F where the matte is reliable,
    # fall back to a fill from the solid interior where it is not.
    solid = (matte > 0.95).astype(np.float32)
    interior_fill = fill_masked(linear, solid)
    with np.errstate(divide="ignore", invalid="ignore"):
        solved = (linear - (1 - matte[..., None]) * background_colour) / np.maximum(matte[..., None], 1e-3)
    reliability = np.clip((matte - 0.3) / 0.4, 0, 1)[..., None]
    subject_colour = np.clip(reliability * solved + (1 - reliability) * interior_fill, 0, None).astype(np.float32)

    if replacement_srgb is not None:
        background_colour = srgb_to_linear(cover_fit(replacement_srgb, (h, w)))
        nearest_allowed = max(0.0, subject_median - REPLACEMENT_MIN_GAP)
        if replacement_disparity is None:
            original_background_median = float(np.median(disparity_full[depth_band < 0.5])) if (depth_band < 0.5).any() else 0.0
            background_disparity = np.full((h, w), min(original_background_median, nearest_allowed), np.float32)
        else:
            fitted = cover_fit(replacement_disparity[..., None], (h, w))[..., 0]
            background_disparity = (np.clip(fitted, 0, 1) * nearest_allowed).astype(np.float32)

    return Scene(Plane(background_colour, np.ones((h, w), np.float32), background_disparity, "background"),
                 Plane(subject_colour, matte, subject_disparity.astype(np.float32), "subject"))


def cover_fit(image: np.ndarray, shape: tuple[int, int], scale: float = 1.0,
              offset: tuple[float, float] = (0.5, 0.5)) -> np.ndarray:
    """Aspect-fill `image` into `shape` (h, w), then zoom by `scale` around `offset` (prototype Scale)."""
    h, w = shape
    factor = max(h / image.shape[0], w / image.shape[1]) * scale
    resized = cv2.resize(image.astype(np.float32), (math.ceil(image.shape[1] * factor), math.ceil(image.shape[0] * factor)),
                         interpolation=cv2.INTER_AREA)
    if resized.ndim == 2:
        resized = resized[..., None]
    top = int(round((resized.shape[0] - h) * offset[1]))
    left = int(round((resized.shape[1] - w) * offset[0]))
    return resized[top:top + h, left:left + w]


# ------------------------------------------------------------------------- focus selection (§R3)

def focal_disparity(scene: Scene, target_x: float, target_y: float) -> float:
    """Disparity under the tap: weighted median over a small window of the topmost plane there."""
    h, w = scene.background.disparity.shape
    cx, cy = int(np.clip(target_x, 0, 1) * (w - 1)), int(np.clip(target_y, 0, 1) * (h - 1))
    on_subject = scene.subject is not None and scene.subject.alpha[cy, cx] >= 0.5
    disparity = scene.subject.disparity if on_subject else scene.background.disparity
    radius = max(2, round(0.01 * max(h, w)))
    window = disparity[max(0, cy - radius):cy + radius + 1, max(0, cx - radius):cx + radius + 1]
    return float(np.median(window))


def signed_coc(disparity: np.ndarray, focal: float, half_width: float, radius_max: float) -> np.ndarray:
    """Signed circle of confusion in px (§R4): >0 in front of the focal band, <0 behind it.

    CoC of a thin lens is proportional to |1/z - 1/z_f| = |disparity - focal|; the dead band of
    +-half_width is the depth of field the "Focus depth" slider controls.
    """
    delta = disparity - focal
    magnitude = np.maximum(np.abs(delta) - half_width, 0) / max(1 - half_width, 1e-6)
    return (np.sign(delta) * np.clip(magnitude, 0, 1) * radius_max).astype(np.float32)


# ------------------------------------------------------------------------------- kernels (§R5)

def _supersampled_grid(radius: float, extent: float = 1.0, supersample: int = 4):
    size = int(math.ceil(radius * extent)) * 2 + 1
    steps = (np.arange(size * supersample) + 0.5) / supersample - size / 2
    xs, ys = np.meshgrid(steps / radius, -steps / radius)  # y up, unit = radius
    return size, supersample, xs, ys


def _polygon_inside(xs, ys, vertices) -> np.ndarray:
    inside = np.ones_like(xs, dtype=bool)
    n = len(vertices)
    for i in range(n):
        (x0, y0), (x1, y1) = vertices[i], vertices[(i + 1) % n]
        inside &= (x1 - x0) * (ys - y0) - (y1 - y0) * (xs - x0) >= 0
    return inside


def _star_inside(xs, ys, points=5, inner=0.45) -> np.ndarray:
    angle = np.arctan2(ys, xs) - math.pi / 2
    sector = 2 * math.pi / points
    local = np.mod(angle + sector / 2, sector) - sector / 2       # angle within one point's sector
    radius = np.hypot(xs, ys)
    # Edge from the tip (r=1, local=0) to the inner vertex (r=inner, local=sector/2), in polar form.
    tip = np.array([1.0, 0.0])
    valley = inner * np.array([math.cos(sector / 2), math.sin(sector / 2)])
    px, py = radius * np.cos(np.abs(local)), radius * np.sin(np.abs(local))
    cross = (valley[0] - tip[0]) * (py - tip[1]) - (valley[1] - tip[1]) * (px - tip[0])
    return cross <= 0


def bokeh_kernel(shape: str, radius: float) -> np.ndarray:
    """Normalised aperture kernel whose circumscribed radius is `radius` px, anti-aliased."""
    if radius < 0.5:
        return np.ones((1, 1), np.float32)
    size, ss, xs, ys = _supersampled_grid(radius)
    if shape == "round":
        inside = xs ** 2 + ys ** 2 <= 1
    elif shape == "hex":
        vertices = [(math.cos(math.radians(a)), math.sin(math.radians(a))) for a in range(0, 360, 60)]
        inside = _polygon_inside(xs, ys, vertices)
    elif shape == "heart":
        # Classic implicit heart, rescaled so its extent fits the unit circle.
        hx, hy = xs * 1.25, ys * 1.25 + 0.15
        inside = (hx ** 2 + hy ** 2 - 1) ** 3 - hx ** 2 * hy ** 3 <= 0
    elif shape == "star":
        inside = _star_inside(xs, ys)
    else:
        raise ValueError(shape)
    kernel = inside.reshape(size, ss, size, ss).mean(axis=(1, 3)).astype(np.float32)
    return kernel / kernel.sum()


def gaussian_kernel(radius: float) -> np.ndarray:
    """Soft style: Gaussian with sigma = radius / 2, truncated at 1.5 radius."""
    if radius < 0.5:
        return np.ones((1, 1), np.float32)
    half = int(math.ceil(radius * 1.5))
    axis = np.arange(-half, half + 1, dtype=np.float32)
    g = np.exp(-0.5 * (axis / (radius / 2)) ** 2)
    kernel = np.outer(g, g)
    return (kernel / kernel.sum()).astype(np.float32)


def motion_kernel(radius: float, direction_degrees: float) -> np.ndarray:
    """Motion style: 1 px wide anti-aliased streak of total length 3 x radius at the given angle."""
    if radius < 0.5:
        return np.ones((1, 1), np.float32)
    half_length = 1.5 * radius
    size, ss, xs, ys = _supersampled_grid(radius, extent=1.5)
    xs, ys = xs * radius, ys * radius  # back to px
    theta = math.radians(direction_degrees)
    along = xs * math.cos(theta) + ys * math.sin(theta)
    across = -xs * math.sin(theta) + ys * math.cos(theta)
    inside = (np.abs(along) <= half_length) & (np.abs(across) <= 0.5)
    kernel = inside.reshape(size, ss, size, ss).mean(axis=(1, 3)).astype(np.float32)
    return kernel / kernel.sum()


def convolve(stack: np.ndarray, kernel: np.ndarray) -> np.ndarray:
    """'same' convolution of HxWxC with a 2-D kernel via FFT, reflect-padded borders."""
    if kernel.shape == (1, 1):
        return stack
    pad_y, pad_x = kernel.shape[0] // 2, kernel.shape[1] // 2
    padded = np.pad(stack, ((pad_y, pad_y), (pad_x, pad_x), (0, 0)), mode="reflect")
    fft_shape = (padded.shape[0] + kernel.shape[0] - 1, padded.shape[1] + kernel.shape[1] - 1)
    spectrum = scipy.fft.rfft2(padded, s=fft_shape, axes=(0, 1), workers=4)
    kernel_spectrum = scipy.fft.rfft2(kernel, s=fft_shape, workers=4)
    full = scipy.fft.irfft2(spectrum * kernel_spectrum[..., None], s=fft_shape, axes=(0, 1), workers=4)
    top, left = 2 * pad_y, 2 * pad_x
    return full[top:top + stack.shape[0], left:left + stack.shape[1]].astype(np.float32)


def rotational_blur(stack: np.ndarray, half_angle: float, centre: tuple[float, float]) -> np.ndarray:
    """Average of copies rotated about `centre` by angles in [-half_angle, +half_angle] (radians)."""
    h, w = stack.shape[:2]
    arc_px = half_angle * math.hypot(w, h) / 2
    samples = int(np.clip(math.ceil(arc_px / 1.5) * 2 + 1, 3, 49))
    accumulated = np.zeros_like(stack)
    for angle in np.linspace(-half_angle, half_angle, samples):
        matrix = cv2.getRotationMatrix2D(centre, math.degrees(angle), 1.0)
        rotated = cv2.warpAffine(stack, matrix, (w, h), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)
        accumulated += rotated.reshape(stack.shape)
    return accumulated / samples


def blur_layer(stack: np.ndarray, radius: float, params: FocusBlurParams, radius_max: float) -> np.ndarray:
    if radius < 0.5:
        return stack
    if params.style == "lens":
        return convolve(stack, bokeh_kernel(params.bokeh, radius))
    if params.style == "soft":
        return convolve(stack, gaussian_kernel(radius))
    if params.style == "motion":
        return convolve(stack, motion_kernel(radius, params.style_amount * 3.6 - 180))
    if params.style == "swirl":
        # Swirl (§R5.3): a smaller disc plus a rotation about the image centre whose angle grows
        # with CoC, so streaks are tangential and lengthen towards the frame edge (Helios-like).
        amount = params.style_amount / 100.0
        disc = convolve(stack, bokeh_kernel("round", radius * (1 - 0.5 * amount)))
        h, w = stack.shape[:2]
        half_angle = 1.5 * radius * amount / (0.5 * math.hypot(w, h)) * 4
        return rotational_blur(disc, half_angle, ((w - 1) / 2, (h - 1) / 2))
    raise ValueError(params.style)


# ---------------------------------------------------------------------------- compositing (§R6)

def render(scene: Scene, params: FocusBlurParams, focal_override: float | None = None) -> tuple[np.ndarray, dict]:
    """Render the refocused image (sRGB float HxWx3) and diagnostics (focal disparity, CoC map).

    focal_override is for experiments only (e.g. rendering a background plane alone at the focal
    disparity of a tap that landed on the subject); the apps always derive it from the tap (§R3).
    """
    h, w = scene.background.disparity.shape
    radius_max = max_coc_radius_px(params.blur, max(h, w))
    half_width = focus_half_width(params.focus_depth)
    focal = focal_override if focal_override is not None else focal_disparity(scene, params.target_x, params.target_y)
    use_highlights = params.style in ("lens", "swirl", "motion")

    planes = [scene.background] + ([scene.subject] if scene.subject is not None else [])
    layer_step = radius_max / LAYERS_PER_SIDE if radius_max > 0 else 1.0
    behind_layers: list[tuple[int, int, np.ndarray]] = []
    # Per plane: additive sum of the focal and in-front layers (premultiplied colour + alpha).
    front_sums = [np.zeros((h, w, 4), np.float32) for _ in planes]
    coc_maps = []

    for plane_index, plane in enumerate(planes):
        colour = expand_highlights(plane.colour_linear) if use_highlights else plane.colour_linear
        coc = signed_coc(plane.disparity, focal, half_width, radius_max)
        coc_maps.append(coc)
        layer_position = coc / layer_step  # continuous signed layer index
        for layer in range(-LAYERS_PER_SIDE, LAYERS_PER_SIDE + 1):
            # Tent membership between adjacent layers avoids visible steps in blur (§R4).
            weight = np.maximum(0, 1 - np.abs(layer_position - layer)) * plane.alpha
            if weight.max() < 1e-4:
                continue
            premultiplied = np.concatenate([colour * weight[..., None], weight[..., None]], axis=2)
            blurred = blur_layer(premultiplied, abs(layer) * layer_step, params, radius_max)
            if layer < 0:
                behind_layers.append((layer, plane_index, blurred))
            else:
                front_sums[plane_index] += blurred

    # (§R6.1-2) Behind the focal band: "over" from far to near (background before subject within a
    # layer), then normalise with pull-push so disocclusions are filled with same-depth colour.
    behind_colour = np.zeros((h, w, 3), np.float32)
    behind_alpha = np.zeros((h, w), np.float32)
    for _, _, blurred in sorted(behind_layers, key=lambda item: (item[0], item[1])):
        behind_colour = blurred[..., :3] + (1 - blurred[..., 3:]) * behind_colour
        behind_alpha = blurred[..., 3] + (1 - blurred[..., 3]) * behind_alpha
    result = pull_push_fill(behind_colour, np.clip(behind_alpha, 0, 1)) if behind_alpha.max() > 0 \
        else np.zeros((h, w, 3), np.float32)

    # (§R6.3-4) Focal + in-front layers of one plane are SUMMED, not "over"-composited: the tent
    # splits one surface across two adjacent layers, and "over" would let 25 % of whatever is behind
    # leak through a split surface (visible as ghost contours inside a blurred foreground). The sum
    # keeps a split surface opaque while its blurred edges still spread and turn semi-transparent.
    # Planes are then layered subject over background.
    # v1 limitation, see doc §R6: background content nearer than the subject blurs *under* the
    # subject's outline rather than over it.
    for front in front_sums:
        coverage = front[..., 3:]
        overflow = np.maximum(coverage, 1.0)
        front_colour, front_alpha = front[..., :3] / overflow, coverage / overflow
        result = front_colour + (1 - front_alpha) * result

    if use_highlights:
        result = compress_highlights(result)
    if params.style == "soft":
        result = add_glow(result, coc_maps, scene, params, radius_max)
    diagnostics = {"focal_disparity": focal, "half_width": half_width, "radius_max_px": radius_max,
                   "coc_background": coc_maps[0]}
    return linear_to_srgb(result), diagnostics


def add_glow(result: np.ndarray, coc_maps, scene: Scene, params: FocusBlurParams, radius_max: float) -> np.ndarray:
    """Soft style glow (§R5.2): diffused highlights, only where the photo is defocused."""
    amount = params.style_amount / 100.0
    if amount <= 0 or radius_max <= 0:
        return result
    defocus = np.abs(coc_maps[0]) / radius_max
    if scene.subject is not None:
        defocus = defocus * (1 - scene.subject.alpha) + np.abs(coc_maps[1]) / radius_max * scene.subject.alpha
    luminance = result @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    bright = result * np.clip((luminance - 0.35) / 0.65, 0, 1)[..., None]
    sigma = max(1.0, 0.6 * radius_max)
    glow = cv2.GaussianBlur(bright, (0, 0), sigma)
    defocus_soft = cv2.GaussianBlur(defocus.astype(np.float32), (0, 0), max(1.0, 0.25 * radius_max))
    # Screen blend keeps glow from clipping whites.
    glow = glow * (0.9 * amount) * defocus_soft[..., None]
    return (1 - (1 - result) * (1 - np.clip(glow, 0, 1))).astype(np.float32)
