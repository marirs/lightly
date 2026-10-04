package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.image.Rgba8Image
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * `tools.edit.geometry` as plain values (edit-recipe-v1 `geometry`); the app maps the recipe onto it.
 * [cropX]…[cropHeight] are the crop rect in the straightened frame, as fractions.
 */
data class GeometryParams(
    val quarterTurns: Int = 0,
    val flipHorizontal: Boolean = false,
    val flipVertical: Boolean = false,
    val perspectiveVertical: Double = 0.0,
    val perspectiveHorizontal: Double = 0.0,
    val straighten: Double = 0.0,
    val cropX: Double = 0.0,
    val cropY: Double = 0.0,
    val cropWidth: Double = 1.0,
    val cropHeight: Double = 1.0,
) {
    val isIdentity: Boolean
        get() = quarterTurns % 4 == 0 && !flipHorizontal && !flipVertical && perspectiveVertical == 0.0 && perspectiveHorizontal == 0.0 &&
            straighten == 0.0 && cropX == 0.0 && cropY == 0.0 && cropWidth == 1.0 && cropHeight == 1.0

    companion object {
        val IDENTITY = GeometryParams()
    }
}

/**
 * Stage 4, `edit.geometry` (rendering-v2 §7): source → frame, each step in the frame the previous one
 * produced (what the person sees): quarter turns → flips → perspective → straighten → crop.
 *
 * The chain is one projective map in pixel coordinates (continuous, origin top-left, pixel centres at
 * +0.5), so content points stored in source coordinates (Remove strokes, the focus target) are drawn
 * on the frame with [frameFromSource], and a touch on the frame is stored with [sourceFromFrame].
 * Built for one resolution of the photo; a preview and an export each build their own.
 */
class GeometryTransform(val params: GeometryParams, val sourceWidth: Int, val sourceHeight: Int) {
    val frameWidth: Int
    val frameHeight: Int
    private val sourceToFrame: DoubleArray
    private val frameToSource: DoubleArray
    val isIdentity: Boolean = params.isIdentity

    init {
        var matrix = Matrix3.IDENTITY
        var width = sourceWidth.toDouble()
        var height = sourceHeight.toDouble()
        // 1. Quarter turns, clockwise: (x, y) in W × H → (H − y, x) in H × W.
        repeat(((params.quarterTurns % 4) + 4) % 4) {
            matrix = Matrix3.multiply(doubleArrayOf(0.0, -1.0, height, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0), matrix)
            val swap = width; width = height; height = swap
        }
        // 2. Flips, in the turned frame.
        if (params.flipHorizontal) matrix = Matrix3.multiply(doubleArrayOf(-1.0, 0.0, width, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0), matrix)
        if (params.flipVertical) matrix = Matrix3.multiply(doubleArrayOf(1.0, 0.0, 0.0, 0.0, -1.0, height, 0.0, 0.0, 1.0), matrix)
        // 3. Perspective (keystone about the centre), zoomed so no empty area shows.
        if (params.perspectiveVertical != 0.0 || params.perspectiveHorizontal != 0.0) {
            matrix = Matrix3.multiply(keystone(params.perspectiveVertical, params.perspectiveHorizontal, width, height), matrix)
        }
        // 4. Straighten: rotate about the centre (clockwise positive), zoomed by the smallest factor
        //    that leaves no empty corner.
        if (params.straighten != 0.0) {
            val theta = params.straighten * PI / 180
            val zoom = straightenZoom(params.straighten, width, height)
            val c = cos(theta) * zoom
            val s = sin(theta) * zoom
            val cx = width / 2
            val cy = height / 2
            matrix = Matrix3.multiply(doubleArrayOf(c, -s, cx - c * cx + s * cy, s, c, cy - s * cx - c * cy, 0.0, 0.0, 1.0), matrix)
        }
        // 5. Crop: the rect in the straightened frame.
        matrix = Matrix3.multiply(doubleArrayOf(1.0, 0.0, -params.cropX * width, 0.0, 1.0, -params.cropY * height, 0.0, 0.0, 1.0), matrix)
        frameWidth = max(1, (params.cropWidth * width).roundToInt())
        frameHeight = max(1, (params.cropHeight * height).roundToInt())
        sourceToFrame = matrix
        frameToSource = Matrix3.invert(matrix)
    }

    /** A normalised source point on the frame (normalised); outside [0, 1] when cropped away. */
    fun frameFromSource(x: Double, y: Double): Pair<Double, Double> {
        val (fx, fy) = Matrix3.apply(sourceToFrame, x * sourceWidth, y * sourceHeight)
        return fx / frameWidth to fy / frameHeight
    }

    /** A normalised frame point (a touch) in normalised source coordinates. */
    fun sourceFromFrame(x: Double, y: Double): Pair<Double, Double> {
        val (sx, sy) = Matrix3.apply(frameToSource, x * frameWidth, y * frameHeight)
        return sx / sourceWidth to sy / sourceHeight
    }

    /** Source pixel coordinates (continuous) of a frame pixel coordinate (continuous). */
    fun sourcePixel(frameX: Double, frameY: Double): Pair<Double, Double> = Matrix3.apply(frameToSource, frameX, frameY)

    /**
     * The source pixels a frame region reads (bilinear support included), clamped to the source:
     * the bounding box of the region's mapped corners (a projective map keeps a rectangle convex).
     */
    fun sourceBounds(region: PixelRect, margin: Int = 2): PixelRect {
        if (isIdentity) return region
        var minX = Double.MAX_VALUE; var minY = Double.MAX_VALUE; var maxX = -Double.MAX_VALUE; var maxY = -Double.MAX_VALUE
        for ((fx, fy) in listOf(region.x to region.y, region.x + region.width to region.y, region.x to region.y + region.height, region.x + region.width to region.y + region.height)) {
            val (sx, sy) = sourcePixel(fx.toDouble(), fy.toDouble())
            minX = min(minX, sx); minY = min(minY, sy); maxX = max(maxX, sx); maxY = max(maxY, sy)
        }
        val x0 = (kotlin.math.floor(minX).toInt() - margin).coerceIn(0, sourceWidth - 1)
        val y0 = (kotlin.math.floor(minY).toInt() - margin).coerceIn(0, sourceHeight - 1)
        val x1 = (kotlin.math.ceil(maxX).toInt() + margin).coerceIn(x0 + 1, sourceWidth)
        val y1 = (kotlin.math.ceil(maxY).toInt() + margin).coerceIn(y0 + 1, sourceHeight)
        return PixelRect(x0, y0, x1 - x0, y1 - y0)
    }

    /** The whole frame from the whole source (previews), bilinear, edge-clamped. */
    fun render(source: Rgba8Image): Rgba8Image {
        require(source.width == sourceWidth && source.height == sourceHeight) { "transform built for ${sourceWidth}x$sourceHeight, image is ${source.width}x${source.height}" }
        if (isIdentity) return source
        return renderTile(source, 0, 0, PixelRect(0, 0, frameWidth, frameHeight))
    }

    /**
     * One frame tile from a region of the source: [region] holds source pixels starting at
     * ([originX], [originY]) and must contain [sourceBounds] of the tile. Sampling clamps to the
     * region, which the zoom rules make equivalent to clamping to the source.
     */
    fun renderTile(region: Rgba8Image, originX: Int, originY: Int, tile: PixelRect): Rgba8Image {
        val out = ByteArray(tile.width * tile.height * 4)
        val src = region.pixels
        val w = region.width
        val h = region.height
        for (row in 0 until tile.height) {
            for (column in 0 until tile.width) {
                val (px, py) = Matrix3.apply(frameToSource, tile.x + column + 0.5, tile.y + row + 0.5)
                val sx = (px - 0.5 - originX).coerceIn(0.0, (w - 1).toDouble())
                val sy = (py - 0.5 - originY).coerceIn(0.0, (h - 1).toDouble())
                val x0 = sx.toInt()
                val y0 = sy.toInt()
                val x1 = min(x0 + 1, w - 1)
                val y1 = min(y0 + 1, h - 1)
                val tx = sx - x0
                val ty = sy - y0
                val o = (row * tile.width + column) * 4
                for (c in 0 until 3) {
                    val a = (src[(y0 * w + x0) * 4 + c].toInt() and 0xff).toDouble()
                    val b = (src[(y0 * w + x1) * 4 + c].toInt() and 0xff).toDouble()
                    val d = (src[(y1 * w + x0) * 4 + c].toInt() and 0xff).toDouble()
                    val e = (src[(y1 * w + x1) * 4 + c].toInt() and 0xff).toDouble()
                    val top = a + (b - a) * tx
                    val bottom = d + (e - d) * tx
                    out[o + c] = (top + (bottom - top) * ty).roundToInt().coerceIn(0, 255).toByte()
                }
                out[o + 3] = 0xff.toByte()
            }
        }
        return Rgba8Image(tile.width, tile.height, out)
    }

    companion object {
        /** ±100 scales the far edge by 1 ∓ 0.3 (rendering-v2.json `perspective`). */
        const val PERSPECTIVE_EDGE_SCALE_PER_UNIT = 0.3

        /** [contract] the smallest zoom that leaves no empty corner after a rotation by [degrees]. */
        fun straightenZoom(degrees: Double, width: Double, height: Double): Double {
            val theta = abs(degrees) * PI / 180
            val c = cos(theta)
            val s = sin(theta)
            return max(c + height / width * s, c + width / height * s)
        }

        /** The turned frame's size (before the crop), in which the crop rect is expressed. */
        fun turnedSize(quarterTurns: Int, sourceWidth: Int, sourceHeight: Int): Pair<Int, Int> =
            if (quarterTurns % 2 == 0) sourceWidth to sourceHeight else sourceHeight to sourceWidth

        /** The largest centred crop of [aspect] (w/h in pixels) in a W × H frame, as fractions [x, y, w, h]. */
        fun centredRect(aspect: Double, width: Int, height: Int): DoubleArray {
            val frameAspect = width.toDouble() / height
            return if (aspect >= frameAspect) {
                val h = frameAspect / aspect
                doubleArrayOf(0.0, (1 - h) / 2, 1.0, h)
            } else {
                val w = aspect / frameAspect
                doubleArrayOf((1 - w) / 2, 0.0, w, 1.0)
            }
        }

        /**
         * Keystone about the frame centre: vertical v > 0 narrows the top edge to 1 − 0.3·v/100 of its
         * width (v < 0 the bottom edge); horizontal h > 0 shortens the right edge (h < 0 the left). Then
         * the smallest zoom about the centre that leaves no empty area.
         */
        // CONTRACT GAP (reported, iOS C3): rendering-v2 §7 names neither which edge is "far" for each
        // sign nor how the keystone is zoomed; this port makes the same choice as iOS (top/right for
        // positive values, the no-empty-area zoom that straighten uses) so both platforms agree.
        fun keystone(vertical: Double, horizontal: Double, width: Double, height: Double): DoubleArray {
            val k = PERSPECTIVE_EDGE_SCALE_PER_UNIT
            val top = if (vertical > 0) 1 - k * vertical / 100 else 1.0
            val bottom = if (vertical < 0) 1 + k * vertical / 100 else 1.0
            val right = if (horizontal > 0) 1 - k * horizontal / 100 else 1.0
            val left = if (horizontal < 0) 1 + k * horizontal / 100 else 1.0
            val cx = width / 2
            val cy = height / 2
            fun corner(sx: Double, sy: Double): DoubleArray {
                val edge = if (sy < 0) top else bottom
                val side = if (sx < 0) left else right
                return doubleArrayOf(cx + sx * cx * edge, cy + sy * cy * side)
            }
            val from = listOf(doubleArrayOf(0.0, 0.0), doubleArrayOf(width, 0.0), doubleArrayOf(width, height), doubleArrayOf(0.0, height))
            val to = listOf(corner(-1.0, -1.0), corner(1.0, -1.0), corner(1.0, 1.0), corner(-1.0, 1.0))
            val warp = homography(from, to)
            fun covers(z: Double): Boolean = from.all { p -> inside(cx + (p[0] - cx) / z, cy + (p[1] - cy) / z, to) }
            var low = 1.0
            var high = 4.0
            if (!covers(low)) {
                repeat(40) { val mid = (low + high) / 2; if (covers(mid)) high = mid else low = mid }
                low = high
            }
            val z = low
            return Matrix3.multiply(doubleArrayOf(z, 0.0, cx - z * cx, 0.0, z, cy - z * cy, 0.0, 0.0, 1.0), warp)
        }

        /** Convex quad, clockwise in y-down coordinates: every edge's cross product must be ≥ 0. */
        private fun inside(x: Double, y: Double, quad: List<DoubleArray>): Boolean {
            for (i in 0 until 4) {
                val a = quad[i]
                val b = quad[(i + 1) % 4]
                val cross = (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0])
                if (cross < -1e-9) return false
            }
            return true
        }

        /** The projective map taking four points to four points (direct linear solve, h33 = 1). */
        fun homography(from: List<DoubleArray>, to: List<DoubleArray>): DoubleArray {
            val a = Array(8) { DoubleArray(9) }
            for (i in 0 until 4) {
                val x = from[i][0]; val y = from[i][1]; val u = to[i][0]; val v = to[i][1]
                a[2 * i] = doubleArrayOf(x, y, 1.0, 0.0, 0.0, 0.0, -u * x, -u * y, u)
                a[2 * i + 1] = doubleArrayOf(0.0, 0.0, 0.0, x, y, 1.0, -v * x, -v * y, v)
            }
            for (column in 0 until 8) {
                val pivot = (column until 8).maxBy { abs(a[it][column]) }
                val swap = a[column]; a[column] = a[pivot]; a[pivot] = swap
                for (row in 0 until 8) {
                    if (row == column) continue
                    val f = a[row][column] / a[column][column]
                    for (k in column until 9) a[row][k] -= f * a[column][k]
                }
            }
            val h = DoubleArray(8) { a[it][8] / a[it][it] }
            return doubleArrayOf(h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1.0)
        }
    }
}

/** Row-major 3 × 3 homogeneous matrices. */
internal object Matrix3 {
    val IDENTITY = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)

    fun multiply(a: DoubleArray, b: DoubleArray): DoubleArray = DoubleArray(9) { i ->
        val r = i / 3
        val c = i % 3
        a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c]
    }

    fun apply(m: DoubleArray, x: Double, y: Double): Pair<Double, Double> {
        val w = m[6] * x + m[7] * y + m[8]
        return (m[0] * x + m[1] * y + m[2]) / w to (m[3] * x + m[4] * y + m[5]) / w
    }

    fun invert(m: DoubleArray): DoubleArray {
        val det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
        require(abs(det) > 1e-18) { "geometry is not invertible" }
        val inv = doubleArrayOf(
            m[4] * m[8] - m[5] * m[7], m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
            m[5] * m[6] - m[3] * m[8], m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
            m[3] * m[7] - m[4] * m[6], m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3],
        )
        return DoubleArray(9) { inv[it] / det }
    }
}
