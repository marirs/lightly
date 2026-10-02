package com.lightlylabs.lightly.decode

import kotlin.math.max
import kotlin.math.roundToInt

/** Oriented pixel dimensions (after EXIF rotation). */
data class PixelSize(val width: Int, val height: Int) {
    init {
        require(width > 0 && height > 0) { "Size must be positive, was ${width}x$height" }
    }

    val longEdge: Int get() = max(width, height)
    val megapixels: Double get() = width.toDouble() * height / 1_000_000.0
}

/** Why an Original is refused before decoding (spec §5.3: reject up front with a specific message). */
sealed class DecodeRejection(message: String) : Exception(message) {
    class TooLarge(val size: PixelSize) : DecodeRejection("Photo is ${"%.1f".format(size.megapixels)} MP; the limit is ${DecodeTargets.MAX_MEGAPIXELS} MP")
    class Unsupported(val mimeType: String?) : DecodeRejection("Unsupported image format: ${mimeType ?: "unknown"}")
}

/**
 * Decode sizes, kept separate from ImageDecoder so they are testable on the JVM.
 *
 * Two different decodes of the same Original (spec §4.6 and §3):
 * - **Analysis** (model input): long edge exactly [ANALYSIS_LONG_EDGE] when the Original is
 *   larger, otherwise the Original's own size. §4.6 requires an analysis source with long edge
 *   ≥ 1024 (or the full Original); decoding to exactly 1024 meets that while keeping memory and the
 *   pinned 256² resize cheap. It is independent of the screen, so phone and tablet get the same Auto.
 * - **Display proxy** (preview render input): long edge ≤ min(screen's longest pixel dimension,
 *   2732). It is never the model input.
 */
object DecodeTargets {
    const val ANALYSIS_LONG_EDGE = 1024
    const val DISPLAY_PROXY_CAP = 2732
    const val MAX_MEGAPIXELS = 100

    fun analysisSize(original: PixelSize): PixelSize = scaledToLongEdge(original, ANALYSIS_LONG_EDGE)

    fun displaySize(original: PixelSize, screenLongestPx: Int): PixelSize {
        require(screenLongestPx > 0) { "screenLongestPx must be positive" }
        return scaledToLongEdge(original, minOf(screenLongestPx, DISPLAY_PROXY_CAP))
    }

    /** Throws [DecodeRejection.TooLarge] above 100 MP, checked from the header before allocation. */
    fun requireDecodable(original: PixelSize) {
        if (original.width.toLong() * original.height > MAX_MEGAPIXELS * 1_000_000L) throw DecodeRejection.TooLarge(original)
    }

    /**
     * Never upscales. The long edge lands exactly on [targetLongEdge]; the short edge is rounded
     * and at least 1. Aspect error is below half a pixel.
     */
    fun scaledToLongEdge(original: PixelSize, targetLongEdge: Int): PixelSize {
        require(targetLongEdge > 0) { "targetLongEdge must be positive" }
        if (original.longEdge <= targetLongEdge) return original
        val scale = targetLongEdge.toDouble() / original.longEdge
        return if (original.width >= original.height) {
            PixelSize(targetLongEdge, max(1, (original.height * scale).roundToInt()))
        } else {
            PixelSize(max(1, (original.width * scale).roundToInt()), targetLongEdge)
        }
    }
}
