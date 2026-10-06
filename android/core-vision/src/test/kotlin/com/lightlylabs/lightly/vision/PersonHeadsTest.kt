package com.lightlylabs.lightly.vision

import com.lightlylabs.lightly.background.FloatPlane
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PersonHeadsTest {
    /** A person seen from behind: a round head over wider shoulders, in pixels of a w × h matte. */
    private fun person(values: FloatArray, w: Int, headX: Int, headTop: Int, headRadius: Int, shoulderHalf: Int, bottom: Int) {
        val cy = headTop + headRadius
        for (y in headTop until bottom) for (x in 0 until w) {
            val inHead = (x - headX) * (x - headX) + (y - cy) * (y - cy) <= headRadius * headRadius
            val inBody = y >= cy + headRadius - 2 && kotlin.math.abs(x - headX) <= shoulderHalf
            if (inHead || inBody) values[y * w + x] = 1f
        }
    }

    @Test
    fun `one ring per person at the head, left to right, specks and thin streaks ignored`() {
        val w = 400; val h = 600
        val values = FloatArray(w * h)
        person(values, w, headX = 260, headTop = 340, headRadius = 18, shoulderHalf = 60, bottom = 480)
        person(values, w, headX = 120, headTop = 330, headRadius = 20, shoulderHalf = 70, bottom = 500)
        for (y in 100 until 300) values[y * w + 397] = 1f          // a one-pixel streak at the edge
        for (y in 50 until 53) for (x in 50 until 53) values[y * w + x] = 1f  // a speck
        val heads = PersonHeads.from(FloatPlane(w, h, values))
        assertEquals(2, heads.size)
        val (left, right) = heads
        assertTrue(kotlin.math.abs((left.x + left.width / 2) * w - 120) < 4, "left centre ${(left.x + left.width / 2) * w}")
        assertTrue(kotlin.math.abs((right.x + right.width / 2) * w - 260) < 4, "right centre ${(right.x + right.width / 2) * w}")
        assertTrue(kotlin.math.abs(left.y * h - 330) <= 5, "left top ${left.y * h}")  // the ring has a small margin above the crown
        // Head-sized: about the head's diameter, not the shoulders.
        assertTrue(left.width * w in 30.0..60.0, "left width ${left.width * w}")
        assertTrue(left.height * h in 25.0..60.0, "left height ${left.height * h}")
    }

    @Test
    fun `an empty matte has no heads`() {
        assertEquals(emptyList(), PersonHeads.from(FloatPlane(10, 10, FloatArray(100))))
    }
}
