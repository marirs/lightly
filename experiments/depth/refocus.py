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
    # None: decided by the tap (M(target) >= 0.5). True for a null recipe target with a subject, which means
    # "focus on the subject" even when the default target (matte centroid) falls outside the matte (§R4).
    subject_focus: bool | None = None


# Constants that both platforms must use (§R3, §R4). Radii are fractions of the image long side.
# Contract fixes 1 (rendering-v2 revision 1, docs/v1/contract-fixes-1.md §1): the maximum radius and the
# depth-of-field slope were re-derived from the approved prototype's bg-* screens. 0.035 and
# 0.30·(focusDepth/100)^1.5 blurred the wall behind the woman at a third of the prototype's strength and
# softened her jacket at the default Focus depth 40.
MAX_COC_FRACTION_OF_LONG_SIDE = 0.06    # blur 100 -> 6 % of the long side, reached at the far end of the depth range
FOCUS_HALF_WIDTH_PER_UNIT = 0.5         # focus depth 100 -> sharp band of +-0.5 disparity (linear in the slider)
LAYERS_PER_SIDE = 8                     # signed CoC quantisation: 8 behind + focal + 8 in front
SUBJECT_DEPTH_COMPRESSION = 0.5         # subject disparity pulled half-way to its median
REPLACEMENT_MIN_GAP = 0.10              # a replacement background stays at least this far behind the subject
HIGHLIGHT_THRESHOLD = 0.70              # linear max-channel value where highlight expansion starts
HIGHLIGHT_GAIN = 0.85                   # expansion strength (1.0 linear maps to 1/(1-0.85) = 6.7)


def focus_half_width(focus_depth: float) -> float:
    return FOCUS_HALF_WIDTH_PER_UNIT * float(np.clip(focus_depth, 0, 100)) / 100.0


def max_coc_radius_px(blur: float, long_side: int) -> float:
    return np.clip(blur, 0, 100) / 100.0 * MAX_COC_FRACTION_OF_LONG_SIDE * long_side


def defocus_range(focal: float) -> float:
    """Disparity distance from the focal plane to the farther end of [0, 1] (§R4): max(d_f, 1 - d_f).

    Normalised disparity always spans [0, 1] (§R2.1), so this is where `blur` reaches R_max. It is one
    scale for both sides of the focal plane, so the ratio of blur between any two depths is the thin-lens
    ratio of their disparity differences; only the overall scale follows the focal plane.
    """
    return max(focal, 1.0 - focal)


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

def _downsample_2x(plane: np.ndarray) -> np.ndarray:
    """Exact 2x2 box mean; an odd last row/column is repeated first (edge padding). Portable by design."""
    h, w = plane.shape[:2]
    if h % 2:
        plane = np.concatenate([plane, plane[-1:]], axis=0)
    if w % 2:
        plane = np.concatenate([plane, plane[:, -1:]], axis=1)
    return 0.25 * (plane[0::2, 0::2] + plane[1::2, 0::2] + plane[0::2, 1::2] + plane[1::2, 1::2])


def _upsample_bilinear(plane: np.ndarray, height: int, width: int) -> np.ndarray:
    """Half-pixel-centre bilinear resize, src = clamp((dst + 0.5)·in/out - 0.5, 0, in - 1), per axis."""
    def axis(out_n, in_n):
        src = np.clip((np.arange(out_n) + 0.5) * in_n / out_n - 0.5, 0, in_n - 1)
        lo = np.floor(src).astype(np.int64)
        return lo, np.minimum(lo + 1, in_n - 1), (src - lo).astype(np.float32)
    y0, y1, fy = axis(height, plane.shape[0])
    x0, x1, fx = axis(width, plane.shape[1])
    fx = fx[None, :, None]
    top = plane[y0][:, x0] * (1 - fx) + plane[y0][:, x1] * fx
    bottom = plane[y1][:, x0] * (1 - fx) + plane[y1][:, x1] * fx
    return top * (1 - fy)[:, None, None] + bottom * fy[:, None, None]


def pull_push_fill(premultiplied: np.ndarray, coverage: np.ndarray) -> np.ndarray:
    """Normalised fill of a partially covered image (§R6, Kraus & Strengert 2007 pull-push).

    `premultiplied` is HxWxC (colour already multiplied by coverage), `coverage` HxW in [0,1].
    Returns HxWxC un-premultiplied colour defined everywhere: where coverage is 1 it is the input,
    where coverage is partial it is normalised, where it is 0 it comes from coarser levels.

    The pyramid is pulled all the way to 1x1 (contract fixes 1, gap G7). The first reference stopped
    when the short side reached 4 px and divided by the coverage there; a cell of that level with no
    coverage stayed 0, so a large disocclusion filled toward black. At 1x1 the only cell holds the
    coverage-weighted mean of the whole plane, so any hole that has covered pixels anywhere is filled
    from them. Only a plane with no coverage at all returns 0.
    """
    colour = premultiplied.astype(np.float32)
    if colour.ndim == 2:
        colour = colour[..., None]
    levels = [(colour, coverage.astype(np.float32))]
    while max(levels[-1][1].shape) > 1:
        colour, alpha = levels[-1]
        down_colour = _downsample_2x(colour)
        down_alpha = _downsample_2x(alpha)
        # Re-normalise coverage per level so a quarter-covered cell becomes fully covered one level up.
        gain = np.minimum(down_alpha * 4.0, 1.0) / np.maximum(down_alpha, 1e-6)
        levels.append((down_colour * gain[..., None], np.minimum(down_alpha * 4.0, 1.0)))
    colour, alpha = levels[-1]
    filled = colour / np.maximum(alpha, 1e-6)[..., None]
    for colour, alpha in reversed(levels[:-1]):
        h, w = alpha.shape
        upsampled = _upsample_bilinear(filled, h, w)
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


# ---------------------------------------------------------------- background.replace (rendering-v2 revision 5)
# The subject's colour where the matte is soft (hair, fur, motion edges) is a mix of subject and old background.
# Compositing the observed pixel over a replacement keeps the old background's colour there (red wall through hair).
# Revision 5 composites the estimated foreground F instead: Germer et al., "Fast multi-level foreground estimation"
# (2020), as in pymatting's estimate_foreground_ml (MIT): regularisation 1e-5, gradient weight 1, 10 iterations on
# levels up to 32 px, 2 above, nearest-neighbour level resizing, Gauss-Seidel updates in row-major order.
FOREGROUND_REGULARIZATION = 1e-5
FOREGROUND_GRADIENT_WEIGHT = 1.0
FOREGROUND_SMALL_ITERATIONS = 10
FOREGROUND_BIG_ITERATIONS = 2
FOREGROUND_SMALL_SIZE = 32


def _resize_nearest(src: np.ndarray, height: int, width: int) -> np.ndarray:
    h, w = src.shape[:2]
    ys = np.clip(np.arange(height) * h // height, 0, h - 1)
    xs = np.clip(np.arange(width) * w // width, 0, w - 1)
    return src[ys][:, xs].copy()


def estimate_foreground(image: np.ndarray, alpha: np.ndarray) -> np.ndarray:
    """Foreground colour F (H x W x 3, linear, clipped to [0, 1]) of `image` (linear) given `alpha`, in float32."""
    image = np.asarray(image, np.float32)
    alpha = np.asarray(alpha, np.float32)
    h0, w0, depth = image.shape
    f_mean = image[alpha > 0.9].sum(0) / np.float32((alpha > 0.9).sum() + 1e-5)
    b_mean = image[alpha < 0.1].sum(0) / np.float32((alpha < 0.1).sum() + 1e-5)
    f_prev = np.zeros((1, 1, depth), np.float32) + f_mean.astype(np.float32)
    b_prev = np.zeros((1, 1, depth), np.float32) + b_mean.astype(np.float32)
    levels = int(math.ceil(math.log2(max(w0, h0))))
    reg, gw = np.float32(FOREGROUND_REGULARIZATION), np.float32(FOREGROUND_GRADIENT_WEIGHT)
    for level in range(levels + 1):
        w = round(w0 ** (level / levels)); h = round(h0 ** (level / levels))
        img = _resize_nearest(image, h, w); a_ = _resize_nearest(alpha, h, w)
        f = _resize_nearest(f_prev, h, w); b = _resize_nearest(b_prev, h, w)
        iterations = FOREGROUND_SMALL_ITERATIONS if (w <= FOREGROUND_SMALL_SIZE and h <= FOREGROUND_SMALL_SIZE) else FOREGROUND_BIG_ITERATIONS
        for _ in range(iterations):
            for y in range(h):
                for x in range(w):
                    a0 = a_[y, x]; a1 = np.float32(1) - a0
                    a00, a01, a11 = a0 * a0, a0 * a1, a1 * a1
                    bf = a0 * img[y, x].copy(); bb = a1 * img[y, x].copy()
                    for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                        x2 = min(max(x + dx, 0), w - 1); y2 = min(max(y + dy, 0), h - 1)
                        da = reg + gw * abs(a0 - a_[y2, x2])
                        a00 += da; a11 += da
                        bf = bf + da * f[y2, x2]; bb = bb + da * b[y2, x2]
                    inv = np.float32(1) / (a00 * a11 - a01 * a01)
                    f[y, x] = np.clip(inv * a11 * bf - inv * a01 * bb, 0, 1)
                    b[y, x] = np.clip(-inv * a01 * bf + inv * a00 * bb, 0, 1)
        f_prev, b_prev = f, b
    return f_prev


def replace_composite(image: np.ndarray, alpha: np.ndarray, replacement: np.ndarray, foreground: np.ndarray | None = None) -> np.ndarray:
    """background.replace without blur, linear RGB: F * a + R * (1 - a), F = estimate_foreground(image, alpha)."""
    a = np.clip(alpha, 0, 1)[..., None]
    f = estimate_foreground(image, alpha) if foreground is None else foreground
    return f * a + replacement * (1 - a)


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
    # Revision 3: the solved colour wherever the matte is above 0.02, clipped to [0, 1]. Revisions 1-2
    # used the interior fill below matte 0.3; where a soft matte tail extends past the subject over a
    # different background, that painted the subject's colour there (a red glow beside a red shirt over
    # a dark wall, 10-20 px wide at 12 MP). The solved colour reproduces the photo there instead.
    reliability = (matte > 0.02).astype(np.float32)[..., None]
    subject_colour = np.clip(reliability * np.clip(solved, 0, 1) + (1 - reliability) * interior_fill, 0, None).astype(np.float32)

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

def _tap_pixel(scene: Scene, target_x: float, target_y: float) -> tuple[int, int]:
    h, w = scene.background.disparity.shape
    return int(np.clip(target_x, 0, 1) * (w - 1)), int(np.clip(target_y, 0, 1) * (h - 1))


def focus_is_on_subject(scene: Scene, target_x: float, target_y: float) -> bool:
    """True when the tap lands on the subject plane (M(tap) >= 0.5), the topmost plane there (§R3)."""
    cx, cy = _tap_pixel(scene, target_x, target_y)
    return scene.subject is not None and bool(scene.subject.alpha[cy, cx] >= 0.5)


def focal_disparity(scene: Scene, target_x: float, target_y: float) -> float:
    """Disparity under the tap: weighted median over a small window of the topmost plane there."""
    h, w = scene.background.disparity.shape
    cx, cy = _tap_pixel(scene, target_x, target_y)
    on_subject = focus_is_on_subject(scene, target_x, target_y)
    disparity = scene.subject.disparity if on_subject else scene.background.disparity
    radius = max(2, round(0.01 * max(h, w)))
    window = disparity[max(0, cy - radius):cy + radius + 1, max(0, cx - radius):cx + radius + 1]
    return float(np.median(window))


def signed_coc(disparity: np.ndarray, focal: float, half_width: float, radius_max: float) -> np.ndarray:
    """Signed circle of confusion in px (§R4): >0 in front of the focal band, <0 behind it.

    CoC of a thin lens is proportional to |1/z - 1/z_f| = |disparity - focal|; the dead band of
    +-half_width is the depth of field the "Focus depth" slider controls. The distance is scaled by
    `defocus_range(focal) - half_width`, so the farthest depth from the focal plane gets `radius_max`
    whatever the tap: Blur means "how blurred the farthest content is", as in the approved prototype,
    while the falloff between the band and that point stays linear in real disparity.
    """
    delta = disparity - focal
    span = max(defocus_range(focal) - half_width, 1e-6)
    magnitude = np.maximum(np.abs(delta) - half_width, 0) / span
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

    focal_override: the focal disparity when the edit stored it. The recipe stores depth (0 near), so the
    apps pass `1 - depth.focusDepth` when it is not null, and leave this None to resolve the tap with §R3
    (rendering-v2.md §7.1, contract fixes 1 gap G4). Whether the subject is in focus is still decided by
    the tap (M(target) >= 0.5).
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

    # Contract fixes 1 (§R4): focusing on the subject keeps the whole subject plane sharp, as the approved
    # prototype shows it. Without this an arm or shoulder nearer than the face fell outside the band at the
    # default Focus depth and blurred visibly. Depth still shapes everything in the background plane.
    if params.subject_focus is None:
        subject_in_focus = scene.subject is not None and focus_is_on_subject(scene, params.target_x, params.target_y)
    else:
        subject_in_focus = scene.subject is not None and params.subject_focus
    for plane_index, plane in enumerate(planes):
        colour = expand_highlights(plane.colour_linear) if use_highlights else plane.colour_linear
        if plane_index == 1 and subject_in_focus:
            coc = np.zeros_like(plane.disparity, dtype=np.float32)
        else:
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
