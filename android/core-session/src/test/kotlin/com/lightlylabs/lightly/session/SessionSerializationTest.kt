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
        assertEquals(24, validRecipeFixtures.size, "valid edit-recipe fixtures: $validRecipeFixtures")
        assertEquals(7, invalidRecipeFixtures.size, "invalid edit-recipe fixtures: $invalidRecipeFixtures")
    }

    @Test
    fun `every valid schema 3 fixture decodes and re-encodes to identical bytes`() {
        val failures = validRecipeFixtures.mapNotNull { name ->
            val text = readRecipe(name)
            try {
                val encoded = SavedEdits.encodeEditState(SavedEdits.decodeEditState(text))
                if (encoded == text) null else "$name re-encodes differently:\n  expected $text\n  actual   $encoded"
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
        assertEquals(readRecipe("neutral.json"), SavedEdits.encodeEditState(EditState.initial(source, noModel)))
    }

    @Test
    fun `a schema 2 edit migrates to exactly the shared migrated-from-v2 fixture`() {
        val migrated = SavedEdits.decodeEditState(read(V2_WITH_LOOK))
        assertEquals(readRecipe("migrated-from-v2-with-look.json"), SavedEdits.encodeEditState(migrated))
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
