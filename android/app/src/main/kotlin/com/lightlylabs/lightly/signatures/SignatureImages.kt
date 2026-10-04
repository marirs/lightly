package com.lightlylabs.lightly.signatures

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import com.lightlylabs.lightly.render.image.Rgba8Image
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/** PNG encoding of signature and logo images (Android graphics). */
object SignatureImages {
    /** Straight-alpha RGBA → PNG. */
    fun png(image: Rgba8Image): ByteArray {
        val bitmap = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888)
        val colours = IntArray(image.width * image.height) { i ->
            val o = i * 4
            ((image.pixels[o + 3].toInt() and 0xff) shl 24) or ((image.pixels[o].toInt() and 0xff) shl 16) or ((image.pixels[o + 1].toInt() and 0xff) shl 8) or (image.pixels[o + 2].toInt() and 0xff)
        }
        bitmap.setPixels(colours, 0, image.width, 0, 0, image.width, image.height)
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }

    /** What an import gives (W6 and its follow-up, as iOS `ImportResult`). */
    sealed interface ImportResult {
        /** The paper removed (PNG). */
        class InkFound(val png: ByteArray) : ImportResult
        /** Content but no ink told from the paper: the photo as it is (PNG, ≤ 1,600 px). */
        class AsIs(val png: ByteArray) : ImportResult
        /** Nothing to show: its "signature" would be an empty rectangle. */
        data object Blank : ImportResult
        data object Unreadable : ImportResult
    }

    /** The working size of an import, as iOS `SignatureInkExtractor.maximumLongEdge`. */
    const val IMPORT_MAX_LONG_EDGE = 1600

    /**
     * Import signature (defect W6; the as-is fallback is a PROVISIONAL coordinator approach, pending the
     * owner): the photo is brought to ≤ 1,600 px (as iOS), then the paper is removed when ink is found;
     * otherwise a blank page gives [ImportResult.Blank] and anything else is used as it is.
     */
    fun importSignature(photo: Rgba8Image?): ImportResult {
        val working = photo?.let { runCatching { downscaled(it, IMPORT_MAX_LONG_EDGE) }.getOrNull() } ?: return ImportResult.Unreadable
        SignatureInkExtractor.extract(working)?.let { return ImportResult.InkFound(png(it)) }
        if (SignatureInkExtractor.isBlank(working)) return ImportResult.Blank
        return ImportResult.AsIs(logoPng(working, maxEdge = IMPORT_MAX_LONG_EDGE))
    }

    /** [image] scaled (filtered) so its long edge is at most [maxEdge]; channel order explicit via get/setPixels. */
    internal fun downscaled(image: Rgba8Image, maxEdge: Int): Rgba8Image {
        val scale = minOf(1.0, maxEdge.toDouble() / maxOf(image.width, image.height))
        if (scale >= 1) return image
        val p = image.pixels
        val source = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888)
        source.setPixels(IntArray(image.width * image.height) { i -> ((p[i * 4 + 3].toInt() and 0xff) shl 24) or ((p[i * 4].toInt() and 0xff) shl 16) or ((p[i * 4 + 1].toInt() and 0xff) shl 8) or (p[i * 4 + 2].toInt() and 0xff) }, 0, image.width, 0, 0, image.width, image.height)
        val scaled = Bitmap.createScaledBitmap(source, maxOf(1, Math.round(image.width * scale).toInt()), maxOf(1, Math.round(image.height * scale).toInt()), true)
        val colours = IntArray(scaled.width * scaled.height)
        scaled.getPixels(colours, 0, scaled.width, 0, 0, scaled.width, scaled.height)
        val out = ByteArray(colours.size * 4)
        for (i in colours.indices) {
            val c = colours[i]
            out[i * 4] = (c shr 16).toByte(); out[i * 4 + 1] = (c shr 8).toByte(); out[i * 4 + 2] = c.toByte(); out[i * 4 + 3] = (c ushr 24).toByte()
        }
        return Rgba8Image(scaled.width, scaled.height, out)
    }

    /** A chosen logo (or an as-is import) as PNG, downscaled to [maxEdge] on its long edge, keeping its own colours (as iOS). */
    fun logoPng(image: Rgba8Image, maxEdge: Int = 1024): ByteArray {
        val scale = minOf(1.0, maxEdge.toDouble() / maxOf(image.width, image.height))
        val bitmap = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888).apply { copyPixelsFromBuffer(ByteBuffer.wrap(image.pixels)) }
        val scaled = if (scale < 1) Bitmap.createScaledBitmap(bitmap, maxOf(1, (image.width * scale).toInt()), maxOf(1, (image.height * scale).toInt()), true) else bitmap
        return ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }

    /**
     * The prototype's imported signature (`sigSvg(h, '', true)`): the sample path in #1D2A6B, stroke 2.6 at
     * 90 %, over a 1-unit echo offset (1.2, 0.8) at 35 %, in a 170 × 50 box, as a transparent PNG at 6×
     * (as iOS `prototypeImportedSample`). Design captures and tests only.
     */
    fun prototypeImportedSample(scale: Float = 6f): ByteArray {
        val sample = DrawnSignature.PROTOTYPE_SAMPLE
        val bitmap = Bitmap.createBitmap((170 * scale).toInt(), (50 * scale).toInt(), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        fun path(dx: Float, dy: Float) = Path().apply {
            val points = sample.strokes[0]
            moveTo((points[0].x * scale + dx).toFloat(), (points[0].y * scale + dy).toFloat())
            for (i in 1 until points.size - 1) {
                quadTo((points[i].x * scale + dx).toFloat(), (points[i].y * scale + dy).toFloat(),
                    (((points[i].x + points[i + 1].x) / 2) * scale + dx).toFloat(), (((points[i].y + points[i + 1].y) / 2) * scale + dy).toFloat())
            }
            lineTo((points.last().x * scale + dx).toFloat(), (points.last().y * scale + dy).toFloat())
        }
        fun paint(width: Float, alpha: Int) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = width; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
            color = android.graphics.Color.argb(alpha, 0x1D, 0x2A, 0x6B)
        }
        canvas.drawPath(path(0f, 0f), paint(2.6f * scale, 230))
        canvas.drawPath(path(1.2f * scale, 0.8f * scale), paint(1f * scale, 89))
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }
}
