package com.lightlylabs.lightly.editor

import android.graphics.Bitmap
import android.graphics.BitmapFactory

/**
 * Bitmap decoding at the size it is used (Play Console, 2026-10-19: "Improve your app's performance with bitmap
 * downsampling"; BitmapFactory without Options decodes at full resolution). The image's bounds are read first, then it
 * is decoded with the largest power-of-two `inSampleSize` that keeps its long edge at or above [maxLongEdge]; callers
 * that need an exact size still scale the result.
 */
object SampledBitmaps {

    /** The power-of-two sample size that keeps a [width] × [height] image's long edge at or above [maxLongEdge]. */
    fun sampleSize(width: Int, height: Int, maxLongEdge: Int): Int {
        var sample = 1
        val longEdge = maxOf(width, height)
        while (maxLongEdge > 0 && longEdge / (sample * 2) >= maxLongEdge) sample *= 2
        return sample
    }

    fun decodeByteArray(bytes: ByteArray, maxLongEdge: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply { inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, maxLongEdge) }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    }

    /** [open] is called twice (bounds, then pixels): a stream is read once each time. */
    fun decodeStream(open: () -> java.io.InputStream, maxLongEdge: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        open().use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply { inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, maxLongEdge) }
        return open().use { BitmapFactory.decodeStream(it, null, options) }
    }

    fun decodeFile(path: String, maxLongEdge: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply { inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, maxLongEdge) }
        return BitmapFactory.decodeFile(path, options)
    }
}
