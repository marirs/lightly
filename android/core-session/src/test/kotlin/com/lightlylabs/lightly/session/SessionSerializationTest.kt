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
import kotlinx.serialization.SerializationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * The saved-edit contract, checked against the files in shared/fixtures/edit-state/ that iOS reads
 * too. If one of these files has to change, that is a schema change for both platforms.
 */
class SessionSerializationTest {

    private val stateWithLook = EditState(source = source, auto = auto, look = portra, revision = 7)
    private val stateWithoutLook = EditState(source = source, auto = auto.copy(guardrail = null), look = null, revision = 0)

    @Test
    fun `EditState with a Look encodes byte-exactly to the shared v2 fixture`() {
        assertEquals(read(V2_WITH_LOOK), SavedEdits.encodeEditState(stateWithLook))
    }

    @Test
    fun `the shared v2 fixture decodes to the same EditState`() {
        assertEquals(stateWithLook, SavedEdits.decodeEditState(read(V2_WITH_LOOK)))
    }

    @Test
    fun `no Look and no guardrail are written as explicit nulls, byte-exactly`() {
        assertEquals(read(V2_NO_LOOK), SavedEdits.encodeEditState(stateWithoutLook))
        assertEquals(stateWithoutLook, SavedEdits.decodeEditState(read(V2_NO_LOOK)))
    }

    // v3 differs from the M2 contract on purpose: schema 1 used to be rejected and the edit dropped
    // (test "a schema 1 edit with a numeric lookVersion is rejected, not reinterpreted"). The shared
    // contract now requires migration, so that test is replaced by the two below.

    @Test
    fun `a schema 1 edit is migrated to exactly the shared v1-migrated-to-v2 fixture`() {
        val migrated = SavedEdits.decodeEditState(read(V1_NUMERIC_LOOK_VERSION))

        assertEquals(read(V1_MIGRATED_TO_V2), SavedEdits.encodeEditState(migrated))
        assertEquals("legacy-v1-2", migrated.look?.lookVersion)
        assertEquals(SavedEdits.decodeEditState(read(V1_MIGRATED_TO_V2)), migrated)
    }

    @Test
    fun `migration keeps everything except schema and lookVersion`() {
        val migrated = SavedEdits.decodeEditState(read(V1_NUMERIC_LOOK_VERSION))

        assertEquals(stateWithLook.copy(look = portra.copy(lookVersion = "legacy-v1-2")), migrated)
    }

    @Test
    fun `a schema 1 edit without a Look migrates by bumping the schema only`() {
        val schemaOne = read(V2_NO_LOOK).replace("\"schema\":2", "\"schema\":1")

        assertEquals(read(V2_NO_LOOK), SavedEdits.encodeEditState(SavedEdits.decodeEditState(schemaOne)))
    }

    @Test
    fun `a schema 1 edit whose lookVersion is not an integer is rejected, not guessed`() {
        val textVersion = read(V1_NUMERIC_LOOK_VERSION).replace("\"lookVersion\":2", "\"lookVersion\":\"2\"")
        assertFailsWith<IllegalArgumentException> { SavedEdits.decodeEditState(textVersion) }
        val fractional = read(V1_NUMERIC_LOOK_VERSION).replace("\"lookVersion\":2", "\"lookVersion\":2.5")
        assertFailsWith<IllegalArgumentException> { SavedEdits.decodeEditState(fractional) }
    }

    @Test
    fun `an unknown key is rejected rather than half-read`() {
        assertFailsWith<SerializationException> { SavedEdits.decodeEditState(read(INVALID_UNKNOWN_KEY)) }
    }

    @Test
    fun `a future schema is rejected`() {
        assertFailsWith<IllegalArgumentException> { SavedEdits.decodeEditState(read(INVALID_FUTURE_SCHEMA)) }
    }

    @Test
    fun `an out-of-range strength is rejected`() {
        assertFailsWith<IllegalArgumentException> { SavedEdits.decodeEditState(read(INVALID_STRENGTH_OUT_OF_RANGE)) }
    }

    @Test
    fun `a whole session round-trips including cursor and revision counter`() {
        val session = newSession().selectLook(portra).setLookStrength(0.3f).undo()

        val json = SavedEdits.encodeEditSession(session)
        val decoded = SavedEdits.decodeEditSession(json)

        assertEquals(session, decoded)
        assertEquals(1, decoded.history.cursor)
        assertEquals(2, decoded.lastIssuedRevision)
        // Encoding is deterministic: re-encoding the decoded value gives identical bytes.
        assertEquals(json, SavedEdits.encodeEditSession(decoded))
    }

    @Test
    fun `a saved session whose entries are schema 1 migrates every entry`() {
        // What SavedStateHandle holds after an update from a schema 1 build: the history entries are
        // the shared v1 EditState (baseline without a Look, then the v1 Look).
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
}
