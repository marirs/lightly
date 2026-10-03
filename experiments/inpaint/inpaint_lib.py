"""Shared helpers for the Edit > Remove inpainting evaluation.

Everything here is experiment code: nothing is linked into ios/ or android/.

Conventions (kept identical across every candidate so the comparison is fair):
  * Images are uint8 RGB numpy arrays (H, W, 3) at full resolution.
  * Masks are uint8 (H, W) with 255 = "remove this pixel" (the user's brush), 0 = keep.
    MI-GAN's own convention is the inverse (255 = known); the adapters below convert.
  * The app-shaped pipeline is: crop a square context window around the mask, resize it to the
    model's fixed input (512), inpaint, resize back, and paste ONLY the masked pixels (with a
    small feather) into the untouched full-resolution original. Pixels outside the brush are
    never altered, so preview and export can share one cached patch.
"""
from __future__ import annotations

import json
import math
import time
import sys
import types
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

EXPERIMENT_ROOT = Path(__file__).resolve().parent
REPO_ROOT = EXPERIMENT_ROOT.parent.parent
MODELS_DIR = EXPERIMENT_ROOT / "models"
UPSTREAM_DIR = EXPERIMENT_ROOT / "upstream"
MODEL_INPUT_SIDE = 512

# --------------------------------------------------------------------------------------------
# Cases and masks
# --------------------------------------------------------------------------------------------


@dataclass
class RemovalCase:
    case_id: str
    title: str
    photo_path: Path
    shapes: list
    dilate_px: int
    category: str


def load_cases(cases_path: Path = EXPERIMENT_ROOT / "cases.json") -> list[RemovalCase]:
    raw_cases = json.loads(cases_path.read_text())
    return [
        RemovalCase(
            case_id=entry["id"],
            title=entry["title"],
            photo_path=REPO_ROOT / entry["photo"],
            shapes=entry["shapes"],
            dilate_px=entry.get("dilate_px", 0),
            category=entry["category"],
        )
        for entry in raw_cases["cases"]
    ]


def rasterise_mask(case: RemovalCase, width: int, height: int) -> np.ndarray:
    """Turn the case's brush description (normalised coords) into a full-res 0/255 mask.

    Shapes mimic what a finger brush produces: round dabs, thick polylines, filled lassos.
    Widths/radii are in full-resolution pixels so they mean the same thing on every photo.
    """
    mask_image = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(mask_image)

    def to_px(point):
        return (point[0] * width, point[1] * height)

    for shape in case.shapes:
        kind = shape["kind"]
        if kind == "circle":
            cx, cy = to_px(shape["center"])
            radius = shape["radius_px"]
            draw.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=255)
        elif kind == "polyline":
            points = [to_px(p) for p in shape["points"]]
            stroke_width = shape["width_px"]
            draw.line(points, fill=255, width=stroke_width, joint="curve")
            for px, py in (points[0], points[-1]):  # round caps, like a real brush
                draw.ellipse([px - stroke_width / 2, py - stroke_width / 2,
                              px + stroke_width / 2, py + stroke_width / 2], fill=255)
        elif kind == "polygon":
            draw.polygon([to_px(p) for p in shape["points"]], fill=255)
        else:
            raise ValueError(f"unknown shape kind {kind!r} in case {case.case_id}")

    if case.dilate_px > 0:
        # Grows the brush the way the app's "auto-expand edge" would.
        return dilate_disc(np.array(mask_image), case.dilate_px)
    return np.array(mask_image)


def dilate_disc(mask: np.ndarray, radius_px: int) -> np.ndarray:
    import cv2

    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * radius_px + 1, 2 * radius_px + 1))
    return cv2.dilate(mask, kernel)


def mask_bbox(mask: np.ndarray) -> tuple[int, int, int, int]:
    ys, xs = np.nonzero(mask)
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def stroke_extent_px(mask: np.ndarray) -> int:
    """Longest side of the mask's bounding box: the size measure used for routing decisions."""
    x0, y0, x1, y1 = mask_bbox(mask)
    return max(x1 - x0, y1 - y0)


# --------------------------------------------------------------------------------------------
# Crop / paste-back (the part both apps would implement natively)
# --------------------------------------------------------------------------------------------


@dataclass
class CropWindow:
    x0: int
    y0: int
    side: int  # square window side in full-res pixels


def context_window(mask: np.ndarray, context_factor: float = 2.2,
                   min_side: int = MODEL_INPUT_SIDE) -> CropWindow:
    """Square window centred on the mask, ~context_factor x the mask extent, clamped to image.

    min_side = 512 means small strokes are inpainted at native resolution (no resampling at all);
    only strokes whose context exceeds 512 px are downscaled into the model.
    """
    height, width = mask.shape
    x0, y0, x1, y1 = mask_bbox(mask)
    side = int(math.ceil(max(x1 - x0, y1 - y0) * context_factor))
    side = max(side, min_side)
    side = min(side, width, height)
    centre_x, centre_y = (x0 + x1) / 2, (y0 + y1) / 2
    left = int(round(min(max(centre_x - side / 2, 0), width - side)))
    top = int(round(min(max(centre_y - side / 2, 0), height - side)))
    return CropWindow(left, top, side)


def feathered_alpha(mask_crop: np.ndarray, feather_px: int) -> np.ndarray:
    """0..1 alpha that is 1 inside the brush and ramps to 0 just OUTSIDE it.

    The ramp lives outside the brush so the object never bleeds back through the blend.
    """
    grown = Image.fromarray(dilate_disc(mask_crop, feather_px))
    blurred = grown.filter(ImageFilter.GaussianBlur(feather_px / 2))
    alpha = np.asarray(blurred, dtype=np.float32) / 255.0
    alpha = np.maximum(alpha, (mask_crop > 0).astype(np.float32))
    return alpha[..., None]


class Inpainter:
    """Model adapter interface: takes a square uint8 crop and 0/255 hole mask at model res."""

    name = "base"
    fixed_side: int | None = MODEL_INPUT_SIDE  # None = works at the crop's native resolution
    max_side: int = 1 << 30  # cap for free-resolution models (None fixed_side)

    def inpaint(self, image_rgb: np.ndarray, hole_mask: np.ndarray) -> np.ndarray:
        raise NotImplementedError


def remove_with_paste_back(inpainter: Inpainter, image_rgb: np.ndarray, hole_mask: np.ndarray,
                           context_factor: float = 2.2, feather_px: int = 3) -> tuple[np.ndarray, dict]:
    """App-shaped pipeline. Returns the full-res result and timing/geometry info."""

    window = context_window(hole_mask, context_factor)
    crop_slice = (slice(window.y0, window.y0 + window.side), slice(window.x0, window.x0 + window.side))
    image_crop = image_rgb[crop_slice]
    mask_crop = hole_mask[crop_slice]

    # fixed_side models always get exactly that side; free-resolution models are capped at max_side.
    model_side = inpainter.fixed_side or min(window.side, inpainter.max_side)
    resampled = model_side != window.side
    if resampled:
        model_image = np.array(Image.fromarray(image_crop).resize((model_side, model_side), Image.BICUBIC))
        # Grow the hole slightly when downscaling so no object edge survives the resample.
        model_mask = np.array(Image.fromarray(mask_crop).resize((model_side, model_side), Image.BILINEAR))
        model_mask = np.where(model_mask > 0, 255, 0).astype(np.uint8)
    else:
        model_image, model_mask = image_crop, mask_crop

    started = time.perf_counter()
    model_output = inpainter.inpaint(model_image, model_mask)
    inference_seconds = time.perf_counter() - started

    if resampled:
        model_output = np.array(Image.fromarray(model_output).resize((window.side, window.side), Image.BICUBIC))

    alpha = feathered_alpha(mask_crop, feather_px)
    blended_crop = image_crop.astype(np.float32) * (1 - alpha) + model_output.astype(np.float32) * alpha
    result = image_rgb.copy()
    result[crop_slice] = np.clip(blended_crop + 0.5, 0, 255).astype(np.uint8)
    info = {
        "window": [window.x0, window.y0, window.side],
        "model_side": model_side,
        "resampled": resampled,
        "scale": window.side / model_side,
        "inference_s": inference_seconds,
    }
    return result, info


THIN_STROKE_MAX_THICKNESS_PX = 64  # strokes thinner than this are tiled at native resolution
TILE_STRIDE_PX = 384  # 512 tiles with 128 px overlap so each tile sees already-filled context


@dataclass
class StrokeJob:
    """One unit of work the app would schedule: a connected stroke and how it will be processed."""

    mask: np.ndarray  # full-res 0/255 mask of just this stroke
    extent_px: int
    thickness_px: int
    route: str  # "native" | "tiled-native" | "downscaled"


def plan_stroke_jobs(hole_mask: np.ndarray, merge_gap_px: int = 24) -> list[StrokeJob]:
    """Split the brush into strokes and pick a processing route per stroke.

    Routing is deterministic and visible (the app can show it): it only decides HOW the same
    model is fed, never WHICH algorithm runs. Algorithm choice (model vs classical) is a separate,
    explicit user-facing decision; see docs/v1/remove-evaluation.md.
    """
    import cv2

    # Merge strokes that nearly touch so one object brushed in two dabs is filled together.
    merged = cv2.dilate(hole_mask, np.ones((merge_gap_px, merge_gap_px), np.uint8))
    component_count, labels = cv2.connectedComponents((merged > 0).astype(np.uint8))
    jobs = []
    for component_index in range(1, component_count):
        stroke_mask = np.where((labels == component_index) & (hole_mask > 0), 255, 0).astype(np.uint8)
        if not stroke_mask.any():
            continue
        extent = stroke_extent_px(stroke_mask)
        thickness = int(round(2 * cv2.distanceTransform(stroke_mask, cv2.DIST_L2, 5).max()))
        if extent * 2.2 <= MODEL_INPUT_SIDE:
            route = "native"
        elif thickness <= THIN_STROKE_MAX_THICKNESS_PX:
            route = "tiled-native"
        else:
            route = "downscaled"
        jobs.append(StrokeJob(stroke_mask, extent, thickness, route))
    return jobs


def _tile_origins(start: int, stop: int, limit: int, side: int) -> list[int]:
    """Tile origins (1-D) covering [start, stop) with `side` tiles, clamped to [0, limit - side]."""
    first = max(0, min(start - (side - TILE_STRIDE_PX) // 2, limit - side))
    origins = [first]
    while origins[-1] + side < min(stop + (side - TILE_STRIDE_PX) // 2, limit):
        origins.append(min(origins[-1] + TILE_STRIDE_PX, limit - side))
        if origins[-1] == limit - side:
            break
    return origins


def remove_tiled_native(inpainter: Inpainter, image_rgb: np.ndarray, stroke_mask: np.ndarray,
                        feather_px: int = 3) -> tuple[np.ndarray, dict]:
    """Long thin strokes (wires, cracks): 512 tiles at native res walked along the stroke."""
    side = inpainter.fixed_side or MODEL_INPUT_SIDE
    height, width = stroke_mask.shape
    x0, y0, x1, y1 = mask_bbox(stroke_mask)
    result = image_rgb.copy()
    remaining = stroke_mask.copy()
    inference_seconds, tiles_run = 0.0, 0
    for tile_y in _tile_origins(y0, y1, height, side):
        for tile_x in _tile_origins(x0, x1, width, side):
            tile_slice = (slice(tile_y, tile_y + side), slice(tile_x, tile_x + side))
            # Each tile fills every still-unfilled stroke pixel it contains; tiles overlap by 128 px
            # and run in order, so later tiles use earlier fills as context (no seams to blend).
            owned = remaining[tile_slice].copy()
            if not owned.any():
                continue
            tile_image = result[tile_slice]
            started = time.perf_counter()
            fill = inpainter.inpaint(np.ascontiguousarray(tile_image), owned)
            inference_seconds += time.perf_counter() - started
            tiles_run += 1
            alpha = feathered_alpha(owned, feather_px)
            blended = tile_image.astype(np.float32) * (1 - alpha) + fill.astype(np.float32) * alpha
            result[tile_slice] = np.clip(blended + 0.5, 0, 255).astype(np.uint8)
            remaining[tile_slice] = 0
    return result, {"tiles": tiles_run, "inference_s": inference_seconds, "model_side": side,
                    "resampled": False, "scale": 1.0}


def remove_strokes(inpainter: Inpainter, image_rgb: np.ndarray, hole_mask: np.ndarray) -> tuple[np.ndarray, dict]:
    """Full app-shaped removal: per-stroke jobs, run sequentially, each pasted into the result."""
    result = image_rgb
    job_infos = []
    for job in plan_stroke_jobs(hole_mask):
        if job.route == "tiled-native":
            result, info = remove_tiled_native(inpainter, result, job.mask)
        else:
            result, info = remove_with_paste_back(inpainter, result, job.mask)
        info.update({"route": job.route, "extent_px": job.extent_px, "thickness_px": job.thickness_px})
        job_infos.append(info)
    return result, {"jobs": job_infos, "inference_s": sum(info["inference_s"] for info in job_infos)}


# --------------------------------------------------------------------------------------------
# LaMa (big-lama, Apache-2.0 code + Apache-2.0 weights, Places2-trained)
# --------------------------------------------------------------------------------------------


def _stub_lama_training_only_imports() -> None:
    """saicinpainting imports kornia + pytorch_lightning for training-only paths.

    The generator never calls them; stubbing keeps the eval env small and avoids pinning those libs.
    """
    if "pytorch_lightning" not in sys.modules:
        lightning_stub = types.ModuleType("pytorch_lightning")
        lightning_stub.seed_everything = lambda *args, **kwargs: None
        sys.modules["pytorch_lightning"] = lightning_stub
    for module_name in ("kornia", "kornia.geometry", "kornia.geometry.transform"):
        if module_name not in sys.modules:
            sys.modules[module_name] = types.ModuleType(module_name)
    sys.modules["kornia.geometry.transform"].rotate = None


def _lama_generator_state_path() -> Path:
    """Extract the generator weights from the Lightning checkpoint once into a plain state dict.

    best.ckpt also pickles pytorch_lightning callback objects, which we deliberately do not
    install; a permissive unpickler replaces those classes with inert placeholders. The result
    (generator only, no discriminator/optimiser state) loads with weights_only=True everywhere.
    """
    import pickle

    import torch

    state_path = MODELS_DIR / "big-lama" / "generator_state.pt"
    if state_path.exists():
        return state_path

    class _Placeholder:
        def __init__(self, *args, **kwargs):
            pass

        def __setstate__(self, state):
            pass

    class _PermissiveUnpickler(pickle.Unpickler):
        def find_class(self, module_name, class_name):
            try:
                return super().find_class(module_name, class_name)
            except (ModuleNotFoundError, AttributeError):
                return _Placeholder

    permissive_pickle = types.ModuleType("permissive_pickle")
    permissive_pickle.Unpickler = _PermissiveUnpickler
    permissive_pickle.load = pickle.load
    checkpoint = torch.load(MODELS_DIR / "big-lama" / "models" / "best.ckpt", map_location="cpu",
                            weights_only=False, pickle_module=permissive_pickle)
    generator_state = {key[len("generator."):]: value for key, value in checkpoint["state_dict"].items()
                       if key.startswith("generator.")}
    torch.save(generator_state, state_path)
    return state_path


def build_lama_generator():
    import torch
    from omegaconf import OmegaConf

    _stub_lama_training_only_imports()
    lama_code = str(UPSTREAM_DIR / "lama")
    if lama_code not in sys.path:
        sys.path.insert(0, lama_code)
    from saicinpainting.training.modules.ffc import FFCResNetGenerator

    config = OmegaConf.load(MODELS_DIR / "big-lama" / "config.yaml")
    generator_kwargs = OmegaConf.to_container(config.generator, resolve=True)
    generator_kwargs.pop("kind")
    generator = FFCResNetGenerator(**generator_kwargs)
    generator.load_state_dict(torch.load(_lama_generator_state_path(), map_location="cpu", weights_only=True))
    generator.eval()
    return generator


class LamaInpainter(Inpainter):
    name = "lama"

    def __init__(self, fixed_side: int | None = MODEL_INPUT_SIDE, max_side: int = MODEL_INPUT_SIDE):
        """fixed_side=512 mirrors a fixed-shape Core ML / TFLite export; fixed_side=None with
        max_side=1024 is the resolution-flexible variant (LaMa generalises to higher res)."""
        import torch

        self.torch = torch
        self.generator = build_lama_generator()
        self.fixed_side = fixed_side
        self.max_side = max_side
        if fixed_side is None:
            self.name = f"lama_flex{max_side}"

    def inpaint(self, image_rgb, hole_mask):
        torch = self.torch
        height, width = hole_mask.shape
        pad_h, pad_w = (-height) % 8, (-width) % 8  # FFC down/up-sampling needs multiples of 8
        image = torch.from_numpy(image_rgb).permute(2, 0, 1)[None].float() / 255.0
        mask = torch.from_numpy((hole_mask > 0).astype(np.float32))[None, None]
        if pad_h or pad_w:
            image = torch.nn.functional.pad(image, (0, pad_w, 0, pad_h), mode="reflect")
            mask = torch.nn.functional.pad(mask, (0, pad_w, 0, pad_h), mode="reflect")
        with torch.inference_mode():
            network_input = torch.cat([image * (1 - mask), mask], dim=1)
            output = self.generator(network_input)[0, :, :height, :width]
        return (output.permute(1, 2, 0).clamp(0, 1).numpy() * 255 + 0.5).astype(np.uint8)


# --------------------------------------------------------------------------------------------
# MI-GAN (MIT code + MIT weights per LICENSE-WEIGHTS, Places2-trained, 512 model)
# --------------------------------------------------------------------------------------------


def build_migan_generator(resolution: int = 512):
    import torch

    migan_code = str(UPSTREAM_DIR / "MI-GAN")
    if migan_code not in sys.path:
        sys.path.insert(0, migan_code)
    from lib.model_zoo.migan_inference import Generator

    generator = Generator(resolution=resolution)
    weights_path = MODELS_DIR / "migan_gdrive" / f"migan_{resolution}_places2.pt"
    generator.load_state_dict(torch.load(weights_path, map_location="cpu", weights_only=True))
    generator.eval()
    return generator


class MiganInpainter(Inpainter):
    name = "migan"
    fixed_side = MODEL_INPUT_SIDE  # MI-GAN is a fixed-resolution network (no resolution freedom)

    def __init__(self):
        import torch

        self.torch = torch
        self.generator = build_migan_generator(MODEL_INPUT_SIDE)

    def inpaint(self, image_rgb, hole_mask):
        torch = self.torch
        known = torch.from_numpy((hole_mask == 0).astype(np.float32))[None, None]
        image = torch.from_numpy(image_rgb).permute(2, 0, 1)[None].float() * 2 / 255 - 1
        with torch.inference_mode():
            network_input = torch.cat([known - 0.5, image * known], dim=1)
            output = self.generator(network_input)[0]
        output = (output * 0.5 + 0.5).clamp(0, 1)
        return (output.permute(1, 2, 0).numpy() * 255 + 0.5).astype(np.uint8)


# --------------------------------------------------------------------------------------------
# Classical baselines (OpenCV, Apache-2.0). Native resolution, no model.
# --------------------------------------------------------------------------------------------


class OpenCvTeleaInpainter(Inpainter):
    """Fast-marching diffusion (Telea 2004). Fine for specks; smears anything with structure."""

    name = "telea"
    fixed_side = None

    def inpaint(self, image_rgb, hole_mask):
        import cv2

        return cv2.inpaint(image_rgb, hole_mask, 5, cv2.INPAINT_TELEA)


class OpenCvExemplarInpainter(Inpainter):
    """Exemplar/patch based (xphoto ShiftMap, He & Sun 2012): copies real texture from the crop.

    Needs opencv-contrib; run_classical.py runs it in a separate venv.
    """

    name = "shiftmap"
    fixed_side = None

    def inpaint(self, image_rgb, hole_mask):
        import cv2

        known_mask = np.where(hole_mask > 0, 0, 255).astype(np.uint8)  # xphoto: 0 = missing
        output = np.zeros_like(image_rgb)
        # xphoto expects BGR-ordered Lab-ish input for SHIFTMAP; Lab gives better patch matching.
        lab = cv2.cvtColor(image_rgb, cv2.COLOR_RGB2Lab)
        cv2.xphoto.inpaint(lab, known_mask, output, cv2.xphoto.INPAINT_SHIFTMAP)
        return cv2.cvtColor(output, cv2.COLOR_Lab2RGB)


def load_rgb(path: Path) -> np.ndarray:
    with Image.open(path) as image:
        return np.array(image.convert("RGB"))
