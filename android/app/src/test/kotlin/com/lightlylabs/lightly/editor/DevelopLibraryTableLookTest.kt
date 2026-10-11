package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.develop.DevelopGlobal
import com.lightlylabs.lightly.develop.LookPreset
import com.lightlylabs.lightly.develop.LookTableDecoder
import com.lightlylabs.lightly.develop.LutBaker
import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.session.AutoResult
import com.lightlylabs.lightly.session.EditState
import com.lightlylabs.lightly.session.LookRef
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef
import java.io.File
import java.util.concurrent.Executors
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Table looks through the real bundled pack: [DevelopLibrary] serves the shipped 33³ table (never a bake of the empty
 * recipe.global) for previews and export, its trilinear resample for thumbnails and drags, and the same strength path
 * as recipe looks.
 */
class DevelopLibraryTableLookTest {
    private val library = BundledPack.library
    private val packDirectory = File(checkNotNull(System.getProperty("lightly.lookPackDir")))

    private val tablePreset: LookPreset by lazy {
        library.pack.categories.flatMap { it.presets }.firstOrNull { it.globalTable != null }
            ?: error("The bundled pack has no table looks")
    }

    private fun shippedTable(preset: LookPreset): Lut3D {
        val table = preset.globalTable!!
        return LookTableDecoder.decode(File(packDirectory, table.lutFile).readBytes(), table.lutDimension, table.lutSha256)
    }

    private fun state(preset: LookPreset, strength: Float): EditState =
        EditState.initial(SourceRef("content://photo/table", SourceFingerprint("cd".repeat(32), 1000, 48, 32), 1), AutoResult("ia3dlut", "no-model-in-build", listOf(0f, 0f, 0f), null, 0f))
            .copy(look = LookRef(preset.id, preset.lookVersion, strength))

    @Test
    fun `a table look at strength 1 renders the shipped table exactly`() {
        val plan = library.planFor(state(tablePreset, 1f))
        val lookLut = assertNotNull(plan.lookLut)
        assertEquals(Lut3D.CONTRACT_DIMENSION, lookLut.dimension)
        assertContentEquals(shippedTable(tablePreset).rgba, lookLut.rgba)
        assertTrue(!plan.hasSpatial && !plan.hasFinishing, "a table look's empty spatial and finishing stages add nothing")
    }

    @Test
    fun `a table look at strength 0 is the identity and in between blends like a recipe look`() {
        assertTrue(library.planFor(state(tablePreset, 0f)).isIdentity)
        val half = assertNotNull(library.planFor(state(tablePreset, 0.4f)).lookLut)
        assertContentEquals(shippedTable(tablePreset).blendTowardIdentity(0.4f).rgba, half.rgba)
    }

    @Test
    fun `thumbnails and drags use the trilinear resample of the table`() {
        val expected = LookTableDecoder.resample(shippedTable(tablePreset), DevelopLibrary.THUMBNAIL_DIMENSION)
        val thumbnail = assertNotNull(library.planFor(state(tablePreset, 1f), lutDimension = DevelopLibrary.THUMBNAIL_DIMENSION).lookLut)
        assertContentEquals(expected.rgba, thumbnail.rgba)
        val drag = assertNotNull(library.planFor(state(tablePreset, 1f), globalOnly = true).lookLut)
        assertEquals(DevelopLibrary.DRAG_DIMENSION, drag.dimension)
        assertContentEquals(LookTableDecoder.resample(shippedTable(tablePreset), DevelopLibrary.DRAG_DIMENSION).rgba, drag.rgba)
    }

    @Test
    fun `a table whose bytes do not match the manifest digest is refused`() {
        val corrupted = File(packDirectory, tablePreset.globalTable!!.lutFile).readBytes().also { it[0] = (it[0] + 1).toByte() }
        val pool = Executors.newSingleThreadExecutor()
        try {
            val corruptLibrary = DevelopLibrary(library.model, library.pack, pool, 1, tableSource = { corrupted })
            assertFailsWith<IllegalArgumentException> { corruptLibrary.lutFor(tablePreset) }
        } finally {
            pool.shutdown()
        }
    }

    @Test
    fun `recipe looks are still baked from their recipe`() {
        val recipePreset = library.pack.categories.flatMap { it.presets }.first { it.globalTable == null }
        val expected = LutBaker.bake(DevelopGlobal(recipePreset.recipe.global, library.model), DevelopLibrary.THUMBNAIL_DIMENSION)
        assertContentEquals(expected.rgba, library.lutFor(recipePreset, DevelopLibrary.THUMBNAIL_DIMENSION).rgba)
    }
}
