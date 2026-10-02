package com.lightlylabs.lightly.session

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/**
 * The single entry point for reading and writing saved edits (SavedStateHandle, recovery snapshots,
 * the shared fixtures). Every decode goes through [migrate], so an edit written by a schema 1 build
 * is upgraded instead of being dropped (shared/fixtures/edit-state/README.md, spec §4.5).
 *
 * Decoding stays strict after migration: unknown keys, unknown schemas and out-of-range values are
 * still rejected by [SessionJson] and the model's `init` checks.
 *
 * @throws kotlinx.serialization.SerializationException for malformed JSON or unknown keys.
 * @throws IllegalArgumentException for an unsupported schema or an invalid value.
 */
object SavedEdits {
    /** `legacy-v1-<n>`: never equals a pack version, so a migrated Look always resolves as "changed". */
    const val LEGACY_V1_VERSION_PREFIX = "legacy-v1-"

    private const val SCHEMA_1 = 1

    fun encodeEditState(state: EditState): String = SessionJson.encodeToString(EditState.serializer(), state)

    fun decodeEditState(json: String): EditState =
        SessionJson.decodeFromJsonElement(EditState.serializer(), migrateEditState(SessionJson.parseToJsonElement(json)))

    fun encodeEditSession(session: EditSession): String = SessionJson.encodeToString(EditSession.serializer(), session)

    fun decodeEditSession(json: String): EditSession =
        SessionJson.decodeFromJsonElement(EditSession.serializer(), migrateEditSession(SessionJson.parseToJsonElement(json)))

    fun encodeRecoverySnapshot(snapshot: RecoverySnapshot): String = SessionJson.encodeToString(RecoverySnapshot.serializer(), snapshot)

    /** The snapshot's own schema is unchanged; only the EditStates inside its session are migrated. */
    fun decodeRecoverySnapshot(json: String): RecoverySnapshot {
        val root = SessionJson.parseToJsonElement(json)
        val migrated = if (root is JsonObject && root["session"] != null) {
            JsonObject(root + ("session" to migrateEditSession(root.getValue("session"))))
        } else {
            root
        }
        return SessionJson.decodeFromJsonElement(RecoverySnapshot.serializer(), migrated)
    }

    /** Migrates every history entry; anything that is not the expected shape is left for the decoder to reject. */
    private fun migrateEditSession(session: JsonElement): JsonElement {
        val history = (session as? JsonObject)?.get("history") as? JsonObject ?: return session
        val entries = history["entries"] as? JsonArray ?: return session
        val migratedHistory = JsonObject(history + ("entries" to JsonArray(entries.map(::migrateEditState))))
        return JsonObject(session + ("history" to migratedHistory))
    }

    /**
     * Schema 1 → 2: `look.lookVersion` (a hand-numbered integer) becomes `"legacy-v1-<n>"`; nothing
     * else changes. Schema 2 and every other schema pass through untouched, so the decoder decides.
     * Key order is irrelevant: the result is re-encoded through the serializer.
     */
    private fun migrateEditState(state: JsonElement): JsonElement {
        if (state !is JsonObject) return state
        val schema = (state["schema"] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
        if (schema != SCHEMA_1) return state
        val look = state["look"]
        val migratedLook = when {
            look == null || look is JsonNull -> look
            look is JsonObject -> JsonObject(look + ("lookVersion" to JsonPrimitive(legacyVersion(look["lookVersion"]))))
            else -> look // not an object: the decoder rejects it
        }
        val upgraded = state + ("schema" to JsonPrimitive(EditState.CURRENT_SCHEMA))
        return JsonObject(if (migratedLook == null) upgraded else upgraded + ("look" to migratedLook))
    }

    /** Only a JSON integer is a schema 1 version; a string or fraction is refused rather than guessed. */
    private fun legacyVersion(version: JsonElement?): String {
        val primitive = version as? JsonPrimitive
        val number = primitive?.takeIf { !it.isString && it.content.all { char -> char.isDigit() || char == '-' } }?.longOrNull
        require(number != null) { "Schema 1 lookVersion must be an integer, was $version" }
        return "$LEGACY_V1_VERSION_PREFIX$number"
    }
}
