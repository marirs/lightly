package com.lightlylabs.lightly.render.gpu

import com.lightlylabs.lightly.render.image.Rgba8Image

/** One rectangle of the output, in pixels, top-left origin. */
data class Tile(val x: Int, val y: Int, val width: Int, val height: Int) {
    val pixelCount: Int get() = width * height
}

/**
 * How a full-resolution frame is split for rendering (spec §5.3: Android renders FBO tiles of at most
 * 4096² and streams them into the encoder bitmap).
 *
 * Tiles are row-major, never overlap, and cover the frame exactly. The LUT passes are per-pixel, so
 * tiles need no apron; a later spatial operator (O3: grain, vignette, local contrast) would need one
 * and must extend this plan rather than reuse it silently.
 */
class TilePlan private constructor(val frameWidth: Int, val frameHeight: Int, val maxTileEdge: Int, val tiles: List<Tile>) {

    companion object {
        /** Spec §5.3 cap, also below every GL_MAX_TEXTURE_SIZE / viewport limit on the target GPUs. */
        const val SPEC_MAX_TILE_EDGE = 4096

        /**
         * @param deviceMaxTileEdge min(GL_MAX_TEXTURE_SIZE, GL_MAX_RENDERBUFFER_SIZE, GL_MAX_VIEWPORT_DIMS)
         *   queried on the device; the plan uses the smaller of that and [SPEC_MAX_TILE_EDGE].
         */
        fun plan(frameWidth: Int, frameHeight: Int, deviceMaxTileEdge: Int = SPEC_MAX_TILE_EDGE): TilePlan {
            require(frameWidth > 0 && frameHeight > 0) { "Frame must be non-empty, was ${frameWidth}x$frameHeight" }
            require(deviceMaxTileEdge > 0) { "deviceMaxTileEdge must be positive" }
            val edge = minOf(deviceMaxTileEdge, SPEC_MAX_TILE_EDGE)
            val tiles = ArrayList<Tile>()
            var y = 0
            while (y < frameHeight) {
                val height = minOf(edge, frameHeight - y)
                var x = 0
                while (x < frameWidth) {
                    val width = minOf(edge, frameWidth - x)
                    tiles += Tile(x, y, width, height)
                    x += width
                }
                y += height
            }
            return TilePlan(frameWidth, frameHeight, edge, tiles)
        }
    }
}

/** Copies a tile out of / back into a full RGBA8 frame (CPU side of upload and readback). */
object TileCopy {
    fun extract(frame: Rgba8Image, tile: Tile): Rgba8Image {
        val out = ByteArray(tile.pixelCount * Rgba8Image.CHANNELS)
        val rowBytes = tile.width * Rgba8Image.CHANNELS
        for (row in 0 until tile.height) {
            val src = ((tile.y + row) * frame.width + tile.x) * Rgba8Image.CHANNELS
            System.arraycopy(frame.pixels, src, out, row * rowBytes, rowBytes)
        }
        return Rgba8Image(tile.width, tile.height, out)
    }

    fun insert(frame: ByteArray, frameWidth: Int, tile: Tile, tilePixels: Rgba8Image) {
        require(tilePixels.width == tile.width && tilePixels.height == tile.height) { "Tile pixels do not match $tile" }
        val rowBytes = tile.width * Rgba8Image.CHANNELS
        for (row in 0 until tile.height) {
            val dst = ((tile.y + row) * frameWidth + tile.x) * Rgba8Image.CHANNELS
            System.arraycopy(tilePixels.pixels, row * rowBytes, frame, dst, rowBytes)
        }
    }
}
