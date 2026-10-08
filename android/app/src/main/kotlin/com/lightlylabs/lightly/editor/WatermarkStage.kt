package com.lightlylabs.lightly.editor

import android.content.res.AssetManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import com.lightlylabs.lightly.develop.PixelRect
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.BorderType
import com.lightlylabs.lightly.session.WatermarkFont
import com.lightlylabs.lightly.session.WatermarkPlacement
import com.lightlylabs.lightly.session.WatermarkTool
import com.lightlylabs.lightly.session.WatermarkType
import com.lightlylabs.lightly.signatures.DrawnSignature
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** rendering-v2 revision 2 `stages[watermark]` constants: sizes at size 34 as fractions of the photo's short edge. */
data class WatermarkSizes(val textFontSize: Double, val signatureHeight: Double, val logoHeight: Double) {
    companion object {
        /** Revision 2's values, used only if the bundled contract cannot be read. */
        val REVISION_2 = WatermarkSizes(0.06225, 0.08995, 0.09415)

        /** From the bundled contract (contract fixes 2 §6: read, not hard-coded). */
        fun fromContract(contract: String): WatermarkSizes? = runCatching {
            val root = kotlinx.serialization.json.Json.parseToJsonElement(contract) as kotlinx.serialization.json.JsonObject
            val stage = (root.getValue("stages") as kotlinx.serialization.json.JsonArray).map { it as kotlinx.serialization.json.JsonObject }
                .first { (it["id"] as kotlinx.serialization.json.JsonPrimitive).content == "watermark" }
            val constants = ((stage.getValue("operators") as kotlinx.serialization.json.JsonArray)[0] as kotlinx.serialization.json.JsonObject).getValue("constants") as kotlinx.serialization.json.JsonObject
            fun value(key: String): Double = when (val e = constants.getValue(key)) {
                is kotlinx.serialization.json.JsonPrimitive -> e.content.toDouble()
                is kotlinx.serialization.json.JsonObject -> (e.getValue("value") as kotlinx.serialization.json.JsonPrimitive).content.toDouble()
                else -> error("bad constant $key")
            }
            WatermarkSizes(value("textFontSize"), value("signatureHeight"), value("logoHeight"))
        }.getOrNull()
    }
}

/** What a watermark shows, resolved from the recipe; a missing or changed saved signature resolves to nothing. */
sealed interface WatermarkContent {
    data class Drawn(val signature: DrawnSignature) : WatermarkContent
    /** PNG with the paper removed; it keeps its own ink. */
    class Imported(val png: ByteArray) : WatermarkContent
    data class Text(val text: String, val font: WatermarkFont) : WatermarkContent
    /** The bundled sample logo (prototype `LOGO`: a ring and "AR"). */
    data object SampleLogo : WatermarkContent
    /** A logo image the person chose; it keeps its own colours. */
    class LogoImage(val png: ByteArray) : WatermarkContent
}

/** A rendered watermark: premultiplied RGBA at ([x], [y]) on the canvas, opacity applied. */
class WatermarkLayer(val x: Int, val y: Int, val width: Int, val height: Int, val premultiplied: ByteArray) {
    /** Composites the layer onto [image], whose pixel (0, 0) is canvas pixel ([originX], [originY]). */
    fun compositeOnto(image: Rgba8Image, originX: Int = 0, originY: Int = 0): Rgba8Image {
        val x0 = max(x, originX); val y0 = max(y, originY)
        val x1 = min(x + width, originX + image.width); val y1 = min(y + height, originY + image.height)
        if (x1 <= x0 || y1 <= y0) return image
        val out = image.pixels.copyOf()
        for (cy in y0 until y1) for (cx in x0 until x1) {
            val l = ((cy - y) * width + (cx - x)) * 4
            val a = (premultiplied[l + 3].toInt() and 0xff) / 255.0
            if (a == 0.0) continue
            val o = ((cy - originY) * image.width + (cx - originX)) * 4
            for (c in 0 until 3) {
                val base = (out[o + c].toInt() and 0xff).toDouble()
                out[o + c] = ((premultiplied[l + c].toInt() and 0xff) + base * (1 - a)).roundToInt().coerceIn(0, 255).toByte()
            }
        }
        return Rgba8Image(image.width, image.height, out)
    }
}

/**
 * Rendering-v2 stage 12, `watermark` (revision 2 §7), after Border, on the canvas, in preview and Save copy
 * alike; the same rules as iOS WatermarkStage.swift (1e2d1d5):
 * - sizes are fractions of the photo's short edge (the frame inside the border) at size 34, linear in size/34;
 * - on the photo, the box is anchored at 6/50/94 % of the photo (or the dragged offset) with the prototype's
 *   tx/ty rule; on a border, centred in the bottom margin with its box bottom 6 % (polaroid) or 1 % of the
 *   canvas height above the canvas bottom, in #222222 on a polaroid;
 * - the box follows the prototype's `.wm` (line-height 1 in a 15 px strut: at least 13 CSS px above the
 *   baseline and 2 below); text keeps its half-leading;
 * - `text-shadow: 0 1px 2px rgba(0,0,0,.35)` on the photo only, on text (and the sample logo's initials);
 * - the whole element at the watermark's opacity.
 * A CSS px is the type's size constant × short edge ÷ the prototype's px size (text 18, signature 26, logo 30).
 */
class WatermarkStage(private val sizes: WatermarkSizes, private val fonts: WatermarkFonts) {
    enum class Kind { TEXT, SIGNATURE, LOGO }

    data class Extent(val width: Double, val above: Double, val below: Double)

    /** The `.wm` box in canvas pixels, its baseline (text) or content bottom (signature, logo), one CSS px, and the ink. */
    data class Layout(val left: Double, val top: Double, val width: Double, val height: Double, val baseline: Double, val cssPixel: Double, val onBorder: Boolean, val ink: String)

    fun kind(content: WatermarkContent) = when (content) {
        is WatermarkContent.Drawn, is WatermarkContent.Imported -> Kind.SIGNATURE
        is WatermarkContent.Text -> Kind.TEXT
        else -> Kind.LOGO
    }

    fun mainSize(kind: Kind, size: Double, shortEdge: Double): Double = when (kind) {
        Kind.TEXT -> sizes.textFontSize
        Kind.SIGNATURE -> sizes.signatureHeight
        Kind.LOGO -> sizes.logoHeight
    } * shortEdge * size / 34

    fun cssPixel(kind: Kind, shortEdge: Double): Double = when (kind) {
        Kind.TEXT -> sizes.textFontSize * shortEdge / 18
        Kind.SIGNATURE -> sizes.signatureHeight * shortEdge / 26
        Kind.LOGO -> sizes.logoHeight * shortEdge / 30
    }

    fun extent(content: WatermarkContent, size: Double, shortEdge: Double): Extent {
        val main = mainSize(kind(content), size, shortEdge)
        return when (content) {
            is WatermarkContent.Text -> {
                val paint = textPaint(content.font, main, size)
                val metrics = paint.fontMetrics
                val ascent = -metrics.ascent.toDouble()
                val descent = metrics.descent.toDouble()
                // CSS `line-height: 1`: one font size tall, the ascent and descent centred in it (half-leading).
                val above = (main - (ascent + descent)) / 2 + ascent
                Extent(paint.measureText(content.text).toDouble(), above, main - above)
            }
            is WatermarkContent.Drawn -> Extent(main * content.signature.aspectRatio, main, 0.0)
            is WatermarkContent.Imported -> Extent(main * aspect(content.png), main, 0.0)
            is WatermarkContent.LogoImage -> Extent(main * aspect(content.png), main, 0.0)
            WatermarkContent.SampleLogo -> Extent(main, main, 0.0)
        }
    }

    fun layout(w: WatermarkTool, kind: Kind, extent: Extent, canvasWidth: Int, canvasHeight: Int, imageRect: PixelRect, border: BorderType): Layout {
        val shortEdge = min(imageRect.width, imageRect.height).toDouble()
        val px = cssPixel(kind, shortEdge)
        val above = max(extent.above, STRUT_ABOVE * px)
        val below = max(extent.below, STRUT_BELOW * px)
        val height = above + below
        val onBorder = isOnBorder(w, border)
        val left: Double
        val top: Double
        if (w.placement == WatermarkPlacement.CANVAS) {
            val (ax, ay) = anchor(w)
            left = (ax * canvasWidth - extent.width / 2).coerceIn(0.0, max(0.0, canvasWidth - extent.width))
            top = (ay * canvasHeight - height / 2).coerceIn(0.0, max(0.0, canvasHeight - height))
        } else if (onBorder) {
            val fromBottom = if (border == BorderType.POLAROID) 0.06 else 0.01
            left = canvasWidth / 2.0 - extent.width / 2
            top = canvasHeight * (1 - fromBottom) - height
        } else {
            val (ax, ay) = anchor(w)
            left = imageRect.x + ax * imageRect.width - alignment(ax) * extent.width
            top = imageRect.y + ay * imageRect.height - alignment(ay) * height
        }
        val ink = if (border == BorderType.POLAROID && onBorder) POLAROID_INK else w.colour
        return Layout(left, top, extent.width, height, top + above, px, onBorder, ink)
    }

    /** The watermark as a layer on a canvas of this size, or null when there is nothing to draw. */
    fun layer(w: WatermarkTool, content: WatermarkContent?, canvasWidth: Int, canvasHeight: Int, imageRect: PixelRect, border: BorderType): WatermarkLayer? {
        if (w.type == WatermarkType.NONE || content == null || w.opacity <= 0) return null
        val shortEdge = min(imageRect.width, imageRect.height).toDouble()
        if (shortEdge <= 0) return null
        val kind = kind(content)
        val extent = extent(content, w.size, shortEdge)
        val l = layout(w, kind, extent, canvasWidth, canvasHeight, imageRect, border)
        val main = mainSize(kind, w.size, shortEdge)
        // The layer covers the box plus room for glyph overhang and the shadow, clipped to the canvas.
        val margin = main * 0.6 + 4 * l.cssPixel
        val x0 = max(0, floor(l.left - margin).toInt()); val y0 = max(0, floor(l.top - margin).toInt())
        val x1 = min(canvasWidth, ceil(l.left + l.width + margin).toInt()); val y1 = min(canvasHeight, ceil(l.top + l.height + margin).toInt())
        if (x1 <= x0 || y1 <= y0) return null
        val bitmap = Bitmap.createBitmap(x1 - x0, y1 - y0, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.translate(-x0.toFloat(), -y0.toFloat())
        draw(content, l, main, w.size, canvas)
        // getPixels is channel-order explicit; copyPixelsToBuffer copies native memory, whose byte order is
        // RGBA on devices but BGRA under Robolectric's host graphics (it recoloured imported ink in tests).
        val colours = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(colours, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        bitmap.recycle()
        val opacity = w.opacity / 100
        val bytes = ByteArray(colours.size * 4)
        for (i in colours.indices) {
            val c = colours[i]
            val alpha = (c ushr 24) / 255.0
            // getPixels gives straight colour; the layer is premultiplied, with the opacity applied.
            bytes[i * 4] = (((c shr 16) and 0xff) * alpha * opacity).roundToInt().toByte()
            bytes[i * 4 + 1] = (((c shr 8) and 0xff) * alpha * opacity).roundToInt().toByte()
            bytes[i * 4 + 2] = ((c and 0xff) * alpha * opacity).roundToInt().toByte()
            bytes[i * 4 + 3] = ((c ushr 24) * opacity).roundToInt().toByte()
        }
        return WatermarkLayer(x0, y0, x1 - x0, y1 - y0, bytes)
    }

    private fun draw(content: WatermarkContent, l: Layout, main: Double, size: Double, canvas: Canvas) {
        val ink = colour(l.ink)
        val left = l.left.toFloat()
        val bottom = l.baseline.toFloat()
        when (content) {
            is WatermarkContent.Text -> {
                val paint = textPaint(content.font, main, size).apply { color = ink }
                shadow(paint, l)
                canvas.drawText(content.text, left, bottom, paint)
            }
            is WatermarkContent.Drawn -> drawSignature(canvas, content.signature, left, (bottom - main).toFloat(), main.toFloat(), ink)
            is WatermarkContent.Imported -> drawImage(canvas, content.png, RectF(left, (bottom - main).toFloat(), (left + l.width).toFloat(), bottom))
            is WatermarkContent.LogoImage -> drawImage(canvas, content.png, RectF(left, (bottom - main).toFloat(), (left + l.width).toFloat(), bottom))
            WatermarkContent.SampleLogo -> drawSampleLogo(canvas, left, (bottom - main).toFloat(), main.toFloat(), ink, l)
        }
    }

    /** The prototype's `LOGO` in a 64-unit box: ring r 27 (stroke 3), "AR" in Inter 700 size 22 centred on baseline 40. Text shadow on the initials only. */
    fun drawSampleLogo(canvas: Canvas, left: Float, top: Float, height: Float, ink: Int, layout: Layout?) {
        val unit = height / 64
        canvas.drawCircle(left + 32 * unit, top + 32 * unit, 27 * unit, Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 3 * unit; color = ink })
        val cssPixels = layout?.let { 22 * unit / it.cssPixel.toFloat() } ?: (22 * unit)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = fonts.logoInitials(cssPixels.toDouble()); textSize = 22 * unit; color = ink; textAlign = Paint.Align.CENTER }
        layout?.let { shadow(paint, it) }
        canvas.drawText("AR", left + 32 * unit, top + 40 * unit, paint)
    }

    /** A drawn signature (prototype `sigSvg`): smoothed through the midpoints, round caps and joins, its own stroke proportion. */
    fun drawSignature(canvas: Canvas, signature: DrawnSignature, left: Float, top: Float, height: Float, ink: Int) {
        val scale = height / signature.viewBox.height
        fun mx(p: DrawnSignature.Point) = (left + (p.x - signature.viewBox.x) * scale).toFloat()
        fun my(p: DrawnSignature.Point) = (top + (p.y - signature.viewBox.y) * scale).toFloat()
        val path = Path()
        for (stroke in signature.strokes) {
            if (stroke.isEmpty()) continue
            path.moveTo(mx(stroke[0]), my(stroke[0]))
            if (stroke.size == 1) { path.lineTo(mx(stroke[0]), my(stroke[0])); continue }
            for (i in 1 until stroke.size - 1) {
                path.quadTo(mx(stroke[i]), my(stroke[i]), (mx(stroke[i]) + mx(stroke[i + 1])) / 2, (my(stroke[i]) + my(stroke[i + 1])) / 2)
            }
            path.lineTo(mx(stroke.last()), my(stroke.last()))
        }
        canvas.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = signature.lineWidth(height.toDouble()).toFloat(); strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND; color = ink
        })
    }

    private fun drawImage(canvas: Canvas, png: ByteArray, rect: RectF) {
        val bitmap = BitmapFactory.decodeByteArray(png, 0, png.size) ?: return
        canvas.drawBitmap(bitmap, null, rect, Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
    }

    private fun shadow(paint: Paint, l: Layout) {
        if (l.onBorder) return
        // CSS blur 2px is a Gaussian of σ = 1 CSS px; Skia's shadow radius r gives σ = 0.57735·r + 0.5 (px).
        val sigma = SHADOW_SIGMA * l.cssPixel
        val radius = max((sigma - 0.5) / 0.57735, 0.01).toFloat()
        paint.setShadowLayer(radius, 0f, (SHADOW_OFFSET * l.cssPixel).toFloat(), android.graphics.Color.argb((SHADOW_ALPHA * 255).roundToInt(), 0, 0, 0))
    }

    private fun textPaint(font: WatermarkFont, main: Double, watermarkSize: Double) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        // Inter's optical size follows the CSS px size the prototype would draw at (18 px × size/34).
        typeface = fonts.typeface(font, opticalSize = 18 * watermarkSize / 34)
        textSize = main.toFloat()
    }

    private fun aspect(png: ByteArray): Double {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(png, 0, png.size, options)
        return if (options.outHeight > 0) options.outWidth.toDouble() / options.outHeight else 0.0
    }

    companion object {
        const val STRUT_ABOVE = 13.0
        const val STRUT_BELOW = 2.0
        const val SHADOW_OFFSET = 1.0
        const val SHADOW_SIGMA = 1.0
        const val SHADOW_ALPHA = 0.35
        const val POLAROID_INK = "#222222"
        private val ANCHORS = doubleArrayOf(0.06, 0.5, 0.94)
        const val SAMPLE_LOGO_ID = "logo-sample-ar"

        fun isOnBorder(w: WatermarkTool, border: BorderType) = w.placement == WatermarkPlacement.BORDER && border != BorderType.NONE

        /** The dragged offset, else the position's anchor (fractions of the photo). */
        fun anchor(w: WatermarkTool): Pair<Double, Double> = w.offset?.let { it.x to it.y } ?: w.position.coerceIn(0, 8).let { ANCHORS[it % 3] to ANCHORS[it / 3] }

        /** The prototype's tx/ty: below 30 % the box starts at the anchor, above 70 % it ends there, else it is centred. */
        fun alignment(c: Double) = if (c < 0.30) 0.0 else if (c > 0.70) 1.0 else 0.5

        fun colour(hex: String): Int = (0xFF000000 or hex.removePrefix("#").toLong(16)).toInt()
    }
}

/**
 * The four approved watermark fonts (shared/fonts, SIL OFL 1.1), bundled into assets/fonts by the build, by
 * exact family and weight as the prototype loads them: Allura, Cormorant Garamond 500, Inter 400 (text) and
 * 700 (the logo's initials), Caveat 500. Variable fonts get their weight through `wght`; Inter's `opsz`
 * follows the CSS px size (Chromium sets it automatically), clamped to its 14…32 axis.
 */
// v3 differs (owner deviation W4): the prototype's Cormorant Garamond quoting falls back to the system
// font; native renders the real Cormorant Garamond 500.
class WatermarkFonts(val assets: AssetManager?) {
    private val cache = java.util.concurrent.ConcurrentHashMap<String, Typeface>()

    fun typeface(font: WatermarkFont, opticalSize: Double = 18.0): Typeface = when (font) {
        WatermarkFont.ALLURA -> load("Allura-Regular.ttf", null)
        WatermarkFont.CORMORANT_GARAMOND -> load("CormorantGaramond-Variable.ttf", "'wght' 500")
        WatermarkFont.INTER -> load("Inter-Variable.ttf", "'wght' 400, 'opsz' ${opticalSize.coerceIn(14.0, 32.0).roundToInt()}")
        WatermarkFont.CAVEAT -> load("Caveat-Variable.ttf", "'wght' 500")
    }

    fun logoInitials(cssPixels: Double): Typeface = load("Inter-Variable.ttf", "'wght' 700, 'opsz' ${cssPixels.coerceIn(14.0, 32.0).roundToInt()}")

    private fun load(file: String, variation: String?): Typeface = cache.getOrPut("$file|$variation") {
        val assets = assets ?: return@getOrPut Typeface.DEFAULT
        runCatching {
            Typeface.Builder(assets, "$ASSET_DIR/$file").apply { if (variation != null) setFontVariationSettings(variation) }.build()
        }.getOrNull() ?: Typeface.DEFAULT // only a broken build reaches this
    }

    companion object {
        const val ASSET_DIR = "fonts"
    }
}
