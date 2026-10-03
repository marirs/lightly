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
