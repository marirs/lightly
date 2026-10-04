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

    /** A chosen logo as PNG, downscaled to 1024 on its long edge, keeping its own colours (as iOS `logoPNG`). */
    fun logoPng(image: Rgba8Image): ByteArray {
        val scale = minOf(1.0, 1024.0 / maxOf(image.width, image.height))
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
