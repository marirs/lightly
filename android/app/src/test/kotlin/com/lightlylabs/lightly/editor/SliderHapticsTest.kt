package com.lightlylabs.lightly.editor

import org.junit.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The bipolar slider's detent tick (owner request 2026-11-12): once on reaching 0 or jumping across it. */
class SliderHapticsTest {
    @Test
    fun ticksOnLandingOnZeroFromEitherSide() {
        assertTrue(reachesZero(-1, 0))
        assertTrue(reachesZero(1, 0))
    }

    @Test
    fun ticksWhenAFastDragSkipsZero() {
        assertTrue(reachesZero(-3, 4))
        assertTrue(reachesZero(5, -2))
    }

    @Test
    fun noTickLeavingZeroOrMovingOnOneSide() {
        assertFalse(reachesZero(0, 1))
        assertFalse(reachesZero(0, -1))
        assertFalse(reachesZero(3, 7))
        assertFalse(reachesZero(-7, -3))
        assertFalse(reachesZero(0, 0))
    }
}
