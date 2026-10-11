package com.lightlylabs.lightly.session

import com.lightlylabs.lightly.session.SessionFixtures.auto
import com.lightlylabs.lightly.session.SessionFixtures.newSession
import com.lightlylabs.lightly.session.SessionFixtures.portra
import com.lightlylabs.lightly.session.SessionFixtures.source
import com.lightlylabs.lightly.session.SharedEditStateFixtures.INVALID_FUTURE_SCHEMA
import com.lightlylabs.lightly.session.SharedEditStateFixtures.INVALID_STRENGTH_OUT_OF_RANGE
import com.lightlylabs.lightly.session.SharedEditStateFixtures.INVALID_UNKNOWN_KEY
import com.lightlylabs.lightly.session.SharedEditStateFixtures.V1_MIGRATED_TO_V2
import com.lightlylabs.lightly.session.SharedEditStateFixtures.V1_NUMERIC_LOOK_VERSION
import com.lightlylabs.lightly.session.SharedEditStateFixtures.V2_NO_LOOK
import com.lightlylabs.lightly.session.SharedEditStateFixtures.V2_WITH_LOOK
import com.lightlylabs.lightly.session.SharedEditStateFixtures.read
import com.lightlylabs.lightly.session.SharedEditStateFixtures.readRecipe
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The saved-edit contract (EditState schema 3, edit recipe v1), checked against the files iOS reads
 * too: shared/fixtures/edit-recipe/ (schema 3) and shared/fixtures/edit-state/ (schemas 1 and 2, now
 * migrated on read). If one of these files has to change, that is a schema change for both platforms.
 */
class SessionSerializationTest {

    private val validRecipeFixtures = SharedEditStateFixtures.recipeFixtureNames.filterNot { it.startsWith("invalid-") }
    private val invalidRecipeFixtures = SharedEditStateFixtures.recipeFixtureNames.filter { it.startsWith("invalid-") }

    @Test
    fun `the shared fixture set is complete`() {
        assertEquals(25, validRecipeFixtures.size, "valid edit-recipe fixtures: $validRecipeFixtures")   // 25th: effects-selective-colour
        assertEquals(8, invalidRecipeFixtures.size, "invalid edit-recipe fixtures: $invalidRecipeFixtures")
    }

    /**
     * rendering-v2 revision 7 (owner amendments 2026-10-11): `tools.text` and `faceEdit.smile` are optional on read and
     * always written. A fixture saved before them re-encodes to its own bytes with exactly those defaults added, where
     * edit-recipe-v1.json places them (text after border; smile between teeth and hair).
     */
    private fun withRevision7Defaults(fixture: String): String {
        val root = Json.parseToJsonElement(fixture).jsonObject
        val tools = root.getValue("tools").jsonObject
        val portrait = tools.getValue("portrait").jsonObject
        val faces = JsonArray(portrait.getValue("faces").jsonArray.map { face ->
            val entries = face.jsonObject
            if ("smile" in entries) entries else JsonObject(buildMap {
                entries.forEach { (key, value) ->
                    if (key == "hair") put("smile", buildJsonObject { put("amount", JsonPrimitive(0)) })
                    put(key, value)
                }
            })
        })
        val newTools = JsonObject(buildMap {
            tools.forEach { (key, value) -> put(key, if (key == "portrait") JsonObject(portrait + ("faces" to faces)) else value) }
            if ("text" !in tools) put("text", buildJsonObject { put("layers", JsonArray(emptyList())) })
        })
        return Json.encodeToString(JsonElement.serializer(), JsonObject(root + ("tools" to newTools)))
    }

    @Test
    fun `every valid schema 3 fixture decodes and re-encodes to identical bytes`() {
        val failures = validRecipeFixtures.mapNotNull { name ->
            val text = readRecipe(name)
            try {
                val encoded = SavedEdits.encodeEditState(SavedEdits.decodeEditState(text))
                val expected = withRevision7Defaults(text)
                if (encoded == expected) null else "$name re-encodes differently:\n  expected $expected\n  actual   $encoded"
            } catch (failure: Exception) {
                "$name does not decode: $failure"
            }
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"))
    }

    @Test
    fun `every invalid schema 3 fixture is rejected as a whole`() {
        for (name in invalidRecipeFixtures) {
            val rejected = try {
                SavedEdits.decodeEditState(readRecipe(name)); false
            } catch (expected: SerializationException) {
                true
            } catch (expected: IllegalArgumentException) {
                true
            }
            assertTrue(rejected, "$name must be rejected")
        }
    }

    @Test
    fun `the neutral fixture is exactly a new edit with no Auto model`() {
        val noModel = AutoResult(AutoResult.MODEL_ID_IA3DLUT, "no-model-in-build", listOf(0f, 0f, 0f), null, 0f)
        assertEquals(withRevision7Defaults(readRecipe("neutral.json")), SavedEdits.encodeEditState(EditState.initial(source, noModel)))
    }

    @Test
    fun `a schema 2 edit migrates to exactly the shared migrated-from-v2 fixture`() {
        val migrated = SavedEdits.decodeEditState(read(V2_WITH_LOOK))
        assertEquals(withRevision7Defaults(readRecipe("migrated-from-v2-with-look.json")), SavedEdits.encodeEditState(migrated))
        assertEquals(2880154539L, migrated.tools.effects.grain.seed) // first 32 bits of headSha256 "abab…"
    }

    @Test
    fun `migration from schema 2 keeps source, auto, look and revision unchanged`() {
        val migrated = SavedEdits.decodeEditState(read(V2_WITH_LOOK))
        assertEquals(EditState(source = source, auto = auto, look = portra, revision = 7, tools = EditTools.neutral(2880154539L)), migrated)
        val noLook = SavedEdits.decodeEditState(read(V2_NO_LOOK))
        assertEquals(null, noLook.look)
        assertEquals(null, noLook.auto.guardrail)
    }

    @Test
    fun `a schema 1 edit migrates through schema 2 to schema 3`() {
        val viaOne = SavedEdits.decodeEditState(read(V1_NUMERIC_LOOK_VERSION))
        assertEquals("legacy-v1-2", viaOne.look?.lookVersion)
        assertEquals(SavedEdits.decodeEditState(read(V1_MIGRATED_TO_V2)), viaOne)
        assertEquals(EditState.CURRENT_SCHEMA, viaOne.schema)
    }

    @Test
    fun `a schema 1 edit whose lookVersion is not an integer is rejected, not guessed`() {
        val textVersion = read(V1_NUMERIC_LOOK_VERSION).replace("\"lookVersion\":2", "\"lookVersion\":\"2\"")
        assertRejected(textVersion)
        val fractional = read(V1_NUMERIC_LOOK_VERSION).replace("\"lookVersion\":2", "\"lookVersion\":2.5")
        assertRejected(fractional)
    }

    @Test
    fun `the schema 2 era invalid fixtures are still rejected`() {
        assertRejected(read(INVALID_UNKNOWN_KEY))
        // Written when schema 3 did not exist: a schema 3 document without recipeVersion and tools.
        assertRejected(read(INVALID_FUTURE_SCHEMA))
        assertRejected(read(INVALID_STRENGTH_OUT_OF_RANGE))
    }

    @Test
    fun `a whole session round-trips including cursor and revision counter`() {
        val session = newSession().selectLook(portra).setLookStrength(0.3f).undo()

        val json = SavedEdits.encodeEditSession(session)
        val decoded = SavedEdits.decodeEditSession(json)

        assertEquals(session, decoded)
        assertEquals(1, decoded.history.cursor)
        assertEquals(2, decoded.lastIssuedRevision)
        assertEquals(json, SavedEdits.encodeEditSession(decoded))
    }

    @Test
    fun `a saved session whose entries are schema 1 migrates every entry`() {
        val v1WithLook = read(V1_NUMERIC_LOOK_VERSION)
        val v1Baseline = v1WithLook.replace(""""look":{"lookId":"film.portra","lookVersion":2,"strength":0.8}""", "\"look\":null")
            .replace("\"revision\":7", "\"revision\":0")
        val json = """{"history":{"entries":[$v1Baseline,$v1WithLook],"cursor":1,"capacity":50},"lastIssuedRevision":7}"""

        val session = SavedEdits.decodeEditSession(json)

        assertEquals(2, session.history.entries.size)
        assertEquals(null, session.history.entries[0].look)
        assertEquals(SavedEdits.decodeEditState(read(V1_MIGRATED_TO_V2)), session.current)
        assertTrue(session.history.entries.all { it.schema == EditState.CURRENT_SCHEMA })
    }

    @Test
    fun `canonical numbers follow Python's repr`() {
        assertEquals("40", CanonicalNumber.format(40.0))
        assertEquals("-3", CanonicalNumber.format(-3.0))
        assertEquals("0.75", CanonicalNumber.format(0.75))
        assertEquals("0.015", CanonicalNumber.format(0.015))
        assertEquals("1e-05", CanonicalNumber.format(0.00001))
        assertEquals("0.0001", CanonicalNumber.format(0.0001))
        assertEquals("1.5e-07", CanonicalNumber.format(1.5e-7))
    }

    @Test
    fun `a recipe without text or smile reads them as no layers and amount 0, and writes them`() {
        val decoded = SavedEdits.decodeEditState(readRecipe("portrait-two-faces.json"))
        assertEquals(TextTool(emptyList()), decoded.tools.text)
        assertTrue(decoded.tools.portrait.faces.isNotEmpty())
        assertTrue(decoded.tools.portrait.faces.all { it.smile == Smile(0.0) })
        val encoded = SavedEdits.encodeEditState(decoded)
        assertTrue(encoded.endsWith(""","text":{"layers":[]}}}"""), encoded)
        assertTrue(""""teeth":{"brighten":""" in encoded && ""","smile":{"amount":0},"hair":""" in encoded, encoded)
    }

    @Test
    fun `text layers and a smile round-trip in canonical order`() {
        val base = SavedEdits.decodeEditState(readRecipe("portrait-two-faces.json"))
        val layers = listOf(
            TextLayer("0a1b2c3d", "Summer in Lisbon", TextFont.PLAYFAIR_DISPLAY, TextWeight.BOLD, 42, "#FFFFFF", 100.0, NormalisedPoint(0.5, 0.5), 0.0),
            TextLayer("ffffff01", "2026\nLine two", TextFont.SPACE_MONO, TextWeight.REGULAR, 18, "#1F2328", 62.5, NormalisedPoint(0.62, 0.86), -4.5),
        )
        val faces = base.tools.portrait.faces.mapIndexed { i, f -> if (i == 0) f.copy(smile = Smile(35.0)) else f }
        val edited = base.copy(tools = base.tools.copy(text = TextTool(layers), portrait = PortraitTool(faces)))
        val encoded = SavedEdits.encodeEditState(edited)
        assertEquals(edited, SavedEdits.decodeEditState(encoded))
        assertEquals(encoded, SavedEdits.encodeEditState(SavedEdits.decodeEditState(encoded)))
        assertTrue(""""text":{"layers":[{"id":"0a1b2c3d","text":"Summer in Lisbon","font":"Playfair Display","weight":"bold","size":42,"colour":"#FFFFFF","opacity":100,"centre":[0.5,0.5],"rotation":0},""" in encoded, encoded)
        assertTrue(""""smile":{"amount":35}""" in encoded, encoded)
    }

    @Test
    fun `text layers outside the schema are rejected`() {
        val base = SavedEdits.encodeEditState(SavedEdits.decodeEditState(readRecipe("neutral.json")))
        fun withLayer(layer: String) = base.replace(""""text":{"layers":[]}""", """"text":{"layers":[$layer]}""")
        val good = """{"id":"0a1b2c3d","text":"Hi","font":"Inter","size":42,"colour":"#FFFFFF","opacity":100,"centre":[0.5,0.5],"rotation":0}"""
        SavedEdits.decodeEditState(withLayer(good))
        assertRejected(withLayer(good.replace("\"0a1b2c3d\"", "\"0A1B2C3D\"")))
        assertRejected(withLayer(good.replace("\"size\":42", "\"size\":9")))
        assertRejected(withLayer(good.replace("\"Inter\"", "\"Lora\"")))
        assertRejected(withLayer(good.replace("\"font\":\"Inter\"", "\"font\":\"Inter\",\"weight\":\"heavy\"")))
        assertRejected(withLayer(good.replace("\"text\":\"Hi\"", "\"text\":\"\"")))
        assertRejected(withLayer(good.replace("\"rotation\":0", "\"rotation\":181")))
        assertRejected(base.replace(""""text":{"layers":[]}""", """"text":{"layers":[$good,$good]}"""))
    }

    @Test
    fun `a text layer without weight reads as regular and is written with it`() {
        val base = SavedEdits.encodeEditState(SavedEdits.decodeEditState(readRecipe("neutral.json")))
        val withoutWeight = """{"id":"0a1b2c3d","text":"Hi","font":"Inter","size":42,"colour":"#FFFFFF","opacity":100,"centre":[0.5,0.5],"rotation":0}"""
        val decoded = SavedEdits.decodeEditState(base.replace(""""text":{"layers":[]}""", """"text":{"layers":[$withoutWeight]}"""))
        assertEquals(TextWeight.REGULAR, decoded.tools.text.layers.single().weight)
        val encoded = SavedEdits.encodeEditState(decoded)
        assertTrue(""""font":"Inter","weight":"regular","size":42""" in encoded, encoded)
    }

    @Test
    fun `every weight and the owner's new Text and Watermark fonts round-trip by their recipe names`() {
        val base = SavedEdits.decodeEditState(readRecipe("neutral.json"))
        val newTextFonts = mapOf(TextFont.RETRO_ROMANCE to "Retro Romance", TextFont.VELOMINO to "Velomino", TextFont.VECTIPEDE_THIN to "Vectipede Thin")
        TextWeight.entries.forEach { weight ->
            newTextFonts.forEach { (font, name) ->
                val layer = TextLayer("0a1b2c3d", "Hi", font, weight, 42, "#FFFFFF", 100.0, NormalisedPoint(0.5, 0.5), 0.0)
                val edited = base.copy(tools = base.tools.copy(text = TextTool(listOf(layer))))
                val encoded = SavedEdits.encodeEditState(edited)
                assertTrue(""""font":"$name","weight":"${weight.name.lowercase()}"""" in encoded, encoded)
                assertEquals(edited, SavedEdits.decodeEditState(encoded))
            }
        }
        val signatureFonts = mapOf(WatermarkFont.CARPENTERS to "Carpenters", WatermarkFont.SOURDOUGH_SCRIPT to "Sourdough Script", WatermarkFont.JAYBIRD to "Jaybird",
            WatermarkFont.ASTORIA to "Astoria", WatermarkFont.BONSKIN to "Bonskin", WatermarkFont.SHAREIT to "Shareit", WatermarkFont.MONTTEE to "Monttee")
        assertEquals(13, WatermarkFont.entries.size)
        assertEquals(11, TextFont.entries.size)
        signatureFonts.forEach { (font, name) ->
            val watermark = base.tools.watermark.copy(type = WatermarkType.TEXT, text = WatermarkText("A. Rivera", font))
            val edited = base.copy(tools = base.tools.copy(watermark = watermark))
            val encoded = SavedEdits.encodeEditState(edited)
            assertTrue(""""text":{"text":"A. Rivera","font":"$name"}""" in encoded, encoded)
            assertEquals(edited, SavedEdits.decodeEditState(encoded))
        }
    }

    private fun assertRejected(json: String) {
        try {
            SavedEdits.decodeEditState(json)
        } catch (expected: SerializationException) {
            return
        } catch (expected: IllegalArgumentException) {
            return
        }
        fail("expected the document to be rejected: $json")
    }
}
