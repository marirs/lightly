package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.session.NormalisedRect
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Free crop on the straightened frame (owner amendment 2026-10-05; the same rules as iOS CropGeometry.swift). The recipe's
 * crop rect is a fraction of the frame after quarter turns, flips, perspective and straighten, so while Crop is open the
 * stage shows that frame uncropped and the rectangle is edited in its own fractions: rotation and straightening need no
 * extra mapping. Pure; tested in CropGeometryTest.
 */
object CropGeometry {
    fun scaled(rect: com.lightlylabs.lightly.session.NormalisedRect, magnification: Double): com.lightlylabs.lightly.session.NormalisedRect {
        val scale = magnification.coerceAtLeast(0.01)
        val width = (rect.width / scale).coerceIn(0.05, 1.0)
        val height = (rect.height / scale).coerceIn(0.05, 1.0)
        return com.lightlylabs.lightly.session.NormalisedRect(
            (rect.x + (rect.width - width) / 2).coerceIn(0.0, 1.0 - width),
            (rect.y + (rect.height - height) / 2).coerceIn(0.0, 1.0 - height), width, height)
    }

    enum class Edge { LEFT, RIGHT, TOP, BOTTOM }

    sealed interface Handle {
        data class Corner(val left: Boolean, val top: Boolean) : Handle
        data class Side(val edge: Edge) : Handle
        /** Inside the rectangle: moves it. */
        data object Move : Handle
    }

    /** The smallest crop, as a fraction of the frame on each side. */
    const val MINIMUM = 0.05

    /** The handle under ([x], [y]) (displayed px) for [rect] shown at [width] × [height]; null away from it. [reach]: px either side of a line. */
    fun handle(x: Float, y: Float, rect: NormalisedRect, width: Float, height: Float, reach: Float): Handle? {
        val left = rect.x.toFloat() * width; val right = (rect.x + rect.width).toFloat() * width
        val top = rect.y.toFloat() * height; val bottom = (rect.y + rect.height).toFloat() * height
        if (x < left - reach || x > right + reach || y < top - reach || y > bottom + reach) return null
        val toLeft = abs(x - left); val toRight = abs(x - right); val toTop = abs(y - top); val toBottom = abs(y - bottom)
        val nearX = min(toLeft, toRight) <= reach
        val nearY = min(toTop, toBottom) <= reach
        return when {
            nearX && nearY -> Handle.Corner(left = toLeft <= toRight, top = toTop <= toBottom)
            nearX -> Handle.Side(if (toLeft <= toRight) Edge.LEFT else Edge.RIGHT)
            nearY -> Handle.Side(if (toTop <= toBottom) Edge.TOP else Edge.BOTTOM)
            x in left..right && y in top..bottom -> Handle.Move
            else -> null
        }
    }

    /**
     * [start] changed by dragging [handle] by ([dx], [dy]) fractions of the frame. [ratio]: the locked width:height in
     * pixels (null = Free); [frameAspect]: the frame's width / height in pixels. Stays inside the frame, at least [MINIMUM].
     */
    fun dragged(start: NormalisedRect, handle: Handle, dx: Double, dy: Double, ratio: Double?, frameAspect: Double): NormalisedRect {
        val m = MINIMUM
        var x0 = start.x; var y0 = start.y; var x1 = start.x + start.width; var y1 = start.y + start.height
        when (handle) {
            Handle.Move -> {
                val x = (start.x + dx).coerceIn(0.0, 1 - start.width)
                val y = (start.y + dy).coerceIn(0.0, 1 - start.height)
                return NormalisedRect(x, y, start.width, start.height)
            }
            is Handle.Corner -> {
                if (handle.left) x0 = (x0 + dx).coerceIn(0.0, x1 - m) else x1 = (x1 + dx).coerceIn(x0 + m, 1.0)
                if (handle.top) y0 = (y0 + dy).coerceIn(0.0, y1 - m) else y1 = (y1 + dy).coerceIn(y0 + m, 1.0)
                if (ratio != null) {
                    // The width leads; the height follows the ratio, anchored at the opposite corner.
                    var width = x1 - x0
                    var height = width * frameAspect / ratio
                    val room = if (handle.top) y1 else 1 - y0
                    if (height > room) { height = room; width = height * ratio / frameAspect }
                    if (handle.left) x0 = x1 - width else x1 = x0 + width
                    if (handle.top) y0 = y1 - height else y1 = y0 + height
                }
            }
            is Handle.Side -> {
                when (handle.edge) {
                    Edge.LEFT -> x0 = (x0 + dx).coerceIn(0.0, x1 - m)
                    Edge.RIGHT -> x1 = (x1 + dx).coerceIn(x0 + m, 1.0)
                    Edge.TOP -> y0 = (y0 + dy).coerceIn(0.0, y1 - m)
                    Edge.BOTTOM -> y1 = (y1 + dy).coerceIn(y0 + m, 1.0)
                }
                if (ratio != null) {
                    if (handle.edge == Edge.LEFT || handle.edge == Edge.RIGHT) {
                        var width = x1 - x0; var height = width * frameAspect / ratio
                        if (height > 1) { height = 1.0; width = height * ratio / frameAspect; if (handle.edge == Edge.LEFT) x0 = x1 - width else x1 = x0 + width }
                        val centre = start.y + start.height / 2
                        y0 = (centre - height / 2).coerceIn(0.0, 1 - height); y1 = y0 + height
                    } else {
                        var height = y1 - y0; var width = height * ratio / frameAspect
                        if (width > 1) { width = 1.0; height = width * frameAspect / ratio; if (handle.edge == Edge.TOP) y0 = y1 - height else y1 = y0 + height }
                        val centre = start.x + start.width / 2
                        x0 = (centre - width / 2).coerceIn(0.0, 1 - width); x1 = x0 + width
                    }
                }
            }
        }
        return NormalisedRect(x0, y0, max(x1 - x0, 0.0), max(y1 - y0, 0.0))
    }
}
