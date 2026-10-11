package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.lut.Lut3D
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Table looks (globalOverride source "cube"): manifest parsing, the .f16 file decode and its SHA-256 check, the
 * resample used by thumbnails and drags, and the strength path shared with recipe looks.
 */
class LookTableTest {
    private val model = LookPackFixtures.model
    private val dimension = Lut3D.CONTRACT_DIMENSION

    /** Probe colours inside the cube, on and off the grid, plus the corners where clamping matters. */
    private val probes = listOf(
        floatArrayOf(0f, 0f, 0f), floatArrayOf(1f, 1f, 1f), floatArrayOf(0.5f, 0.5f, 0.5f),
        floatArrayOf(0.13f, 0.71f, 0.42f), floatArrayOf(0.9f, 0.2f, 0.05f), floatArrayOf(0.333f, 0.666f, 0.999f),
    )

    @Test
    fun `a table preset parses with its table and verifies its lookVersion against the table digest`() {
        val bytes = syntheticTableBytes()
        val digest = LookTableDecoder.sha256Hex(bytes)
        val pack = LookPack.parse(manifestWithTablePreset(tablePresetEntry(digest)), model)
        val preset = requireNotNull(pack.preset(TABLE_PRESET_ID)) { "table preset missing" }
        val table = requireNotNull(preset.globalTable) { "no globalTable" }
        assertEquals("luts/$TABLE_PRESET_ID.f16", table.lutFile)
        assertEquals(digest, table.lutSha256)
        assertEquals(33, table.lutDimension)
        assertEquals(LookGlobalTable.ENCODING_RGB_FLOAT16_RED_FASTEST, table.lutEncoding)
        assertEquals("exact-table", preset.validationStatus)
        assertTrue(preset.operators.isEmpty())
        assertTrue(preset.recipe.spatial.isNeutral)
        assertEquals(LookVersion.of(preset.recipeObject, preset.recipeVersion, model, digest), preset.lookVersion)
        assertEquals(preset.lookVersion, LookVersion.of(preset.recipeObject, preset.recipeVersion, model, preset.globalOverrideSha256))
        // The recipe presets around it are untouched.
        assertTrue(pack.categories.flatMap { it.presets }.filter { it.id != TABLE_PRESET_ID }.all { it.globalTable == null && it.globalOverrideSha256 == null })
    }

    @Test
    fun `an override this build cannot render exactly is refused when the pack loads`() {
        val digest = LookTableDecoder.sha256Hex(syntheticTableBytes())
        val variants = mapOf(
            "source" to JsonPrimitive("hald"),
            "lutFile" to JsonPrimitive("../manifest.json"),
            "lutDimension" to JsonPrimitive(17),
            "lutEncoding" to JsonPrimitive("rgb-float32-red-fastest"),
            "lutSha256" to JsonPrimitive("ABC"),
            "unexpected" to JsonPrimitive(true),
        )
        for ((field, value) in variants) {
            val entry = tablePresetEntry(digest)
            val override = JsonObject(entry.getValue("globalOverride").jsonObject + (field to value))
            assertRefused("globalOverride.$field = $value") { LookPack.parse(manifestWithTablePreset(JsonObject(entry + ("globalOverride" to override))), model) }
        }
        val notAnObject = JsonObject(tablePresetEntry(digest) + ("globalOverride" to JsonPrimitive("luts/x.f16")))
        assertRefused("globalOverride as a string") { LookPack.parse(manifestWithTablePreset(notAnObject), model) }
    }

    @Test
    fun `a table look with a recipe global stage is refused when its recipe is read`() {
        val entry = tablePresetEntry(LookTableDecoder.sha256Hex(syntheticTableBytes()))
        val recipe = JsonObject(mapOf("global" to Json.parseToJsonElement("""{"exposure": 0.5}"""), "spatial" to JsonObject(emptyMap()), "finishing" to JsonObject(emptyMap())))
        val preset = LookPack.parse(manifestWithTablePreset(JsonObject(entry + ("recipe" to recipe))), model).preset(TABLE_PRESET_ID)!!
        assertRefused("recipe.global beside a table") { preset.recipe }
    }

    @Test
    fun `the f16 file decodes to the bake layout with alpha 1 and its digest is checked`() {
        val bytes = syntheticTableBytes()
        val lut = LookTableDecoder.decode(bytes, dimension, LookTableDecoder.sha256Hex(bytes))
        for (b in 0 until dimension) for (g in 0 until dimension) for (r in 0 until dimension) {
            val base = lut.entryIndex(r, g, b)
            val expected = syntheticEntry(r, g, b)
            for (channel in 0 until 3) assertEquals("($r,$g,$b)[$channel]", expected[channel], lut.rgba[base + channel], 0f)
            assertEquals(1f, lut.rgba[base + 3], 0f)
        }
        // Null digest: already verified once; decodes without hashing.
        assertEquals(lut.rgba.toList(), LookTableDecoder.decode(bytes, dimension, null).rgba.toList())
    }

    @Test
    fun `a table whose bytes differ from the manifest digest fails`() {
        val bytes = syntheticTableBytes()
        val digest = LookTableDecoder.sha256Hex(bytes)
        val corrupted = bytes.copyOf().also { it[1000] = (it[1000] + 1).toByte() }
        assertRefused("corrupted table") { LookTableDecoder.decode(corrupted, dimension, digest) }
        assertRefused("truncated table") { LookTableDecoder.decode(bytes.copyOf(bytes.size - 2), dimension, null) }
    }

    @Test
    fun `half floats convert exactly, including subnormals, signed zero and infinities`() {
        assertEquals(0f, LookTableDecoder.halfToFloat(0x0000), 0f)
        assertEquals("signed zero keeps its sign", Float.NEGATIVE_INFINITY, 1f / LookTableDecoder.halfToFloat(0x8000), 0f)
        assertEquals(1f, LookTableDecoder.halfToFloat(0x3C00), 0f)
        assertEquals(-2f, LookTableDecoder.halfToFloat(0xC000), 0f)
        assertEquals(65504f, LookTableDecoder.halfToFloat(0x7BFF), 0f)
        assertEquals(Math.pow(2.0, -24.0).toFloat(), LookTableDecoder.halfToFloat(0x0001), 0f)
        assertEquals(1023 * Math.pow(2.0, -24.0).toFloat(), LookTableDecoder.halfToFloat(0x03FF), 0f)
        assertEquals(Float.POSITIVE_INFINITY, LookTableDecoder.halfToFloat(0x7C00), 0f)
        assertTrue(LookTableDecoder.halfToFloat(0x7E00).isNaN())
        // Agrees with the fixtures' independent reference conversion on every half.
        for (half in 0 until 0x10000) {
            val expected = LookPackFixtures.halfToFloat(half)
            val actual = LookTableDecoder.halfToFloat(half)
            if (expected.isNaN()) assertTrue(actual.isNaN()) else assertEquals("half 0x${half.toString(16)}", expected, actual, 0f)
        }
    }

    @Test
    fun `the 17-cubed resample equals the trilinear lookup of the 33-cubed table at its grid points`() {
        val table = LookTableDecoder.decode(syntheticTableBytes(), dimension, null)
        val small = LookTableDecoder.resample(table, 17)
        assertEquals(17, small.dimension)
        val expected = FloatArray(3)
        for (b in 0 until 17) for (g in 0 until 17) for (r in 0 until 17) {
            table.sample(Lut3D.gridValue(r, 17), Lut3D.gridValue(g, 17), Lut3D.gridValue(b, 17), expected)
            val base = small.entryIndex(r, g, b)
            for (channel in 0 until 3) assertEquals("($r,$g,$b)[$channel]", expected[channel], small.rgba[base + channel], 0f)
            assertEquals(1f, small.rgba[base + 3], 0f)
        }
        assertSame("the contract dimension is the table itself", table, LookTableDecoder.resample(table, dimension))
    }

    @Test
    fun `a table preset at strength 1 renders the table and at strength 0 the identity`() {
        val bytes = syntheticTableBytes()
        val preset = LookPack.parse(manifestWithTablePreset(tablePresetEntry(LookTableDecoder.sha256Hex(bytes))), model).preset(TABLE_PRESET_ID)!!
        val table = LookTableDecoder.decode(bytes, dimension, preset.globalTable!!.lutSha256)

        val full = DevelopRenderPlan.of(model, autoLut = null, autoStrength = 0f, lookLut = table, recipe = preset.recipe, strength = 1f)
        assertSame(table, full.lookLut)
        assertTrue("empty recipe spatial and finishing add nothing", !full.hasSpatial && !full.hasFinishing)
        val viaPlan = FloatArray(3)
        val viaTable = FloatArray(3)
        for (probe in probes) {
            full.lookLut!!.sample(probe[0], probe[1], probe[2], viaPlan)
            table.sample(probe[0], probe[1], probe[2], viaTable)
            assertEquals(viaTable.toList(), viaPlan.toList())
        }

        val none = DevelopRenderPlan.of(model, autoLut = null, autoStrength = 0f, lookLut = table, recipe = preset.recipe, strength = 0f)
        assertNull(none.lookLut)
        assertTrue(none.isIdentity)

        // Between, the same identity blend as a recipe look's bake (rendering-v2.md §4.2).
        val half = DevelopRenderPlan.of(model, autoLut = null, autoStrength = 0f, lookLut = table, recipe = preset.recipe, strength = 0.5f)
        assertEquals(table.blendTowardIdentity(0.5f).rgba.toList(), half.lookLut!!.rgba.toList())
    }

    @Test
    fun `every table look in the built pack decodes with its recorded digest and lookVersion`() {
        val manifest = LookPackFixtures.builtManifest ?: run {
            println("shared/look-pack/out/manifest.json not built; skipping the built-pack table check")
            return
        }
        val pack = LookPack.parse(manifest.readText(), model)
        val tables = pack.categories.flatMap { it.presets }.filter { it.globalTable != null }
        for (preset in tables) {
            val table = preset.globalTable!!
            assertEquals("lookVersion of ${preset.id}", preset.lookVersion, LookVersion.of(preset.recipeObject, preset.recipeVersion, model, table.lutSha256))
            LookTableDecoder.decode(File(manifest.parentFile, table.lutFile).readBytes(), table.lutDimension, table.lutSha256)
            assertTrue(preset.recipe.spatial.isNeutral)
        }
        println("built pack: ${tables.size} table looks of ${pack.presetCount} presets verified")
    }

    // --- fixtures ---------------------------------------------------------------------------------------------------

    /** Values on a 1/64 grid: exact in binary16, so the decode can be compared bit for bit. */
    private fun syntheticEntry(r: Int, g: Int, b: Int): FloatArray = floatArrayOf(
        (32 - r) / 32f,
        (g + b) / 64f,
        ((r * 7 + b * 3) % 33) / 32f,
    )

    private fun syntheticTableBytes(): ByteArray {
        val buffer = ByteBuffer.allocate(dimension * dimension * dimension * 6).order(ByteOrder.LITTLE_ENDIAN)
        for (b in 0 until dimension) for (g in 0 until dimension) for (r in 0 until dimension) {
            for (value in syntheticEntry(r, g, b)) buffer.putShort(exactHalf(value).toShort())
        }
        return buffer.array()
    }

    /** float → binary16 for values that are exactly representable as normal halves (or zero); fails otherwise. */
    private fun exactHalf(value: Float): Int {
        if (value == 0f) return 0
        val bits = value.toRawBits()
        val exponent = ((bits ushr 23) and 0xFF) - 127 + 15
        val mantissa = bits and 0x7FFFFF
        check(exponent in 1..30 && mantissa and 0x1FFF == 0) { "$value is not an exact normal half" }
        return ((bits ushr 16) and 0x8000) or (exponent shl 10) or (mantissa ushr 13)
    }

    private fun tablePresetEntry(lutSha256: String): JsonObject {
        val recipe = Json.parseToJsonElement("""{"global": {}, "spatial": {}, "finishing": {}}""").jsonObject
        val lookVersion = LookVersion.of(recipe, LookPack.RECIPE_VERSION, model, lutSha256)
        return Json.parseToJsonElement(
            """{"id": "$TABLE_PRESET_ID", "displayName": "Table Look", "stop": 99, "recipeVersion": 1, "lookVersion": "$lookVersion",
               "operators": [], "recipe": $recipe, "completeness": "complete", "approximated": [], "unsupported": [], "notApplied": [],
               "effects": {"grain": false, "vignette": false},
               "validation": {"status": "exact-table", "binding": {"globalStage": "cube", "lutSha256": "$lutSha256"}},
               "globalOverride": {"source": "cube", "lutFile": "luts/$TABLE_PRESET_ID.f16", "lutSha256": "$lutSha256",
                                  "lutDimension": 33, "lutEncoding": "rgb-float16-red-fastest", "note": "develop.global = this table alone"}}""",
        ).jsonObject
    }

    /** The shared parity manifest (a real format-3 header for this model) with [entry] appended to its first category. */
    private fun manifestWithTablePreset(entry: JsonObject): String {
        val parity = Json.parseToJsonElement(File(LookPackFixtures.directory, "manifest-parity.json").readText()).jsonObject
        val categories = parity.getValue("categories").jsonArray
        val first = categories[0].jsonObject
        val extended = JsonObject(first + ("presets" to JsonArray(first.getValue("presets").jsonArray + entry)))
        return JsonObject(parity + ("categories" to JsonArray(listOf<JsonElement>(extended) + categories.drop(1)))).toString()
    }

    private fun assertRefused(what: String, block: () -> Unit) {
        try {
            block()
        } catch (expected: IllegalArgumentException) {
            return
        }
        fail("$what was accepted")
    }

    private companion object {
        const val TABLE_PRESET_ID = "look-table0000000000000"
    }
}
