package com.lightlylabs.lightly.signatures

import com.lightlylabs.lightly.render.image.Rgba8Image
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Import a signature (approved `wm-sig-import`): "The paper is removed. The ink keeps its original colour
 * and texture." The same algorithm as iOS (SignatureInkExtractor.swift):
 * - the paper is the photo's bright level (90th percentile of luma), the ink its dark level (2nd);
 * - each pixel's ink coverage α rises from 0 just below the paper level to 1 halfway to the ink level;
 * - its colour is un-mixed from the paper, C = (P − (1 − α)·paper)/α, so the ink keeps its hue and the
 *   stroke's texture survives as varying α;
 * - the result is cropped to the ink and padded like the prototype's signature (the ink spans 32 of 50
 *   units of height, 6 units of margin each side).
 * Returns straight (not premultiplied) RGBA, or null when no ink stands out from the paper.
 */
object SignatureInkExtractor {
    const val INK_HEIGHT_FRACTION = 32.0 / 50

    fun extract(image: Rgba8Image): Rgba8Image? {
        val w = image.width
        val h = image.height
        val n = w * h
        val p = image.pixels
        fun ch(i: Int, c: Int) = (p[i * 4 + c].toInt() and 0xff) / 255.0
        val luma = DoubleArray(n) { 0.2126 * ch(it, 0) + 0.7152 * ch(it, 1) + 0.0722 * ch(it, 2) }
        val sorted = luma.sortedArray()
        val paperLevel = sorted[((n - 1) * 0.90).toInt()]
        val inkLevel = sorted[((n - 1) * 0.02).toInt()]
        if (paperLevel - inkLevel <= 0.15) return null
        val paper = DoubleArray(3)
        var paperCount = 0
        for (i in 0 until n) if (luma[i] >= paperLevel) { for (c in 0 until 3) paper[c] += ch(i, c); paperCount++ }
        for (c in 0 until 3) paper[c] /= max(paperCount, 1)
        val start = paperLevel - 0.06
        val full = paperLevel - (paperLevel - inkLevel) * 0.5
        val alpha = DoubleArray(n) { ((start - luma[it]) / max(start - full, 1e-6)).coerceIn(0.0, 1.0) }
        var minX = w; var minY = h; var maxX = -1; var maxY = -1
        for (y in 0 until h) for (x in 0 until w) if (alpha[y * w + x] > 0.2) { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        if (maxX < minX || maxY < minY) return null
        val inkHeight = (maxY - minY + 1).toDouble()
        val boxHeight = max(inkHeight / INK_HEIGHT_FRACTION, 1.0)
        val margin = boxHeight * 6 / 50
        val outW = ((maxX - minX + 1) + 2 * margin).roundToInt()
        val outH = boxHeight.roundToInt()
        val originX = (minX - margin).roundToInt()
        val originY = (minY - (boxHeight - inkHeight) / 2).roundToInt()
        val out = ByteArray(outW * outH * 4)
        for (oy in 0 until outH) for (ox in 0 until outW) {
            val x = originX + ox
            val y = originY + oy
            if (x !in 0 until w || y !in 0 until h) continue
            val i = y * w + x
            val a = alpha[i]
            if (a <= 0) continue
            val o = (oy * outW + ox) * 4
            for (c in 0 until 3) out[o + c] = (((ch(i, c) - (1 - a) * paper[c]) / a).coerceIn(0.0, 1.0) * 255).roundToInt().toByte()
            out[o + 3] = (a * 255).roundToInt().toByte()
        }
        return Rgba8Image(outW, outH, out)
    }
}
