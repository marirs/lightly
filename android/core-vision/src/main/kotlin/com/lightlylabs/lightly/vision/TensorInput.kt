package com.lightlylabs.lightly.vision

import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.sin

/**
 * A model behind LiteRT (or a fake in tests). Takes one float32 input tensor, already laid out as the
 * model expects, and returns its float32 output tensors in the order the adapter declares. The app's
 * LiteRT adapter maps output tensors by shape, so the order here never depends on tensor names.
 */
fun interface TensorModel {
    fun run(input: FloatArray): List<FloatArray>
}

/** A photo as tightly packed RGBA8 (row-major, top-left origin), the editor's analysis image. */
class RgbaImage(val width: Int, val height: Int, val pixels: ByteArray) {
    init {
        require(width > 0 && height > 0 && pixels.size == width * height * 4) { "image ${width}x$height has ${pixels.size} bytes" }
    }

    /** Channel [c] (0 R, 1 G, 2 B) of pixel (x, y) in [0, 1]. */
    fun channel(x: Int, y: Int, c: Int): Float = (pixels[(y * width + x) * 4 + c].toInt() and 0xff) / 255f
}

/**
 * A rotated rectangle in photo pixels: centre, size and rotation. The rectangle's x axis points along
 * (cos θ, sin θ) in y-down pixel coordinates, MediaPipe's `NormalizedRect.rotation` convention, so a
 * positive angle turns the crop clockwise on screen.
 */
data class RotatedRect(val centreX: Double, val centreY: Double, val width: Double, val height: Double, val rotation: Double) {
    /** Photo pixel position of the normalised rect point (u, v) ∈ [0, 1]² (0.5, 0.5 = the centre). */
    fun toPhoto(u: Double, v: Double): Pair<Double, Double> {
        val du = (u - 0.5) * width
        val dv = (v - 0.5) * height
        val c = cos(rotation)
        val s = sin(rotation)
        return (centreX + du * c - dv * s) to (centreY + du * s + dv * c)
    }
}

/** How the 0…1 pixel values are mapped into the tensor. */
enum class ValueRange(val scale: Float, val offset: Float) {
    /** [0, 1]: selfie segmenter, face landmarks. */
    UNIT(1f, 0f),

    /** [−1, 1]: BlazeFace and the pose detector. */
    SIGNED(2f, -1f),
}

/**
 * MediaPipe ImageToTensorCalculator on the CPU: samples [roi] of [image] into a [tensorWidth] ×
 * [tensorHeight] RGB tensor, bilinear, zero outside the photo (BORDER_ZERO).
 */
object TensorSampler {
    /** NHWC float32 (1 × h × w × 3), the layout of every MediaPipe model. */
    fun nhwc(image: RgbaImage, roi: RotatedRect, tensorWidth: Int, tensorHeight: Int, range: ValueRange): FloatArray {
        val out = FloatArray(tensorWidth * tensorHeight * 3)
        val rgb = FloatArray(3)
        for (ty in 0 until tensorHeight) {
            val v = (ty + 0.5) / tensorHeight
            for (tx in 0 until tensorWidth) {
                val (px, py) = roi.toPhoto((tx + 0.5) / tensorWidth, v)
                sampleBilinearZero(image, px, py, rgb)
                val o = (ty * tensorWidth + tx) * 3
                for (c in 0 until 3) out[o + c] = rgb[c] * range.scale + range.offset
            }
        }
        return out
    }

    /** The whole photo stretched to the tensor (no aspect kept): the segmenters' input. */
    fun stretched(image: RgbaImage) = RotatedRect(image.width / 2.0, image.height / 2.0, image.width.toDouble(), image.height.toDouble(), 0.0)

    /**
     * The whole photo letterboxed into a square tensor (keep_aspect_ratio): a square ROI on the longer
     * side, centred, so the padding is split equally. Returns the ROI and the normalised padding
     * (left/right, top/bottom) that [Letterbox.remove] takes out of the detections again.
     */
    fun letterboxed(image: RgbaImage): Pair<RotatedRect, Letterbox> {
        val side = max(image.width, image.height).toDouble()
        val padX = (1 - image.width / side) / 2
        val padY = (1 - image.height / side) / 2
        return RotatedRect(image.width / 2.0, image.height / 2.0, side, side, 0.0) to Letterbox(padX, padY)
    }

    /** Bilinear at a pixel-centre coordinate (pixel i covers [i, i+1)); zero outside. */
    private fun sampleBilinearZero(image: RgbaImage, x: Double, y: Double, out: FloatArray) {
        val fx = x - 0.5
        val fy = y - 0.5
        val x0 = floor(fx).toInt()
        val y0 = floor(fy).toInt()
        val wx = (fx - x0).toFloat()
        val wy = (fy - y0).toFloat()
        out.fill(0f)
        for (dy in 0..1) {
            val yi = y0 + dy
            if (yi < 0 || yi >= image.height) continue
            val weightY = if (dy == 0) 1 - wy else wy
            for (dx in 0..1) {
                val xi = x0 + dx
                if (xi < 0 || xi >= image.width) continue
                val weight = weightY * (if (dx == 0) 1 - wx else wx)
                for (c in 0 until 3) out[c] += image.channel(xi, yi, c) * weight
            }
        }
    }
}

/** Normalised letterbox padding on each side (MediaPipe LETTERBOX_PADDING: left = right, top = bottom). */
data class Letterbox(val padX: Double, val padY: Double) {
    fun removeX(x: Double) = (x - padX) / (1 - 2 * padX)
    fun removeY(y: Double) = (y - padY) / (1 - 2 * padY)
}
