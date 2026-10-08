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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin

/**
 * The approved line icons (docs/ui/app/app.js `ICON`), drawn from the same 24-unit SVG paths with
 * stroke 1.6 and round caps/joins. Rects and circles of the originals are written as path arcs.
 */
object LightlyIcons {
    private fun circle(cx: Float, cy: Float, r: Float) = "M${cx - r} ${cy}a$r $r 0 1 0 ${2 * r} 0a$r $r 0 1 0 ${-2 * r} 0"

    private fun lineIcon(name: String, vararg strokePaths: String, filledPaths: List<String> = emptyList(), strokeWidth: Float = 1.6f): ImageVector =
        ImageVector.Builder(name = name, defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f).apply {
            strokePaths.forEach { path ->
                addPath(
                    pathData = addPathNodes(path), fill = null, stroke = SolidColor(Color.Black), strokeLineWidth = strokeWidth,
                    strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
                )
            }
            filledPaths.forEach { path -> addPath(pathData = addPathNodes(path), fill = SolidColor(Color.Black)) }
        }.build()

    /** Android back (`backA`). */
    val BackArrow = lineIcon("backA", "M20 12H5M11 6l-6 6 6 6")

    /** Page back chevron (`back`), used by the More pages on both platforms. */
    val BackChevron = lineIcon("back", "M15 5l-7 7 7 7")
    val AutoEnhance = lineIcon("autoEnhance", "M4 20L16 8l3 3L7 23z", "M13 11l3 3", "M6 3v4M4 5h4M19 1v4M17 3h4M21 16v4M19 18h4")
    val Close = lineIcon("close", "M6 6l12 12M18 6L6 18")
    val Chevron = lineIcon("chevron", "M9 5l7 7-7 7")
    val Check = lineIcon("check", "M5 12.5l4.5 4.5L19 7.5")
    val Trash = lineIcon("trash", "M5 7h14M9 7V5h6v2M7 7l1 13h8l1-13")
    val Grip = lineIcon("grip", "M8 7h.01M8 12h.01M8 17h.01M16 7h.01M16 12h.01M16 17h.01", strokeWidth = 3f)
    val More = lineIcon("more", filledPaths = listOf(circle(12f, 5.5f, 1.3f), circle(12f, 12f, 1.3f), circle(12f, 18.5f, 1.3f)))
    val Photo = lineIcon(
        "photo",
        "M6 4.5h12a2.5 2.5 0 0 1 2.5 2.5v10a2.5 2.5 0 0 1-2.5 2.5H6a2.5 2.5 0 0 1-2.5-2.5V7A2.5 2.5 0 0 1 6 4.5z",
        circle(9f, 10f, 1.8f),
        "M4 17l4.5-4.5 4 4 2.5-2.5 5 5",
    )
    val Undo = lineIcon("undo", "M9 7H5V3", "M5.5 7.5A8 8 0 1 1 4 13")
    val Redo = lineIcon("redo", "M15 7h4V3", "M18.5 7.5A8 8 0 1 0 20 13")
    val Compare = lineIcon(
        "compare",
        "M7 4.5h10a2.5 2.5 0 0 1 2.5 2.5v10a2.5 2.5 0 0 1-2.5 2.5H7a2.5 2.5 0 0 1-2.5-2.5V7A2.5 2.5 0 0 1 7 4.5z",
        "M12 4.5v15",
        filledPaths = listOf("M12 4.5h5a2.5 2.5 0 0 1 2.5 2.5v10a2.5 2.5 0 0 1-2.5 2.5h-5z"),
    )
    val Develop = lineIcon("develop", "M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1")
    val Background = lineIcon(
        "background",
        "M6 5h12a2.5 2.5 0 0 1 2.5 2.5v9a2.5 2.5 0 0 1-2.5 2.5H6a2.5 2.5 0 0 1-2.5-2.5v-9A2.5 2.5 0 0 1 6 5z",
        circle(12f, 11f, 2.6f),
        "M7 19c.8-2.6 2.8-4 5-4s4.2 1.4 5 4",
    )
    val Portrait = lineIcon("portrait", circle(12f, 8.5f, 3.6f), "M5 20c1.2-3.8 4-5.6 7-5.6s5.8 1.8 7 5.6")
    val Edit = lineIcon("edit", "M5 7h9M18 7h1M5 17h1M10 17h9", circle(16f, 7f, 2f), circle(8f, 17f, 2f))
    val Effects = lineIcon("effects", "M12 3l1.8 4.6L18.5 9l-4.7 1.6L12 15l-1.8-4.4L5.5 9l4.7-1.4z")
    val Watermark = lineIcon("watermark", "M4 17c2.5-4 4.5-9 7-9 1.6 0 1 4 2.6 4 1.3 0 1.7-2 3-2 1 0 1.6 1 3.4 2", "M4 20h16")
    val Border = lineIcon(
        "border",
        "M5 3.5h14a1.5 1.5 0 0 1 1.5 1.5v14a1.5 1.5 0 0 1-1.5 1.5H5a1.5 1.5 0 0 1-1.5-1.5V5A1.5 1.5 0 0 1 5 3.5z",
        "M7.5 7h9a.5 .5 0 0 1 .5.5v7a.5 .5 0 0 1-.5.5h-9a.5 .5 0 0 1-.5-.5v-7a.5 .5 0 0 1 .5-.5z",
    )
    private const val STAR_PATH = "M12 4.5l2.2 4.6 5 .7-3.6 3.5.9 5-4.5-2.4-4.5 2.4.9-5L4.8 9.8l5-.7z"
    val Star = lineIcon("star", STAR_PATH)

    /** `.star.on .icon { fill: currentColor }`: the same star, stroked and filled. */
    val StarFilled = lineIcon("starOn", STAR_PATH, filledPaths = listOf(STAR_PATH))
    val Info = lineIcon("info", circle(12f, 12f, 8.5f), "M12 11v5M12 8v.5")
    val Warn = lineIcon("warn", "M12 4l9 16H3z", "M12 10v4M12 17v.5")
    val Share = lineIcon("share", "M12 3v12M7.5 7.5 12 3l4.5 4.5", "M5 12v6.5A1.5 1.5 0 0 0 6.5 20h11a1.5 1.5 0 0 0 1.5-1.5V12")
    val Brush = lineIcon("brush", "M14.5 4.5l5 5-8 8H6.5v-5z", "M4 20h7")
    val Erase = lineIcon("erase", "M8 20h12M5.5 14.5l7-7 5 5-5.5 5.5H9z")
    val Plus = lineIcon("plus", "M12 5v14M5 12h14")
    /** Effects › Selective Colour (reference: docs/ui/proposals/selective-colour at 330cf5b; status in its README): eyedropper. */
    val Picker = lineIcon("picker", "M14.6 4.6A2.6 2.6 0 0 1 18.3 4.6L19.4 5.7A2.6 2.6 0 0 1 19.4 9.4L17.2 11.6L12.4 6.8Z",
        "M11.2 7.6l5.2 5.2", "M13.6 10.2L6.4 17.4L5 20L7.6 18.6L14.8 11.4")
    val Circle = lineIcon("circle", circle(12f, 12f, 7f))
    val Hex = lineIcon("hex", "M12 4.5l6.5 3.75v7.5L12 19.5l-6.5-3.75v-7.5z")
    val Heart = lineIcon("heart", "M12 19s-7-4.4-7-9.5A3.8 3.8 0 0 1 12 7a3.8 3.8 0 0 1 7 2.5C19 14.6 12 19 12 19z")
    val StarShape = lineIcon("starShape", "M12 5l2 4.6 5 .4-3.8 3.3 1.2 4.9L12 15.6 7.6 18.2l1.2-4.9L5 10l5-.4z")
    /** Edit › Rotate (prototype `rotl`, `rotr`, `fliph`, `flipv`). */
    val RotateLeft = lineIcon("rotl", "M4 4v5h5", "M4.5 9A8 8 0 1 1 6 16")
    val RotateRight = lineIcon("rotr", "M20 4v5h-5", "M19.5 9A8 8 0 1 0 18 16")
    val FlipHorizontal = lineIcon("fliph", "M12 3v18", "M9 7L4 12l5 5z", "M15 7l5 5-5 5z")
    val FlipVertical = lineIcon("flipv", "M3 12h18", "M7 9l5-5 5 5z", "M7 15l5 5 5-5z")
    val Camera = lineIcon(
        "camera",
        "M4 8.5A2.5 2.5 0 0 1 6.5 6h1.6l1.4-2h5l1.4 2h1.6A2.5 2.5 0 0 1 20 8.5v8A2.5 2.5 0 0 1 17.5 19h-11A2.5 2.5 0 0 1 4 16.5z",
        circle(12f, 12.5f, 3.4f),
    )
}

/** An approved icon at the prototype's size (22 dp by default), tinted with the current content colour or [tint]. */
@Composable
fun LightlyIcon(icon: ImageVector, size: Dp = 22.dp, tint: Color = Color.Unspecified, modifier: Modifier = Modifier) {
    Icon(icon, contentDescription = null, tint = if (tint == Color.Unspecified) androidx.compose.material3.LocalContentColor.current else tint, modifier = modifier.size(size))
}

/**
 * The eight-ray Lightly mark (prototype `mark()`, geometry of BrandMark.swift): rays from 30% of the
 * radius outwards, alternating full and 86% length, stroke max(1.6, 3.5% of the size), round caps.
 */
@Composable
fun LightlyMark(size: Dp, color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier.size(size)) {
        val radius = this.size.minDimension / 2f
        val center = Offset(this.size.width / 2f, this.size.height / 2f)
        val inner = radius * 0.3f
        val strokeWidth = max(1.6.dp.toPx(), this.size.minDimension * 0.035f)
        for (ray in 0 until 8) {
            val angle = ray * PI / 4
            val outer = if (ray % 2 == 1) radius * 0.86f else radius
            val direction = Offset(cos(angle).toFloat(), sin(angle).toFloat())
            drawLine(color, center + direction * inner, center + direction * outer, strokeWidth = strokeWidth, cap = StrokeCap.Round)
        }
    }
}
