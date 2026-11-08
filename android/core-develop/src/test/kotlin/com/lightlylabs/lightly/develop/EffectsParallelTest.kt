package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.image.Rgba8Image
import java.util.concurrent.Executors
import kotlin.test.Test
import kotlin.test.assertContentEquals

class EffectsParallelTest {
    @Test fun `parallel effects preserve every pixel including alpha and tile origins`() {
        val pool = Executors.newFixedThreadPool(3)
        try {
            val renderer = DevelopRenderer(pool, 3)
            val image = Rgba8Image(97, 83, ByteArray(97 * 83 * 4) { ((it * 31 + 17) % 256).toByte() })
            for (style in listOf("fine", "film", "coarse")) {
                val stage = EffectsStage(EffectsParams(leakEnabled = true, leakStyle = "prism",
                    grainEnabled = true, grainStyle = style, grainSeed = 42,
                    vignetteEnabled = true), FinishingRecipe.NEUTRAL, LookPackFixtures.model, 160, 120)
                assertContentEquals(stage.apply(image, 11, 7).pixels,
                    stage.apply(image, 11, 7, renderer).pixels)
            }
        } finally { pool.shutdownNow() }
    }
    @Test fun `cached finishing fields equal streaming math across strength shape seed and dimensions`() {
        val pool = Executors.newFixedThreadPool(3)
        try {
            val renderer = DevelopRenderer(pool, 3)
            for (width in listOf(97, 81)) {
                val image = Rgba8Image(width, 83, ByteArray(width * 83 * 4) { ((it * 31 + 17) % 256).toByte() })
                for (amount in listOf(1.0, 30.0, 80.0, 30.0)) for (style in listOf("fine", "film", "coarse")) {
                    val params = EffectsParams(leakEnabled = true, leakStyle = "rose", grainEnabled = true,
                        grainStyle = style, grainAmount = amount, grainSeed = width.toLong(),
                        vignetteEnabled = true, vignetteAmount = amount, vignetteSize = width.toDouble())
                    val expected = EffectsStage(params, FinishingRecipe.NEUTRAL, LookPackFixtures.model, width, 83).apply(image)
                    val actual = EffectsStage(params, FinishingRecipe.NEUTRAL, LookPackFixtures.model, width, 83).apply(image, renderer = renderer.cancellable { false })
                    assertContentEquals(expected.pixels, actual.pixels)
                }
            }
        } finally { pool.shutdownNow() }
    }

}
