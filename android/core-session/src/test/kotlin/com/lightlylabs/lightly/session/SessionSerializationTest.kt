package com.lightlylabs.lightly.session

import com.lightlylabs.lightly.session.SessionFixtures.auto
import com.lightlylabs.lightly.session.SessionFixtures.newSession
import com.lightlylabs.lightly.session.SessionFixtures.portra
import com.lightlylabs.lightly.session.SessionFixtures.source
import kotlinx.serialization.SerializationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * The JSON below is the contract shape shared with iOS. If one of these golden strings has to
 * change, that is a schema change: bump EditState.CURRENT_SCHEMA and record why in the commit.
 */
class SessionSerializationTest {

    private val goldenEditState =
        """{"schema":1,""" +
            """"source":{"assetId":"content://media/picker/0/42",""" +
            """"fingerprint":{"headSha256":"${"ab".repeat(32)}","byteSize":1048576,"pixelWidth":4032,"pixelHeight":3024},""" +
            """"orientation":6},""" +
            """"auto":{"modelId":"ia3dlut","modelVersion":"research-fivek-1","weights":[1.5,-0.25,-0.75],""" +
            """"guardrail":"endpoint-v1","strength":0.75},""" +
            """"look":{"lookId":"film.portra","lookVersion":2,"strength":0.8},""" +
            """"revision":7}"""

    private val stateWithLook = EditState(source = source, auto = auto, look = portra, revision = 7)

    @Test
    fun `EditState encodes to the golden JSON`() {
        assertEquals(goldenEditState, SessionJson.encodeToString(EditState.serializer(), stateWithLook))
    }

    @Test
    fun `golden JSON decodes to the same EditState`() {
        assertEquals(stateWithLook, SessionJson.decodeFromString(EditState.serializer(), goldenEditState))
    }

    @Test
    fun `no Look and no guardrail are written as explicit nulls`() {
        val state = EditState(source = source, auto = auto.copy(guardrail = null), look = null, revision = 0)

        val json = SessionJson.encodeToString(EditState.serializer(), state)

        assertEquals(
            goldenEditState
                .replace(""""guardrail":"endpoint-v1"""", """"guardrail":null""")
                .replace(""""look":{"lookId":"film.portra","lookVersion":2,"strength":0.8}""", """"look":null""")
                .replace(""""revision":7""", """"revision":0"""),
            json,
        )
    }

    @Test
    fun `a whole session round-trips including cursor and revision counter`() {
        val session = newSession().selectLook(portra).setLookStrength(0.3f).undo()

        val json = SessionJson.encodeToString(EditSession.serializer(), session)
        val decoded = SessionJson.decodeFromString(EditSession.serializer(), json)

        assertEquals(session, decoded)
        assertEquals(1, decoded.history.cursor)
        assertEquals(2, decoded.lastIssuedRevision)
        // Encoding is deterministic: re-encoding the decoded value gives identical bytes.
        assertEquals(json, SessionJson.encodeToString(EditSession.serializer(), decoded))
    }

    @Test
    fun `unknown keys and schemas are rejected rather than half-read`() {
        assertFailsWith<SerializationException> {
            SessionJson.decodeFromString(EditState.serializer(), goldenEditState.replace("{\"schema\":1,", "{\"schema\":1,\"extra\":true,"))
        }
        assertFailsWith<IllegalArgumentException> {
            SessionJson.decodeFromString(EditState.serializer(), goldenEditState.replace("\"schema\":1", "\"schema\":2"))
        }
    }

    @Test
    fun `out-of-range strength in JSON is rejected`() {
        assertFailsWith<IllegalArgumentException> {
            SessionJson.decodeFromString(EditState.serializer(), goldenEditState.replace("\"strength\":0.8", "\"strength\":1.5"))
        }
    }
}
