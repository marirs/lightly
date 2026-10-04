package com.lightlylabs.lightly.signatures

import com.lightlylabs.lightly.render.image.Rgba8Image
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Import a signature (approved `wm-sig-import`): "The paper is removed. The ink keeps its original colour
 * and texture." The same algorithm and constants as iOS (SignatureInkExtractor.swift), so both platforms
 * agree on the same inputs:
 * - the paper is estimated locally (the 90th luma percentile of 32 px blocks, spread to the brightest 3 × 3
 *   neighbour and interpolated), so uneven lighting does not survive as a tinted rectangle;
 * - a pixel's ink coverage rises from well above the paper's grain to full at half the ink's contrast;
 *   below [ALPHA_FLOOR], and anywhere more than [INK_PROXIMITY] px from ink, it is exactly 0;
 * - its colour is un-mixed from the local paper colour, C = (P − (1 − α)·paper)/α, so the ink keeps its hue
 *   without a paper fringe;
 * - the result is cropped to the ink and padded like the prototype's signature (the ink spans 32 of 50
 *   units of height, 6 units of margin each side).
 * Returns straight (not premultiplied) RGBA, or null when no ink stands out from the paper.
 */
object SignatureInkExtractor {
    const val INK_HEIGHT_FRACTION = 32.0 / 50
    /** Coverage below this is paper: exactly transparent. */
    const val ALPHA_FLOOR = 0.12
    /** Partial coverage is kept only this close to ink (px, at the working size). */
    const val INK_PROXIMITY = 4
    /** Luma spread (98th − 2nd percentile) below which a page holds nothing to import (iOS `blankSpread`). */
    const val BLANK_SPREAD = 0.04
    private const val PAPER_BLOCK = 32

    fun luma(image: Rgba8Image): DoubleArray {
        val p = image.pixels
        return DoubleArray(image.width * image.height) {
            (0.2126 * (p[it * 4].toInt() and 0xff) + 0.7152 * (p[it * 4 + 1].toInt() and 0xff) + 0.0722 * (p[it * 4 + 2].toInt() and 0xff)) / 255
        }
    }

    /** True when the image holds nothing to import: its luma spread is under [BLANK_SPREAD]. */
    fun isBlank(image: Rgba8Image): Boolean {
        val sorted = luma(image).sortedArray()
        val n = sorted.size
        return sorted[((n - 1) * 0.98).toInt()] - sorted[((n - 1) * 0.02).toInt()] < BLANK_SPREAD
    }

    fun extract(image: Rgba8Image): Rgba8Image? {
        val w = image.width
        val h = image.height
        val n = w * h
        val p = image.pixels
        fun ch(i: Int, c: Int) = (p[i * 4 + c].toInt() and 0xff) / 255.0
        val luma = luma(image)
        // The paper's own level, locally: lighting and shadows make a photographed page uneven, so a single
        // global level leaves its darker parts as a faint tinted rectangle.
        val paperLuma = localPaperLevel(luma, w, h)
        val paperRgb = localPaperColour(image, luma, paperLuma)
        val difference = DoubleArray(n) { max(paperLuma[it] - luma[it], 0.0) }
        val inkContrast = difference.sortedArray()[((n - 1) * 0.98).toInt()]
        if (inkContrast <= 0.15) return null
        val start = max(0.06, inkContrast * 0.22)
        val full = inkContrast * 0.5
        val alpha = DoubleArray(n) {
            val a = ((difference[it] - start) / max(full - start, 1e-6)).coerceIn(0.0, 1.0)
            if (a < ALPHA_FLOOR) 0.0 else a
        }
        // Feathering only near ink: coverage survives only within INK_PROXIMITY px of a core pixel
        // (coverage ≥ 0.5); everything else is paper and becomes exactly transparent.
        val near = dilate(BooleanArray(n) { alpha[it] >= 0.5 }, w, h, INK_PROXIMITY)
        for (i in 0 until n) if (!near[i]) alpha[i] = 0.0
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
            for (c in 0 until 3) out[o + c] = (((ch(i, c) - (1 - a) * paperRgb[i * 3 + c]) / a).coerceIn(0.0, 1.0) * 255).roundToInt().toByte()
            out[o + 3] = (a * 255).roundToInt().toByte()
        }
        return Rgba8Image(outW, outH, out)
    }

    /** The paper's luma around each pixel: the 90th percentile of 32 px blocks, spread and interpolated (as iOS). */
    internal fun localPaperLevel(luma: DoubleArray, width: Int, height: Int): DoubleArray {
        val block = PAPER_BLOCK
        val bw = (width + block - 1) / block
        val bh = (height + block - 1) / block
        val levels = DoubleArray(bw * bh)
        for (by in 0 until bh) for (bx in 0 until bw) {
            val values = ArrayList<Double>()
            for (y in by * block until min((by + 1) * block, height)) for (x in bx * block until min((bx + 1) * block, width)) values += luma[y * width + x]
            values.sort()
            levels[by * bw + bx] = values[((values.size - 1) * 0.9).toInt()]
        }
        // A block that is mostly ink takes the brightest neighbour (3 × 3), so strokes never set the paper.
        val spread = DoubleArray(bw * bh) { index ->
            val bx = index % bw
            val by = index / bw
            var best = levels[index]
            for (dy in -1..1) for (dx in -1..1) {
                val x = bx + dx
                val y = by + dy
                if (x in 0 until bw && y in 0 until bh) best = max(best, levels[y * bw + x])
            }
            best
        }
        // Bilinear between block centres.
        val out = DoubleArray(width * height)
        for (y in 0 until height) {
            val fy = ((y + 0.5) / block - 0.5).coerceIn(0.0, (bh - 1).toDouble())
            val y0 = fy.toInt(); val y1 = min(y0 + 1, bh - 1); val ty = fy - y0
            for (x in 0 until width) {
                val fx = ((x + 0.5) / block - 0.5).coerceIn(0.0, (bw - 1).toDouble())
                val x0 = fx.toInt(); val x1 = min(x0 + 1, bw - 1); val tx = fx - x0
                val top = spread[y0 * bw + x0] * (1 - tx) + spread[y0 * bw + x1] * tx
                val bottom = spread[y1 * bw + x0] * (1 - tx) + spread[y1 * bw + x1] * tx
                out[y * width + x] = top * (1 - ty) + bottom * ty
            }
        }
        return out
    }

    /** The paper's colour around each pixel (RGB triples): the page's mean paper hue at the local paper brightness. */
    private fun localPaperColour(image: Rgba8Image, luma: DoubleArray, paperLuma: DoubleArray): DoubleArray {
        val p = image.pixels
        val sum = DoubleArray(3)
        var count = 0.0
        var lumaSum = 0.0
        for (i in luma.indices) if (luma[i] >= paperLuma[i] - 0.02) {
            for (c in 0 until 3) sum[c] += (p[i * 4 + c].toInt() and 0xff) / 255.0
            lumaSum += luma[i]; count++
        }
        val hue = if (count > 0) DoubleArray(3) { sum[it] / count } else doubleArrayOf(1.0, 1.0, 1.0)
        val hueLuma = if (count > 0) lumaSum / count else 1.0
        val out = DoubleArray(luma.size * 3)
        for (i in luma.indices) for (c in 0 until 3) out[i * 3 + c] = (hue[c] * (paperLuma[i] / max(hueLuma, 1e-6))).coerceIn(0.0, 1.0)
        return out
    }

    /** Square dilation of a mask (separable max). */
    internal fun dilate(mask: BooleanArray, width: Int, height: Int, radius: Int): BooleanArray {
        val horizontal = BooleanArray(mask.size)
        for (y in 0 until height) for (x in 0 until width) {
            var hit = false
            for (dx in max(0, x - radius)..min(width - 1, x + radius)) if (mask[y * width + dx]) { hit = true; break }
            horizontal[y * width + x] = hit
        }
        val out = BooleanArray(mask.size)
        for (x in 0 until width) for (y in 0 until height) {
            var hit = false
            for (dy in max(0, y - radius)..min(height - 1, y + radius)) if (horizontal[dy * width + x]) { hit = true; break }
            out[y * width + x] = hit
        }
        return out
    }
}
