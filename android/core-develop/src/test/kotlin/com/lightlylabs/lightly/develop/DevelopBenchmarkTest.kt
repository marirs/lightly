package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.lut.Lut3D
import java.util.concurrent.Executors
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Host-JVM timings (for orientation only; the targets in docs/v1/preset-pack.md apply to devices and
 * are measured on the emulator by the app's debug benchmark). Also proves the FULL built pack parses
 * and every one of its 2,591 recipes bakes, when the pack has been built in this checkout.
 */
class DevelopBenchmarkTest {
    private val model = LookPackFixtures.model

    @Test
    fun `bake timings over the parity presets`() {
        val presets = LookPackFixtures.parityPack.categories.flatMap { it.presets }
        val pool = Executors.newFixedThreadPool(4)
        try {
            repeat(2) { presets.forEach { LutBaker.bake(DevelopGlobal(it.recipe.global, model), executor = pool, parallelism = 4) } } // warm-up
            val times = presets.map { preset ->
                val start = System.nanoTime()
                LutBaker.bake(DevelopGlobal(preset.recipe.global, model), Lut3D.CONTRACT_DIMENSION, pool, 4)
                (System.nanoTime() - start) / 1e6
            }.sorted()
            println("host 33³ bake (4 threads): median ${"%.1f".format(times[times.size / 2])} ms, p95 ${"%.1f".format(times[(times.size * 95) / 100])} ms")
        } finally {
            pool.shutdown()
        }
    }

    @Test
    fun `the full built pack parses and every recipe bakes`() {
        val manifest = LookPackFixtures.builtManifest ?: run {
            println("shared/look-pack/out/manifest.json is not built in this checkout; full-pack check not run")
            return
        }
        val text = manifest.readText()
        val start = System.nanoTime()
        val pack = LookPack.parse(text, model)
        println("host manifest parse: ${"%.0f".format((System.nanoTime() - start) / 1e6)} ms for ${pack.presetCount} presets")
        assertEquals(2591, pack.presetCount)
        assertEquals(listOf("portrait", "landscape", "film", "cinematic", "street", "travel", "wedding", "golden-hour", "black-white"), pack.categories.map { it.id })
        val pool = Executors.newFixedThreadPool(4)
        try {
            pack.categories.flatMap { it.presets }.forEach { preset ->
                LutBaker.bake(DevelopGlobal(preset.recipe.global, model), dimension = 9, executor = pool, parallelism = 4)
                preset.recipe.spatial
                preset.recipe.finishing
            }
        } finally {
            pool.shutdown()
        }
    }
}
