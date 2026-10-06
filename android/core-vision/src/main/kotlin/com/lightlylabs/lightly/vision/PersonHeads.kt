package com.lightlylabs.lightly.vision

import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.session.NormalisedRect
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Where the approved dim rings go when people are found but no face is usable (prototype `marksFor`, screen
 * `pt-no-usable-face`: rings on the people's heads). Faces seen from behind or in the dark give the face and pose
 * detectors nothing reliable: on the bar photo the only face detection lies on the bottles (landmark presence 1.5e-8)
 * and the only pose detection is the disco ball, while the person segmenter finds the two people the prototype marks
 * (2026-10-06, experiments/android-vision/work/bar-ring). So the rings come from the person matte: one per person
 * region, at the top of the region (the head).
 */
object PersonHeads {
    /**
     * Matte confidence that counts as a person here. Dark, backlit people come out weak: on the bar photo the right-hand
     * person is mostly below 0.5 and falls apart into specks there, while at 0.3 both people the prototype rings are
     * whole regions and the streak at the edge stays out (0.4 already loses the right-hand person).
     */
    const val REGION_CONFIDENCE = 0.3f

    /** A person region must cover this share of the frame and be this wide (drops specks and edge streaks). */
    const val MIN_AREA_FRACTION = 0.005
    const val MIN_WIDTH_FRACTION = 0.03

    /** The crown, where only the head is (shoulders widen below): this share of the region's height, at most this share of its width. */
    private const val CROWN_OF_HEIGHT = 0.15
    private const val CROWN_OF_WIDTH = 0.3
    /** The ring around the head: this much wider than the crown's widest row, round in pixels like the prototype's. */
    private const val RING_SCALE = 1.15

    /** Head rings, left to right, normalised to the matte's frame. */
    fun from(matte: FloatPlane): List<NormalisedRect> {
        val w = matte.width
        val h = matte.height
        val labels = IntArray(w * h)
        val queue = IntArray(w * h)
        val heads = ArrayList<PixelRect>()
        var next = 0
        for (start in 0 until w * h) {
            if (labels[start] != 0 || matte.values[start] <= REGION_CONFIDENCE) continue
            next++
            // 4-connected flood fill of the confident region.
            var head = 0
            var tail = 0
            queue[tail++] = start
            labels[start] = next
            var minX = w; var maxX = -1; var minY = h; var maxY = -1
            while (head < tail) {
                val p = queue[head++]
                val x = p % w
                val y = p / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (q in intArrayOf(if (x > 0) p - 1 else -1, if (x < w - 1) p + 1 else -1, if (y > 0) p - w else -1, if (y < h - 1) p + w else -1)) {
                    if (q >= 0 && labels[q] == 0 && matte.values[q] > REGION_CONFIDENCE) { labels[q] = next; queue[tail++] = q }
                }
            }
            val area = tail
            val regionWidth = maxX - minX + 1
            if (area < MIN_AREA_FRACTION * w * h || regionWidth < MIN_WIDTH_FRACTION * w) continue
            heads += headOf(labels, next, w, minY, maxY - minY + 1, regionWidth)
        }
        return heads.sortedBy { it.x }.map { r -> DetectedFace.clampedRect(r.x / w, r.y / h, r.width / w, r.height / h) }
    }

    private class PixelRect(val x: Double, val y: Double, val width: Double, val height: Double)

    /** The head ring of region [label] in pixels: centred on the crown's pixels, as wide as its widest row (scaled), round. */
    private fun headOf(labels: IntArray, label: Int, w: Int, top: Int, regionHeight: Int, regionWidth: Int): PixelRect {
        val crownRows = max(2, min(CROWN_OF_HEIGHT * regionHeight, CROWN_OF_WIDTH * regionWidth).roundToInt())
        var sumX = 0.0
        var count = 0
        var widest = 1
        for (y in top until top + crownRows) {
            var rowMin = w; var rowMax = -1
            for (x in 0 until w) if (labels[y * w + x] == label) { sumX += x; count++; rowMin = min(rowMin, x); rowMax = max(rowMax, x) }
            if (rowMax >= rowMin) widest = max(widest, rowMax - rowMin + 1)
        }
        val centreX = sumX / max(count, 1) + 0.5
        val size = widest * RING_SCALE
        val margin = (size - widest) / 2
        return PixelRect(centreX - size / 2, top - margin, size, size)
    }
}
