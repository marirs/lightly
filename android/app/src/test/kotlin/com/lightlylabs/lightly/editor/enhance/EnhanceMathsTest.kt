package com.lightlylabs.lightly.editor.enhance

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Enhance engine (1.3): the tile layout, mirrored reads, detection scale and alignment check exactly as the Mac copy
 * (experiments/enhance-2026-11-12/phone_pipeline.py) and the iOS engine (EnhanceEngineTests).
 */
class EnhanceMathsTest {

    @Test
    fun tileWindowsCoverEveryPixelOnceWithContext() {
        val tile = EnhanceEngine.TILE
        val pad = EnhanceEngine.TILE_PAD
        for (size in listOf(1, 100, 383, 384, 385, 800, 1200, 1676, 4032)) {
            val windows = EnhanceMaths.tileWindows(size, tile, pad)
            var next = 0
            for ((kept, length, start) in windows) {
                assertEquals("size $size: kept ranges must be contiguous", next, kept)
                assertTrue(length > 0)
                next = kept + length
                if (size > tile) {
                    assertTrue(start >= 0 && start + tile <= size)
                    // Every kept pixel has >= 16 px of context on its inner sides (README step 2e).
                    if (kept > 0) assertTrue(kept - start >= pad)
                    if (next < size) assertTrue(start + tile - next >= pad)
                } else {
                    assertEquals(1, windows.size)
                    assertEquals(0, start)
                }
            }
            assertEquals(size, next)
        }
    }

    /** Python's tile_windows for 1200 and 1676 px (phone_pipeline.tile_windows, printed 2026-11-17). */
    @Test
    fun tileWindowsMatchTheMacCopy() {
        assertEquals(listOf(listOf(0, 328, 0), listOf(328, 272, 272), listOf(600, 272, 544), listOf(872, 328, 816)),
            EnhanceMaths.tileWindows(1200, 384, 16).map { listOf(it.first, it.second, it.third) })
        assertEquals(listOf(listOf(0, 353, 0), listOf(353, 323, 323), listOf(676, 323, 646), listOf(999, 323, 969), listOf(1322, 354, 1292)),
            EnhanceMaths.tileWindows(1676, 384, 16).map { listOf(it.first, it.second, it.third) })
    }

    @Test
    fun mirrorIndexReflectsWithoutRepeatingTheEdge() {
        assertEquals(listOf(0, 1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1), (0 until 12).map { EnhanceMaths.mirrorIndex(it, 4) })
        assertEquals(listOf(0, 0, 0), (0 until 3).map { EnhanceMaths.mirrorIndex(it, 1) })
        assertEquals((0 until 500).toList(), (0 until 500).map { EnhanceMaths.mirrorIndex(it, 500) })
    }

    @Test
    fun detectionScaleKeepsFittingPhotosAndFitsLongOnes() {
        assertEquals(640.0 / 1200, EnhanceMaths.detectionScale(1200, 1676, 640, 1024), 0.0)
        assertEquals(1024.0 / 3000, EnhanceMaths.detectionScale(3000, 1000, 640, 1024), 0.0)
        assertEquals(1536.0 / 3000, EnhanceMaths.detectionScale(1000, 3000, 960, 1536), 0.0)
    }

    /** Python's input_size (phone_pipeline.input_size, printed 2026-11-17): the owner's 2000 px long-side cap. */
    @Test
    fun inputSizeCapsTheLongSideAt2000() {
        val cases = listOf(
            (4032 to 3024) to (2000 to 1500), (3000 to 1000) to (2000 to 667), (1000 to 2001) to (1000 to 2000),
            (2000 to 10) to (2000 to 10), (5000 to 1) to (2000 to 1), (1200 to 1676) to (1200 to 1676),
        )
        for ((input, expected) in cases) {
            assertEquals("$input", expected, EnhanceMaths.inputSize(input.first, input.second, EnhanceEngine.INPUT_LONG_SIDE_MAX))
        }
    }

    @Test
    fun collapsedOrNonFinitePointsCannotAlign() {
        val face = arrayOf(doubleArrayOf(100.0, 100.0), doubleArrayOf(130.0, 100.0), doubleArrayOf(115.0, 115.0),
            doubleArrayOf(104.0, 130.0), doubleArrayOf(126.0, 130.0))
        assertTrue(EnhanceEngine.canAlign(face))
        assertFalse(EnhanceEngine.canAlign(Array(5) { doubleArrayOf(207.3, 152.7) }))
        assertFalse(EnhanceEngine.canAlign(face.copyOf().also { it[2] = doubleArrayOf(Double.NaN, 1.0) }))
    }
}
