"""Enhance step 1e: CodeFormer's restored detail with the original photo's colour.

CodeFormer repaints colour as well as detail: on sepia prints it adds blue eyes and red lips (its own black-and-white
check only catches pure grey). Old photos lose detail, not colour, so the restored face keeps CodeFormer's lightness (L)
and takes its colour (a, b in Lab) from the original aligned face. The original colour is low resolution, so it is
smoothed with a guided filter steered by the restored lightness: colour edges follow the restored lips, eyes and hair
instead of bleeding across them. No sepia/colour decision is needed, so a warm colour portrait cannot be misjudged.
"""
import cv2
import numpy as np


def box_mean(image: np.ndarray, radius: int) -> np.ndarray:
    return cv2.boxFilter(image, ddepth=-1, ksize=(2 * radius + 1, 2 * radius + 1), borderType=cv2.BORDER_REFLECT)


def guided_filter(guide: np.ndarray, source: np.ndarray, radius: int, epsilon: float) -> np.ndarray:
    """He, Sun and Tang's guided filter (grey guide): source smoothed, edges taken from guide."""
    mean_guide, mean_source = box_mean(guide, radius), box_mean(source, radius)
    covariance = box_mean(guide * source, radius) - mean_guide * mean_source
    variance = box_mean(guide * guide, radius) - mean_guide * mean_guide
    slope = covariance / (variance + epsilon)
    offset = mean_source - slope * mean_guide
    return box_mean(slope, radius) * guide + box_mean(offset, radius)


def restored_detail_original_colour(restored_bgr: np.ndarray, original_bgr: np.ndarray,
                                    radius: int = 8, epsilon: float = 1e-3) -> np.ndarray:
    """restored_bgr, original_bgr: uint8 aligned faces of the same size. Returns uint8 BGR."""
    restored = cv2.cvtColor(restored_bgr.astype(np.float32) / 255.0, cv2.COLOR_BGR2LAB)
    original = cv2.cvtColor(original_bgr.astype(np.float32) / 255.0, cv2.COLOR_BGR2LAB)
    guide = restored[..., 0] / 100.0
    colour = [guided_filter(guide, original[..., channel], radius, epsilon) for channel in (1, 2)]
    combined = np.dstack([restored[..., 0]] + colour).astype(np.float32)
    return (np.clip(cv2.cvtColor(combined, cv2.COLOR_LAB2BGR), 0, 1) * 255).round().astype(np.uint8)
