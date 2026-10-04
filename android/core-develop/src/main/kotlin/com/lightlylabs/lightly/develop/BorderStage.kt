package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.image.Rgba8Image
import kotlin.math.max
import kotlin.math.roundToInt

/** `tools.border` as plain values (edit-recipe-v1 `border`). [type] is none, solid, frame or polaroid; colours "#RRGGBB". */
data class BorderParams(val type: String = "none", val colour: String = "#FFFFFF", val width: Double = 4.0, val spacing: Double = 3.0, val mat: String = "#F4F1EC") {
    val isNone: Boolean get() = type == "none"
}

/**
 * Rendering-v2 stage 11, `border`: places the finished frame on a larger canvas. Insets are fractions of
 * the frame's WIDTH (rendering-v2 §7, prototype `borderInsets`):
 * - solid: width/100 on every side, in the colour;
 * - frame: (width + spacing)/100 on every side; the outer width/100 band is the colour, the inner
 *   spacing/100 band the mat;
 * - polaroid: side and top 0.055, bottom 0.24, in the colour;
 * - none: the frame unchanged.
 * Inset pixel sizes are rounded from the frame width, as on iOS (BorderStage.swift). Preview and Save
 * copy run the same placement.
 */
object BorderStage {
    data class Insets(val side: Double, val top: Double, val bottom: Double)

    fun insets(b: BorderParams): Insets = when (b.type) {
        "solid" -> (b.width / 100).let { Insets(it, it, it) }
        "frame" -> ((b.width + b.spacing) / 100).let { Insets(it, it, it) }
        "polaroid" -> Insets(0.055, 0.055, 0.24)
        else -> Insets(0.0, 0.0, 0.0)
    }

    /** Inset pixels for a frame and the canvas they make; the photo sits at ([side], [top]). */
    data class Placement(val side: Int, val top: Int, val bottom: Int, val frameWidth: Int, val frameHeight: Int, val band: Int) {
        val canvasWidth: Int get() = frameWidth + 2 * side
        val canvasHeight: Int get() = frameHeight + top + bottom
    }

    fun placement(b: BorderParams, frameWidth: Int, frameHeight: Int): Placement {
        val i = insets(b)
        val band = if (b.type == "frame") (b.width / 100 * frameWidth).roundToInt() else 0
        return Placement((i.side * frameWidth).roundToInt(), (i.top * frameWidth).roundToInt(), (i.bottom * frameWidth).roundToInt(), frameWidth, frameHeight, band)
    }

    /**
     * The photo's box inside a canvas this border made, as fractions of the canvas [x, y, w, h] (the
     * prototype's `.imgbox` inside `.frame`): marks and touches sit on it. Recovers the exact frame width
     * the canvas was made from, since the insets are rounded from it.
     */
    fun imageBox(b: BorderParams, canvasWidth: Int, canvasHeight: Int): DoubleArray {
        if (b.isNone || canvasWidth <= 0 || canvasHeight <= 0) return doubleArrayOf(0.0, 0.0, 1.0, 1.0)
        val estimate = (canvasWidth / (1 + 2 * insets(b).side)).roundToInt()
        val frameWidth = (estimate - 2..estimate + 2).firstOrNull { placement(b, it, 0).canvasWidth == canvasWidth } ?: estimate
        val probe = placement(b, frameWidth, 0)
        val frameHeight = max(canvasHeight - probe.top - probe.bottom, 1)
        return doubleArrayOf(probe.side.toDouble() / canvasWidth, probe.top.toDouble() / canvasHeight, frameWidth.toDouble() / canvasWidth, frameHeight.toDouble() / canvasHeight)
    }

    /** The whole canvas from the whole frame (previews). */
    fun apply(b: BorderParams, frame: Rgba8Image): Rgba8Image {
        if (b.isNone) return frame
        val p = placement(b, frame.width, frame.height)
        return renderTile(b, p, PixelRect(0, 0, p.canvasWidth, p.canvasHeight)) { region -> crop(frame, region) }
    }

    /**
     * One canvas tile (Save copy). [frameRegion] renders the frame pixels of a region in frame
     * coordinates; it is asked only for the part of the tile the photo covers.
     */
    fun renderTile(b: BorderParams, p: Placement, tile: PixelRect, frameRegion: (PixelRect) -> Rgba8Image): Rgba8Image {
        val out = ByteArray(tile.width * tile.height * 4)
        val outer = rgb(b.colour)
        val mat = rgb(b.mat)
        for (row in 0 until tile.height) for (column in 0 until tile.width) {
            val x = tile.x + column
            val y = tile.y + row
            val inBand = p.band > 0 && (x < p.band || y < p.band || x >= p.canvasWidth - p.band || y >= p.canvasHeight - p.band)
            val colour = if (b.type == "frame" && !inBand) mat else outer
            val o = (row * tile.width + column) * 4
            out[o] = colour[0]; out[o + 1] = colour[1]; out[o + 2] = colour[2]; out[o + 3] = -1
        }
        // The photo's part of the tile, in frame coordinates.
        val x0 = max(tile.x, p.side)
        val y0 = max(tile.y, p.top)
        val x1 = minOf(tile.x + tile.width, p.side + p.frameWidth)
        val y1 = minOf(tile.y + tile.height, p.top + p.frameHeight)
        if (x1 > x0 && y1 > y0) {
            val photo = frameRegion(PixelRect(x0 - p.side, y0 - p.top, x1 - x0, y1 - y0))
            for (row in 0 until photo.height) {
                System.arraycopy(photo.pixels, row * photo.width * 4, out, ((y0 - tile.y + row) * tile.width + (x0 - tile.x)) * 4, photo.width * 4)
            }
        }
        return Rgba8Image(tile.width, tile.height, out)
    }

    private fun crop(image: Rgba8Image, r: PixelRect): Rgba8Image {
        val out = ByteArray(r.width * r.height * 4)
        for (row in 0 until r.height) System.arraycopy(image.pixels, ((r.y + row) * image.width + r.x) * 4, out, row * r.width * 4, r.width * 4)
        return Rgba8Image(r.width, r.height, out)
    }

    /** "#RRGGBB" → three bytes; the recipe schema guarantees the format. */
    private fun rgb(hex: String): ByteArray {
        val v = hex.removePrefix("#").toLong(16)
        return byteArrayOf(((v shr 16) and 0xff).toByte(), ((v shr 8) and 0xff).toByte(), (v and 0xff).toByte())
    }
}
