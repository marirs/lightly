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
            "formatVersion" to JsonPrimitive(3),
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
    fun `a format 1 pack is rejected with a reason that says so`() {
        // Format 1 had a single `validation` flag that conflated global colour and the full recipe.
        val book = LookPackLoader.load(FixtureLookPack.source(FixtureLookPack.files(alphaBeta) { it.with("formatVersion", JsonPrimitive(1)) }))

        assertTrue(book.isEmpty)
        assertEquals(LookPackLoader.FORMAT_1_REASON, book.unavailableReason)
    }

    @Test
    fun `a stop without the format 2 status fields is dropped and reported`() {
        val files = FixtureLookPack.files(alphaBeta)
        val manifest = files.getValue(LookPackLoader.MANIFEST).decodeToString()
        // Remove only-4's status, as a format 1 manifest relabelled as 2 would lack it.
        val onlyFour = manifest.indexOf("\"lookId\":\"only-4\"")
        val statusAt = manifest.indexOf(",\"status\":\"approximate\"", onlyFour)
        files[LookPackLoader.MANIFEST] = (manifest.substring(0, statusAt) + manifest.substring(statusAt + ",\"status\":\"approximate\"".length)).encodeToByteArray()

        val book = LookPackLoader.load(FixtureLookPack.source(files))

        assertNull(book.category("c-1"))
        assertTrue(book.problems.any { it.startsWith("only-4: missing status") }, book.problems.toString())
    }

    @Test
    fun `a manifest that is not JSON gives an empty book with a reason`() {
        val book = LookPackLoader.load(FixtureLookPack.source(mapOf(LookPackLoader.MANIFEST to "{ not json".encodeToByteArray())))

        assertTrue(book.isEmpty)
        assertNotNull(book.unavailableReason)
    }

    @Test
    fun `the status fields are read verbatim`() {
        val stop = Stop("g-1", "Global", 1, lutSource = "lightroom-hald", status = "global-colour-validated", globalColour = "validated", fullRecipe = "failed")
        val look = FixtureLookPack.book(listOf(Category("c", "C", listOf(stop)))).stops("c").single()

        assertEquals(LookStatus.GLOBAL_COLOUR_VALIDATED, look.status)
        assertEquals(ValidationRecord("validated", "report.json"), look.globalColour)
        assertEquals(ValidationRecord("failed", "report.json"), look.fullRecipe)
        assertEquals("approximate", look.conversion)
    }

    @Test
    fun `the approximate notice follows status, and only fully validated Looks drop it`() {
        val validated = FixtureLookPack.validatedStop("hald-1", "Checked", 1)
        val validatedBook = FixtureLookPack.book(listOf(Category("c", "C", listOf(validated))))
        assertNull(validatedBook.approximationNotice)

        val approximate = Stop("model-2", "Model", 2)
        assertEquals(LookBook.APPROXIMATE_NOTICE, FixtureLookPack.book(listOf(Category("c", "C", listOf(validated, approximate)))).approximationNotice)

        val globalOnly = Stop("hald-3", "Colour only", 3, lutSource = "lightroom-hald", status = "global-colour-validated", globalColour = "validated")
        assertEquals(LookBook.GLOBAL_COLOUR_ONLY_NOTICE, FixtureLookPack.book(listOf(Category("c", "C", listOf(validated, globalOnly)))).approximationNotice)
    }

    @Test
    fun `an unknown status reads as approximate`() {
        val future = Stop("f-1", "Future", 1, status = "checked-by-hand")
        val look = FixtureLookPack.book(listOf(Category("c", "C", listOf(future)))).stops("c").single()

        assertEquals(LookStatus.APPROXIMATE, look.status)
    }

    @Test
    fun `a validated status without the evidence behind it is demoted and reported`() {
        // A model-derived LUT can never be validated (README "LUT source and status").
        val claimed = Stop("m-1", "Claimed", 1, lutSource = "lr-model-approximation", status = "validated", globalColour = "validated", fullRecipe = "validated", omittedOperators = emptyList())
        val book = FixtureLookPack.book(listOf(Category("c", "C", listOf(claimed))))

        assertEquals(LookStatus.APPROXIMATE, book.stops("c").single().status)
        assertTrue(book.problems.any { it.startsWith("m-1: status") }, book.problems.toString())
        assertEquals(LookBook.APPROXIMATE_NOTICE, book.approximationNotice)
    }

    @Test
    fun `the bundled pack, when present, is format 2 with 18 Looks and keeps every name`() {
        val packDirectory = System.getProperty("lightly.lookPackDir")?.let { java.io.File(it) }?.takeIf { it.resolve("manifest.json").isFile }
            ?: return // no pack in this checkout: the APK check covers the shipped pack
        val book = LookPackLoader.load { path -> packDirectory.resolve(path).takeIf { it.isFile }?.readBytes() }

        assertNull(book.unavailableReason)
        assertTrue(book.problems.isEmpty(), book.problems.toString())
        assertEquals(18, book.categories.sumOf { it.stops.size })
        val names = book.categories.flatMap { category -> category.stops.map { it.name } }
        assertTrue("03 Black and White 03" in names && "11 Black and White 11" in names, "both Mono presets ship")
        assertTrue("Nordic Tone (10)" in names)
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
