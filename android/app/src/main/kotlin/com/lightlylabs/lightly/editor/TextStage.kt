package com.lightlylabs.lightly.editor

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.TextLayer
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Rendering-v2 revision 7 stage 11, `text` (§7.4, owner amendment 2026-10-11): in the frame, after crop and effects and
 * before the border, so a border never covers text and the text is part of the photo. Each layer, in order:
 * - font size = size / 100 × 0.25 × the frame's short edge, the named family at regular weight (shared/fonts);
 * - lines centred on one another, the font's own line height (descent − ascent + leading);
 * - the block (the lines' advance widths × their line heights) centred on centre × frame size, then turned
 *   `rotation` degrees clockwise about that centre;
 * - the colour at opacity / 100, anti-aliased, source-over on the frame. No shadow or outline: the selection frame and
 *   handles drawn while the Text tool is open are never rendered.
 * Preview and Save copy run exactly this code (Save copy per frame tile, through [apply]'s origin).
 */
class TextStage(private val fonts: WatermarkFonts) {

    /**
     * One laid-out text block in frame pixels: its centre, unrotated size, rotation (degrees clockwise), font size, the
     * lines with their advance widths, the line height and the font ascent (negative, as Android reports it).
     */
    data class Block(
        val centreX: Double, val centreY: Double, val width: Double, val height: Double, val rotation: Double,
        val fontSize: Double, val lines: List<String>, val lineWidths: List<Double>, val lineHeight: Double, val ascent: Double,
    )

    fun paint(layer: TextLayer, fontSize: Double): Paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = fonts.textTypeface(layer.font)
        textSize = fontSize.toFloat()
        // Unhinted metrics scale linearly with the size, so the block covers the same part of the photo at any resolution.
        isLinearText = true
        isSubpixelText = true
        color = WatermarkStage.colour(layer.colour)
        alpha = (layer.opacity / 100 * 255).roundToInt().coerceIn(0, 255)
    }

    /** The layer's block in a frame of [frameWidth] × [frameHeight] pixels. */
    fun block(layer: TextLayer, frameWidth: Double, frameHeight: Double): Block {
        val fontSize = fontSize(layer.size, frameWidth, frameHeight)
        val paint = paint(layer, fontSize)
        val metrics = paint.fontMetrics
        val lineHeight = (metrics.descent - metrics.ascent + metrics.leading).toDouble()
        val lines = layer.text.split('\n')
        val widths = lines.map { paint.measureText(it).toDouble() }
        return Block(
            centreX = layer.centre.x * frameWidth, centreY = layer.centre.y * frameHeight,
            width = widths.maxOrNull() ?: 0.0, height = lineHeight * lines.size, rotation = layer.rotation,
            fontSize = fontSize, lines = lines, lineWidths = widths, lineHeight = lineHeight, ascent = metrics.ascent.toDouble(),
        )
    }

    /** Draws [layer] on [canvas], whose coordinates are frame pixels. */
    fun draw(canvas: Canvas, layer: TextLayer, frameWidth: Double, frameHeight: Double) {
        val block = block(layer, frameWidth, frameHeight)
        val paint = paint(layer, block.fontSize)
        canvas.save()
        canvas.translate(block.centreX.toFloat(), block.centreY.toFloat())
        // Canvas.rotate turns clockwise on screen (y points down), as the recipe's rotation does.
        canvas.rotate(block.rotation.toFloat())
        val top = -block.height / 2
        block.lines.forEachIndexed { index, line ->
            val baseline = top + index * block.lineHeight - block.ascent
            canvas.drawText(line, (-block.lineWidths[index] / 2).toFloat(), baseline.toFloat(), paint)
        }
        canvas.restore()
    }

    /**
     * Stage 11 on [image], which is the frame region starting at ([originX], [originY]) of a [frameWidth] × [frameHeight]
     * frame (the whole frame for previews, one tile for Save copy). Returns [image] itself when no layer reaches it.
     */
    fun apply(image: Rgba8Image, layers: List<TextLayer>, frameWidth: Int, frameHeight: Int, originX: Int = 0, originY: Int = 0): Rgba8Image {
        if (layers.isEmpty()) return image
        val reaching = layers.filter { reaches(block(it, frameWidth.toDouble(), frameHeight.toDouble()), originX, originY, image.width, image.height) }
        if (reaching.isEmpty()) return image
        // setPixels/getPixels are channel-order explicit (copyPixels*Buffer is BGRA under Robolectric's host graphics).
        val colours = IntArray(image.width * image.height) { i ->
            val o = i * 4
            ((image.pixels[o + 3].toInt() and 0xff) shl 24) or ((image.pixels[o].toInt() and 0xff) shl 16) or
                ((image.pixels[o + 1].toInt() and 0xff) shl 8) or (image.pixels[o + 2].toInt() and 0xff)
        }
        val bitmap = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888)
        bitmap.setPixels(colours, 0, image.width, 0, 0, image.width, image.height)
        val canvas = Canvas(bitmap)
        canvas.translate(-originX.toFloat(), -originY.toFloat())
        reaching.forEach { draw(canvas, it, frameWidth.toDouble(), frameHeight.toDouble()) }
        bitmap.getPixels(colours, 0, image.width, 0, 0, image.width, image.height)
        bitmap.recycle()
        val out = image.pixels.copyOf()
        for (i in colours.indices) {
            val c = colours[i]
            out[i * 4] = (c shr 16).toByte()
            out[i * 4 + 1] = (c shr 8).toByte()
            out[i * 4 + 2] = c.toByte()
            // The frame's own alpha is kept: text is painted into the photo, not onto a transparent layer.
        }
        return Rgba8Image(image.width, image.height, out)
    }

    /** Whether the rotated block, grown for glyph overhang (swashes, italic tails), touches the given region. */
    private fun reaches(block: Block, x: Int, y: Int, width: Int, height: Int): Boolean {
        val bounds = rotatedBounds(block, overhang = block.fontSize * OVERHANG)
        return bounds[2] >= x && bounds[0] <= x + width && bounds[3] >= y && bounds[1] <= y + height
    }

    companion object {
        /** rendering-v2 §7.4: font size = size / 100 × this × the frame's short edge. */
        const val FONT_SIZE_FRACTION = 0.25

        /** Glyphs may ink past their advance box (Caveat, Dancing Script); the tile test allows this much of the font size. */
        private const val OVERHANG = 0.6

        fun fontSize(size: Int, frameWidth: Double, frameHeight: Double): Double = size / 100.0 * FONT_SIZE_FRACTION * min(frameWidth, frameHeight)

        /** [left, top, right, bottom] of the block turned about its centre, grown by [overhang] on every side. */
        fun rotatedBounds(block: Block, overhang: Double = 0.0): DoubleArray {
            val radians = Math.toRadians(block.rotation)
            val halfW = block.width / 2 + overhang
            val halfH = block.height / 2 + overhang
            val extentX = abs(halfW * cos(radians)) + abs(halfH * sin(radians))
            val extentY = abs(halfW * sin(radians)) + abs(halfH * cos(radians))
            return doubleArrayOf(floor(block.centreX - extentX), floor(block.centreY - extentY), ceil(block.centreX + extentX), ceil(block.centreY + extentY))
        }

        /** Whether the frame point ([x], [y]) lies inside the block grown by [padX] × [padY] (its own, turned axes). */
        fun contains(block: Block, x: Double, y: Double, padX: Double = 0.0, padY: Double = 0.0): Boolean {
            val (localX, localY) = toBlock(block, x, y)
            return abs(localX) <= block.width / 2 + padX && abs(localY) <= block.height / 2 + padY
        }

        /** A frame point in the block's own axes (origin at its centre, unturned). */
        fun toBlock(block: Block, x: Double, y: Double): Pair<Double, Double> {
            val radians = Math.toRadians(-block.rotation)
            val dx = x - block.centreX
            val dy = y - block.centreY
            return (dx * cos(radians) - dy * sin(radians)) to (dx * sin(radians) + dy * cos(radians))
        }

        /** A point in the block's own axes back in the frame. */
        fun fromBlock(block: Block, localX: Double, localY: Double): Pair<Double, Double> {
            val radians = Math.toRadians(block.rotation)
            return (block.centreX + localX * cos(radians) - localY * sin(radians)) to (block.centreY + localX * sin(radians) + localY * cos(radians))
        }
    }
}
