package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.editor.FixtureLookPack.Category
import com.lightlylabs.lightly.editor.FixtureLookPack.Stop
import com.lightlylabs.lightly.editor.FixtureLookPack.with
import com.lightlylabs.lightly.render.lut.Lut3D
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LookPackLoaderTest {

    private val alphaBeta = listOf(
        Category("c-2", "Beta", listOf(Stop("zeta-1", "Zeta (11)", 1), Stop("alpha-2", "Alpha Tone (3)", 2), Stop("mid-3", "Mid", 3))),
        Category("c-1", "Alpha", listOf(Stop("only-4", "Only One", 4))),
    )

    @Test
    fun `categories, labels and stops keep manifest order and text exactly`() {
        val book = FixtureLookPack.book(alphaBeta)

        assertEquals(listOf("c-2", "c-1"), book.categories.map { it.id }, "not sorted by id or label")
        assertEquals(listOf("Beta", "Alpha"), book.categories.map { it.label })
        assertEquals(listOf("Zeta (11)", "Alpha Tone (3)", "Mid"), book.stops("c-2").map { it.name }, "not sorted by name")
        assertTrue(book.problems.isEmpty())
        assertNull(book.unavailableReason)
    }

    @Test
    fun `a Look's LUT is the manifest's file, decoded in contract layout`() {
        val book = FixtureLookPack.book(alphaBeta)
        val look = book.stops("c-1").single()

        assertContentEquals(Lut3D.fromLittleEndianBytes(FixtureLookPack.lutBytes(4)).rgba, look.lut.rgba)
        assertEquals(look, book.find(look.ref()))
        assertEquals(1, book.stopIndexOf("c-1", look.ref()))
        assertEquals(0, book.stopIndexOf("c-2", look.ref()), "a Look is only a stop in its own category")
    }

    @Test
    fun `a LUT whose sha256 does not match is dropped and reported, the rest still load`() {
        val files = FixtureLookPack.files(alphaBeta)
        files[FixtureLookPack.lutPath("alpha-2")] = FixtureLookPack.lutBytes(9) // right size, wrong pixels

        val book = LookPackLoader.load(FixtureLookPack.source(files))

        assertEquals(listOf("zeta-1", "mid-3"), book.stops("c-2").map { it.lookId })
        assertEquals(1, book.problems.size)
        assertTrue(book.problems.single().startsWith("alpha-2: LUT sha256"), book.problems.single())
    }

    @Test
    fun `a missing or truncated LUT file is dropped and reported`() {
        val files = FixtureLookPack.files(alphaBeta)
        files.remove(FixtureLookPack.lutPath("zeta-1"))
        files[FixtureLookPack.lutPath("mid-3")] = FixtureLookPack.lutBytes(3).copyOf(1000)

        val book = LookPackLoader.load(FixtureLookPack.source(files))

        assertEquals(listOf("alpha-2"), book.stops("c-2").map { it.lookId })
        assertEquals(2, book.problems.size, book.problems.toString())
    }

    @Test
    fun `a category left with no Looks is dropped and reported`() {
        val files = FixtureLookPack.files(alphaBeta)
        files.remove(FixtureLookPack.lutPath("only-4"))

        val book = LookPackLoader.load(FixtureLookPack.source(files))

        assertEquals(listOf("c-2"), book.categories.map { it.id })
        assertTrue(book.problems.any { it.startsWith("Category c-1") }, book.problems.toString())
    }

    @Test
    fun `a LUT path outside the pack is refused`() {
        val files = FixtureLookPack.files(alphaBeta)
        val manifest = files.getValue(LookPackLoader.MANIFEST).decodeToString()
        files[LookPackLoader.MANIFEST] = manifest.replace("\"luts/only-4.f32\"", "\"../secrets/only-4.f32\"").encodeToByteArray()
        files["../secrets/only-4.f32"] = FixtureLookPack.lutBytes(4)

        val book = LookPackLoader.load(FixtureLookPack.source(files))

        assertNull(book.category("c-1"))
        assertTrue(book.problems.any { it.contains("leaves the pack") }, book.problems.toString())
    }

    @Test
    fun `no pack gives an empty book with a reason`() {
        val book = LookPackLoader.load(FixtureLookPack.source(emptyMap()))

        assertTrue(book.isEmpty)
        assertEquals(LookPackLoader.NO_PACK_REASON, book.unavailableReason)
    }

    @Test
    fun `a manifest of another format, version, LUT size or encoding gives an empty book with a reason`() {
        val cases = mapOf(
            "format" to JsonPrimitive("lightroom-presets"),
            "formatVersion" to JsonPrimitive(2),
            "lutDimension" to JsonPrimitive(17),
            "lutEncoding" to JsonPrimitive("rgb-float16"),
        )
        cases.forEach { (field, value) ->
            val book = LookPackLoader.load(FixtureLookPack.source(FixtureLookPack.files(alphaBeta) { it.with(field, value) }))
            assertTrue(book.isEmpty, field)
            assertNotNull(book.unavailableReason, field)
        }
    }

    @Test
    fun `a manifest that is not JSON gives an empty book with a reason`() {
        val book = LookPackLoader.load(FixtureLookPack.source(mapOf(LookPackLoader.MANIFEST to "{ not json".encodeToByteArray())))

        assertTrue(book.isEmpty)
        assertNotNull(book.unavailableReason)
    }

    @Test
    fun `the approximation flag follows lutSource and validation`() {
        val validated = Stop("hald-1", "Checked", 1, lutSource = "lightroom-hald", validation = "validated")
        assertEquals(false, FixtureLookPack.book(listOf(Category("c", "C", listOf(validated)))).hasApproximateLooks)

        val haldUnvalidated = Stop("hald-2", "Unchecked", 2, lutSource = "lightroom-hald", validation = "unvalidated")
        assertEquals(true, FixtureLookPack.book(listOf(Category("c", "C", listOf(validated, haldUnvalidated)))).hasApproximateLooks)

        val model = Stop("model-3", "Model", 3, lutSource = "lr-model-approximation", validation = "validated")
        assertEquals(true, FixtureLookPack.book(listOf(Category("c", "C", listOf(validated, model)))).hasApproximateLooks)
    }

    @Test
    fun `the same Look in two categories is one Look`() {
        val shared = Stop("shared-1", "Shared", 1)
        val book = FixtureLookPack.book(listOf(Category("a", "A", listOf(shared)), Category("b", "B", listOf(Stop("other-2", "Other", 2), shared))))

        val look = book.stops("a").single()
        assertEquals(2, book.stopIndexOf("b", look.ref()))
        assertTrue(book.problems.isEmpty())
    }
}
