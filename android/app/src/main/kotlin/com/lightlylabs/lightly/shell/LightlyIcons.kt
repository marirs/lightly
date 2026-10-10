package com.lightlylabs.lightly.shell

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * The Lightly 2 line icons (docs/ui/directions/lightly-2-concept/index.html `IC` / `ic()`), drawn from the same
 * 24-unit SVG paths with stroke 1.9 and round caps/joins.
 */
object LightlyIcons {
    private fun circle(cx: Float, cy: Float, r: Float) = "M${cx - r} ${cy}a$r $r 0 1 0 ${2 * r} 0a$r $r 0 1 0 ${-2 * r} 0"

    private fun lineIcon(name: String, vararg strokePaths: String, filledPaths: List<String> = emptyList(), strokeWidth: Float = 1.9f): ImageVector =
        ImageVector.Builder(name = name, defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f).apply {
            strokePaths.forEach { path ->
                addPath(
                    pathData = addPathNodes(path), fill = null, stroke = SolidColor(Color.Black), strokeLineWidth = strokeWidth,
                    strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
                )
            }
            filledPaths.forEach { path -> addPath(pathData = addPathNodes(path), fill = SolidColor(Color.Black)) }
        }.build()

    // Lightly 2 icons: the mockup's `IC` table, 1.9-unit round strokes (arc flags written out).
    val Close = lineIcon("close", "M6 6 l12 12 M18 6 L6 18")
    val BackChevron = lineIcon("backChevron", "M15 5 l-7 7 7 7")
    val Undo = lineIcon("undo", "M9 14 L4 9 l5 -5 M4 9 h10 a6 6 0 0 1 0 12 h-3")
    val Redo = lineIcon("redo", "M15 14 l5 -5 -5 -5 M20 9 H10 a6 6 0 0 0 0 12 h3")
    val Chevron = lineIcon("chevron", "M9 6 l6 6 -6 6")
    val Check = lineIcon("check", "M5 12 l5 5 9 -10")
    val Star = lineIcon("star", "M12 3 l2.7 5.6 6.1 .9 -4.4 4.3 1 6.1 L12 17 l-5.4 2.9 1 -6.1 -4.4 -4.3 6.1 -.9 z")
    val Develop = lineIcon("develop", "M12 3 v4 M12 17 v4 M3 12 h4 M17 12 h4 M6 6 l2.5 2.5 M15.5 15.5 L18 18 M18 6 l-2.5 2.5 M8.5 15.5 L6 18")
    val Background = lineIcon("background", "M5 4 h14 a2 2 0 0 1 2 2 v12 a2 2 0 0 1 -2 2 H5 a2 2 0 0 1 -2 -2 V6 a2 2 0 0 1 2 -2 z M12 7.5 a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0 -5 z M7.5 20 c.8 -3 2.4 -4.5 4.5 -4.5 s3.7 1.5 4.5 4.5")
    val Portrait = lineIcon("portrait", "M12 4.5 a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0 -7 z M5 20 c1 -4 3.6 -6 7 -6 s6 2 7 6")
    val Edit = lineIcon("edit", "M4 7 h10 M18 7 h2 M4 17 h4 M12 17 h8 M16 5 v4 M10 15 v4")
    val Effects = lineIcon("effects", "M12 3 l1.8 5.2 L19 10 l-5.2 1.8 L12 17 l-1.8 -5.2 L5 10 l5.2 -1.8 z")
    val Watermark = lineIcon("watermark", "M3 17 c3 0 4 -9 6 -9 s1 8 3 8 2 -5 4 -5 2 3 5 3")
    val Border = lineIcon("border", "M4 4 h16 v16 H4 z M8 8 h8 v8 H8 z")
    val Photo = lineIcon("photo", "M5 4 h14 a2 2 0 0 1 2 2 v12 a2 2 0 0 1 -2 2 H5 a2 2 0 0 1 -2 -2 V6 a2 2 0 0 1 2 -2 z M9 8.2 a1.8 1.8 0 1 0 0 3.6 1.8 1.8 0 0 0 0 -3.6 z M21 16 l-5 -5 -9 9")
    val Camera = lineIcon("camera", "M4 8 h3 l2 -3 h6 l2 3 h3 v11 H4 z M12 9.5 a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0 -7 z")
    val Brush = lineIcon("brush", "M14 4 l6 6 -8 8 H6 v-6 z")
    val Erase = lineIcon("erase", "M7 20 h10 M4 14 l8 -8 6 6 -6 6 H8 z")
    val Info = lineIcon("info", "M12 3 a9 9 0 1 0 0 18 9 9 0 0 0 0 -18 z M12 11 v5 M12 8 h.01")
    val Warn = lineIcon("warn", "M12 3 l10 18 H2 z M12 10 v5 M12 18 h.01")
    val Share = lineIcon("share", "M12 15 V4 M7 9 l5 -5 5 5 M5 14 v6 h14 v-6")
    val Plus = lineIcon("plus", "M12 5 v14 M5 12 h14")
    val Eye = lineIcon("eye", "M2 12 s4 -7 10 -7 10 7 10 7 -4 7 -10 7 S2 12 2 12 z M12 9 a3 3 0 1 0 0 6 3 3 0 0 0 0 -6 z")
    val RotateLeft = lineIcon("rotateLeft", "M4 8 v5 h5 M5 13 a8 8 0 1 1 2 5")
    val RotateRight = lineIcon("rotateRight", "M20 8 v5 h-5 M19 13 a8 8 0 1 1 -2 5")
    val FlipHorizontal = lineIcon("flipHorizontal", "M12 3 v18 M8 7 L4 12 l4 5 z M16 7 l4 5 -4 5 z")
    val FlipVertical = lineIcon("flipVertical", "M3 12 h18 M7 8 l5 -4 5 4 z M7 16 l5 4 5 -4 z")
    val Grip = lineIcon("grip", "M9 6 h.01 M15 6 h.01 M9 12 h.01 M15 12 h.01 M9 18 h.01 M15 18 h.01")
    val Trash = lineIcon("trash", "M4 7 h16 M10 11 v6 M14 11 v6 M6 7 l1 13 h10 l1 -13 M9 7 V4 h6 v3")
    val Search = lineIcon("search", "M11 4 a7 7 0 1 0 0 14 7 7 0 0 0 0 -14 z M20 20 l-4 -4")
    val Flash = lineIcon("flash", "M13 2 L5 14 h6 l-1 8 8 -12 h-6 z")
    val Circle = lineIcon("circle", "M12 4 a8 8 0 1 0 0 16 8 8 0 0 0 0 -16 z")
    val Hex = lineIcon("hex", "M12 3 l8 4.5 v9 L12 21 l-8 -4.5 v-9 z")
    val Heart = lineIcon("heart", "M12 20 s-8 -5 -8 -11 a4.5 4.5 0 0 1 8 -2.8 A4.5 4.5 0 0 1 20 9 c0 6 -8 11 -8 11 z")
    val StarShape = lineIcon("starShape", "M12 3 l2.7 5.6 6.1 .9 -4.4 4.3 1 6.1 L12 17 l-5.4 2.9 1 -6.1 -4.4 -4.3 6.1 -.9 z")
    val Reset = lineIcon("reset", "M4 4 v6 h6 M5.5 15 a8 8 0 1 0 2 -8.5 L4 10")
    val AutoEnhance = lineIcon("autoEnhance", "M4 20 L15 9 M14 4 v3 M18.5 5.5 l-2 2 M20 10 h-3 M9 4.5 l1 1.5 M17 14 l1 1.5")
    val Pencil = lineIcon("pencil", "M4 20 h4 L19 9 l-4 -4 L4 16 z M13 7 l4 4")
    val Dropper = lineIcon("dropper", "M14 5 l5 5 M12 7 l5 5 -8 8 H4 v-5 z M16 3 l5 5 -2 2 -5 -5 z")
    val Flip = lineIcon("flip", "M4 8 h12 l-3 -3 M20 16 H8 l3 3")
    val Mail = lineIcon("mail", "M3 6 h18 v12 H3 z M3 7 l9 6 9 -6")
    val Picker = lineIcon("picker", "M12 3 a9 9 0 1 0 0 18 9 9 0 0 0 0 -18 z M12 8 v8 M8 12 h8")
    /** Starred: the same star, stroked and filled. */
    val StarFilled = lineIcon("starOn", "M12 3 l2.7 5.6 6.1 .9 -4.4 4.3 1 6.1 L12 17 l-5.4 2.9 1 -6.1 -4.4 -4.3 6.1 -.9 z", filledPaths = listOf("M12 3 l2.7 5.6 6.1 .9 -4.4 4.3 1 6.1 L12 17 l-5.4 2.9 1 -6.1 -4.4 -4.3 6.1 -.9 z"))
    /** `ic('more')`: three filled dots, r 1.8, at y 5, 12, 19. */
    val More = lineIcon("more", filledPaths = listOf(circle(12f, 5f, 1.8f), circle(12f, 12f, 1.8f), circle(12f, 19f, 1.8f)))
    /** `ic('compare')`: a 2-unit ring, r 8, its right half filled. */
    val Compare = lineIcon("compare", circle(12f, 12f, 8f), filledPaths = listOf("M12 4a8 8 0 0 1 0 16z"), strokeWidth = 2f)
    /** `ic('ellipsis')`: dots drawn with a 3.2-unit stroke. */
    val Ellipsis = lineIcon("ellipsis", "M5 12h.01M12 12h.01M19 12h.01", strokeWidth = 3.2f)
    /** Android back arrow (Lightly 2 uses the mockup's back chevron on both platforms). */
    val BackArrow = BackChevron
}

/** An approved icon at the prototype's size (22 dp by default), tinted with the current content colour or [tint]. */
@Composable
fun LightlyIcon(icon: ImageVector, size: Dp = 22.dp, tint: Color = Color.Unspecified, modifier: Modifier = Modifier) {
    Icon(icon, contentDescription = null, tint = if (tint == Color.Unspecified) androidx.compose.material3.LocalContentColor.current else tint, modifier = modifier.size(size))
}

/**
 * The Lightly logo (owner choice 2026-10-10, Lightly 2 "spectrum rays"), the geometry of BrandMark.swift and of the
 * mockup's `rayEnds`/`SPECTRUM`/`SPARK`/`appIcon('rays')` in its 1024-unit space: ray i points at i·45° − 90°
 * (clockwise from the top) from radius 118 to 352 (diagonals 0.86 of that), a 38-unit round stroke over a 64-unit
 * stroke at 75 % blurred by 22 units. [tile] draws the app icon (the mark on #050506, 228-unit corners); otherwise
 * the mark alone, view box 120…904.
 */
@Composable
fun LightlyMark(size: Dp, modifier: Modifier = Modifier, tile: Boolean = false) {
    Canvas(modifier.size(size)) {
        val viewOrigin = if (tile) 0f else 120f
        val viewSize = if (tile) 1024f else 784f
        val scale = this.size.minDimension / viewSize
        fun p(x: Double, y: Double) = Offset(((x - viewOrigin) * scale).toFloat(), ((y - viewOrigin) * scale).toFloat())
        if (tile) {
            drawRoundRect(Color(0xFF050506), cornerRadius = androidx.compose.ui.geometry.CornerRadius(228f * scale))
        }
        drawIntoCanvas { canvas ->
            for (ray in 0 until 8) {
                val angle = (ray * 45 - 90) * PI / 180
                val outer = if (ray % 2 == 0) 352.0 else 352.0 * 0.86
                val start = p(512 + cos(angle) * 118, 512 + sin(angle) * 118)
                val end = p(512 + cos(angle) * outer, 512 + sin(angle) * outer)
                val colour = LIGHTLY_SPECTRUM[ray]
                // The glow: Android derives sigma from a blur radius as radius × 0.57735 + 0.5, so the mockup's
                // stdDeviation 22 is radius (22 − 0.5) / 0.57735.
                val glow = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                    color = colour.copy(alpha = 0.75f).toArgb()
                    strokeWidth = 64f * scale
                    strokeCap = android.graphics.Paint.Cap.ROUND
                    style = android.graphics.Paint.Style.STROKE
                    val radius = ((22f - 0.5f) / 0.57735f) * scale
                    if (radius > 0.5f) maskFilter = android.graphics.BlurMaskFilter(radius, android.graphics.BlurMaskFilter.Blur.NORMAL)
                }
                canvas.nativeCanvas.drawLine(start.x, start.y, end.x, end.y, glow)
            }
        }
        for (ray in 0 until 8) {
            val angle = (ray * 45 - 90) * PI / 180
            val outer = if (ray % 2 == 0) 352.0 else 352.0 * 0.86
            drawLine(LIGHTLY_SPECTRUM[ray], p(512 + cos(angle) * 118, 512 + sin(angle) * 118),
                p(512 + cos(angle) * outer, 512 + sin(angle) * outer), strokeWidth = 38f * scale, cap = StrokeCap.Round)
        }
    }
}

/** `SPECTRUM`, from the top ray clockwise. */
val LIGHTLY_SPECTRUM = listOf(
    Color(0xFF6E5BFF), Color(0xFF2F86FF), Color(0xFF18C8F0), Color(0xFF14C99B),
    Color(0xFFCFF26B), Color(0xFFFFC23D), Color(0xFFFF5A5F), Color(0xFFE447C8),
)
