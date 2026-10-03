package com.lightlylabs.lightly.background

import kotlin.math.max
import kotlin.math.roundToInt

/** Where a photo's depth came from (recipe `depth.source`). */
enum class DepthOrigin { EMBEDDED, ESTIMATED }

/**
 * Depth for Focus & Blur, normalised as §R2.1 requires: nearness in [0, 1] (1 = nearest) at the
 * working resolution. The recipe stores depth the other way round (0 near, 1 far), see [toRecipeDepth].
 */
class NormalisedDepth(val origin: DepthOrigin, val nearness: FloatPlane) {
    fun toRecipeDepth(nearnessValue: Double) = 1.0 - nearnessValue
    fun fromRecipeDepth(depthValue: Double) = 1.0 - depthValue
}

/**
 * The monocular depth model behind an interface (Depth Anything V2 Small, LiteRT 518×392 int8 weights,
 * docs/v1/depth-evaluation.md §3). Implementations return raw relative disparity at 392 rows × 518
 * columns for [DepthModelInput.tensor]. DEFERRED(runtime): no LiteRT runtime is a project dependency
 * yet, so the app wires [UnavailableDepthEstimator] and photos without embedded depth show the
 * approved unavailable state for Focus & Blur.
 */
fun interface DepthEstimator {
    /** @throws DepthUnavailableException when this build or device cannot estimate depth. */
    suspend fun estimate(input: DepthModelInput): FloatPlane
}

class DepthUnavailableException(reason: String) : Exception(reason)

object UnavailableDepthEstimator : DepthEstimator {
    override suspend fun estimate(input: DepthModelInput): FloatPlane =
        throw DepthUnavailableException("No depth model runtime in this build (LiteRT pending approval; model pending legal sign-off)")
}

/**
 * The model input contract of §R2.1 [contract]: the image entering the Background operator, 8-bit
 * sRGB, area-resized to exactly 518 × 392 (w × h) whatever its orientation (stretch, no crop, no
 * rotation), RGB/255, ImageNet mean/std, NCHW float32.
 */
class DepthModelInput private constructor(val tensor: FloatArray) {
    companion object {
        const val WIDTH = 518
        const val HEIGHT = 392
        private val MEAN = floatArrayOf(0.485f, 0.456f, 0.406f)
        private val STD = floatArrayOf(0.229f, 0.224f, 0.225f)

        /** [rgba] is tightly packed 8-bit RGBA of [width] × [height]. */
        fun fromRgba8(rgba: ByteArray, width: Int, height: Int): DepthModelInput {
            val tensor = FloatArray(3 * WIDTH * HEIGHT)
            for (c in 0 until 3) {
                val plane = FloatPlane(width, height, FloatArray(width * height) { (rgba[it * 4 + c].toInt() and 0xff) / 255f })
                val resized = resizeArea(plane, WIDTH, HEIGHT)
                for (i in 0 until WIDTH * HEIGHT) tensor[c * WIDTH * HEIGHT + i] = (resized.values[i] - MEAN[c]) / STD[c]
            }
            return DepthModelInput(tensor)
        }

        /** Area resize to an arbitrary size (cv2 INTER_AREA for downscaling; bilinear when enlarging). */
        fun resizeArea(source: FloatPlane, width: Int, height: Int): FloatPlane {
            if (width >= source.width || height >= source.height) return PlaneOps.resizeBilinear(source, width, height)
            val out = FloatPlane(width, height)
            val sx = source.width.toDouble() / width
            val sy = source.height.toDouble() / height
            for (y in 0 until height) for (x in 0 until width) {
                val x0 = x * sx
                val x1 = (x + 1) * sx
                val y0 = y * sy
                val y1 = (y + 1) * sy
                var sum = 0.0
                var area = 0.0
                var yy = kotlin.math.floor(y0).toInt()
                while (yy < y1 && yy < source.height) {
                    val wy = minOf(y1, yy + 1.0) - maxOf(y0, yy.toDouble())
                    var xx = kotlin.math.floor(x0).toInt()
                    while (xx < x1 && xx < source.width) {
                        val wx = minOf(x1, xx + 1.0) - maxOf(x0, xx.toDouble())
                        sum += source[xx, yy] * wx * wy
                        area += wx * wy
                        xx++
                    }
                    yy++
                }
                out[x, y] = (sum / area).toFloat()
            }
            return out
        }
    }
}

object DepthMaps {
    /** §R2.1 [contract]: D = clamp((raw − p1)/(p99 − p1), 0, 1). */
    fun percentileNormalise(raw: FloatPlane): FloatPlane {
        val p1 = PlaneOps.percentile(raw.values, 1.0)
        val p99 = PlaneOps.percentile(raw.values, 99.0)
        val span = max(p99 - p1, 1e-9)
        return raw.map { ((it - p1) / span).toFloat().coerceIn(0f, 1f) }
    }

    /**
     * Model-resolution (or embedded) disparity → working resolution, edge-aware: bilinear, then a guided
     * filter with the grey image as guide, radius max(2, round(0.006·longSide)), ε = 1e-3, clamped.
     */
    fun upsample(disparity: FloatPlane, greyGuide: FloatPlane): FloatPlane {
        val up = PlaneOps.resizeBilinear(disparity, greyGuide.width, greyGuide.height)
        val radius = max(2, (0.006 * max(greyGuide.width, greyGuide.height)).roundToInt())
        return PlaneOps.guidedFilter(greyGuide, up, radius, 1e-3)
    }

    /** Full §R2.1 pipeline for any raw disparity source. */
    fun normalised(origin: DepthOrigin, rawDisparity: FloatPlane, greyGuide: FloatPlane): NormalisedDepth =
        NormalisedDepth(origin, upsample(percentileNormalise(rawDisparity), greyGuide))
}
