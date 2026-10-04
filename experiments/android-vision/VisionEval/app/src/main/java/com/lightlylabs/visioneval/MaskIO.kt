package com.lightlylabs.visioneval

import android.graphics.Bitmap
import org.json.JSONObject
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Persists confidence masks as greyscale PNGs and computes ground-truth-free mask statistics.
 * Ground truth comes later on the desktop (Apple Vision reference masks); the on-device stats are
 * there so edge behaviour is measured at full mask resolution before any PNG downscale.
 */
object MaskIO {
    /** PNGs larger than this on the long edge are box-downscaled to keep pulled results small. */
    const val SAVED_MASK_MAX_EDGE = 1024

    fun savePng(mask: ConfidenceMask, file: File, maxEdge: Int = SAVED_MASK_MAX_EDGE) {
        val scale = max(1, (max(mask.width, mask.height) + maxEdge - 1) / maxEdge)
        val outWidth = mask.width / scale
        val outHeight = mask.height / scale
        val pixels = IntArray(outWidth * outHeight)
        for (y in 0 until outHeight) {
            for (x in 0 until outWidth) {
                var sum = 0f
                for (dy in 0 until scale) for (dx in 0 until scale) {
                    sum += mask.values[(y * scale + dy) * mask.width + (x * scale + dx)]
                }
                val grey = ((sum / (scale * scale)).coerceIn(0f, 1f) * 255f).roundToInt()
                pixels[y * outWidth + x] = (0xFF shl 24) or (grey shl 16) or (grey shl 8) or grey
            }
        }
        val bitmap = Bitmap.createBitmap(pixels, outWidth, outHeight, Bitmap.Config.ARGB_8888)
        file.parentFile?.mkdirs()
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    /**
     * coverage:          fraction of pixels with confidence >= 0.5 (subject area).
     * soft_fraction:     fraction of pixels in (0.05, 0.95) — how much of the image is "uncertain".
     * boundary_px:       4-neighbour transitions of the 0.5-binarised mask (≈ contour length in px).
     * transition_width:  soft pixels per boundary pixel ≈ mean width (px) of the matte's soft edge.
     *                    ~1 = hard/aliased cut-out, 2-6 = natural matte, large = blurry halo.
     * mean_confidence_inside / outside: separation of the two classes.
     */
    fun statistics(mask: ConfidenceMask): JSONObject {
        val width = mask.width
        val height = mask.height
        val values = mask.values
        var insideCount = 0L
        var softCount = 0L
        var boundaryCount = 0L
        var insideSum = 0.0
        var outsideSum = 0.0
        for (y in 0 until height) {
            val row = y * width
            for (x in 0 until width) {
                val value = values[row + x]
                val inside = value >= 0.5f
                if (inside) { insideCount++; insideSum += value } else outsideSum += value
                if (value > 0.05f && value < 0.95f) softCount++
                if (x + 1 < width && (values[row + x + 1] >= 0.5f) != inside) boundaryCount++
                if (y + 1 < height && (values[row + width + x] >= 0.5f) != inside) boundaryCount++
            }
        }
        val total = width.toLong() * height
        val outsideCount = total - insideCount
        return JSONObject()
            .put("width", width).put("height", height)
            .put("coverage", insideCount.toDouble() / total)
            .put("soft_fraction", softCount.toDouble() / total)
            .put("boundary_px", boundaryCount)
            .put("transition_width_px", if (boundaryCount > 0) softCount.toDouble() / boundaryCount else JSONObject.NULL)
            .put("mean_confidence_inside", if (insideCount > 0) insideSum / insideCount else JSONObject.NULL)
            .put("mean_confidence_outside", if (outsideCount > 0) outsideSum / outsideCount else JSONObject.NULL)
    }
}
