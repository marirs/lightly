package com.lightlylabs.lightly.prefs

import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

// Pinned: with no @Config Robolectric uses targetSdk 37; on SDK 36+ its ApplicationSharedMemory set-up fails on JDK 25 (2026-10-19), as the other tests pin 35.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class PresetPackSizeTest {
    @Test
    fun `counts distinct presets and categories, skipping recipes`() {
        val manifest = """{"format":3,"categories":[
            {"id":"a","name":"A","presets":[{"id":"p1","recipe":{"global":{"x":[1,2]}}},{"id":"p2"}]},
            {"id":"b","name":"B","presets":[{"id":"p2"},{"id":"p3","displayName":"Three"}]}]}"""
        assertEquals(PresetPackSize(presets = 3, categories = 2), PresetPackSize.count(manifest.reader()))
    }

    @Test
    fun `the bundled look pack is counted, not a typed-in number`() {
        val bundled = listOf("../../shared/look-pack/out/manifest.json", "../shared/look-pack/out/manifest.json").map(::File).firstOrNull { it.exists() } ?: return
        val size = bundled.reader().use(PresetPackSize::count)
        assert(size.presets > 0 && size.categories > 0) { "empty pack: $size" }
    }
}
