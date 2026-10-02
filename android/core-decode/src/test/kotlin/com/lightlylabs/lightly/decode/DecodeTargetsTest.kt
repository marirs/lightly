package com.lightlylabs.lightly.decode

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class DecodeTargetsTest {

    @Test
    fun `analysis decode lands the long edge on exactly 1024 and keeps aspect`() {
        assertEquals(PixelSize(1024, 768), DecodeTargets.analysisSize(PixelSize(4032, 3024)))
        assertEquals(PixelSize(768, 1024), DecodeTargets.analysisSize(PixelSize(3024, 4032)))
        assertEquals(PixelSize(1024, 576), DecodeTargets.analysisSize(PixelSize(8064, 4536)))
        // 48 MP portrait.
        assertEquals(PixelSize(768, 1024), DecodeTargets.analysisSize(PixelSize(6048, 8064)))
    }

    @Test
    fun `analysis decode is independent of the screen`() {
        // Same Original on a phone and a tablet: there is no screen parameter at all.
        val original = PixelSize(5712, 4284)
        assertEquals(DecodeTargets.analysisSize(original), DecodeTargets.analysisSize(original.copy()))
    }

    @Test
    fun `small Originals are never upscaled`() {
        assertEquals(PixelSize(800, 600), DecodeTargets.analysisSize(PixelSize(800, 600)))
        assertEquals(PixelSize(1024, 1024), DecodeTargets.analysisSize(PixelSize(1024, 1024)))
        assertEquals(PixelSize(800, 600), DecodeTargets.displaySize(PixelSize(800, 600), screenLongestPx = 2400))
    }

    @Test
    fun `display proxy is capped by the screen and by 2732`() {
        assertEquals(PixelSize(2400, 1800), DecodeTargets.displaySize(PixelSize(4032, 3024), screenLongestPx = 2400))
        assertEquals(PixelSize(2732, 2049), DecodeTargets.displaySize(PixelSize(4032, 3024), screenLongestPx = 3200))
    }

    @Test
    fun `extreme aspect keeps a short edge of at least 1`() {
        assertEquals(PixelSize(1024, 1), DecodeTargets.analysisSize(PixelSize(20000, 2)))
    }

    @Test
    fun `Originals above 100 MP are rejected from the header`() {
        DecodeTargets.requireDecodable(PixelSize(10000, 10000)) // exactly 100 MP is allowed
        assertFailsWith<DecodeRejection.TooLarge> { DecodeTargets.requireDecodable(PixelSize(10001, 10000)) }
    }
}
