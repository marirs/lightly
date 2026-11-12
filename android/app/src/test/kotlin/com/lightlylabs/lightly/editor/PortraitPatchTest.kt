package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.develop.PixelRect
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** Save copy's Portrait patches keep only the box of pixels a retouch or pair changes (device check 2026-11-11). */
class PortraitPatchTest {
    private val region = PixelRect(100, 200, 6, 5)

    private fun pixels(fill: (x: Int, y: Int, channel: Int) -> Int) =
        ByteArray(region.width * region.height * 4) { i -> fill((i / 4) % region.width, (i / 4) / region.width, i % 4).toByte() }

    @Test
    fun unchangedRegionGivesNoPatch() {
        val before = pixels { x, y, c -> x * 10 + y + c }
        assertNull(PortraitSession.Patch.between(region, before, before.copyOf()))
    }

    @Test
    fun alphaOnlyChangeGivesNoPatch() {
        val before = pixels { _, _, _ -> 40 }
        val after = before.copyOf().also { it[3] = 0 }
        assertNull(PortraitSession.Patch.between(region, before, after))
    }

    @Test
    fun patchIsCroppedToTheChangedBoxAndAppliesTheSameChange() {
        val before = pixels { x, y, c -> 50 + x * 7 + y * 3 + c }
        // Changes at (1, 1) red +30 and (3, 2) blue −20: the box is x 1…3, y 1…2.
        val after = before.copyOf()
        after[(1 * region.width + 1) * 4] = (after[(1 * region.width + 1) * 4] + 30).toByte()
        after[(2 * region.width + 3) * 4 + 2] = (after[(2 * region.width + 3) * 4 + 2] - 20).toByte()
        val patch = assertNotNull(PortraitSession.Patch.between(region, before, after))
        assertEquals(PixelRect(101, 201, 3, 2), patch.region)
        assertEquals(30, patch.delta[0].toInt())
        assertEquals(-20, patch.delta[(1 * 3 + 2) * 4 + 2].toInt())
        // Applied over the full region, the cropped patch reproduces `after` exactly.
        val applied = before.copyOf()
        PortraitSession.applyPatches(applied, region, listOf(patch))
        assertContentEquals(after, applied)
    }
}
