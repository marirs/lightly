package com.lightlylabs.lightly.session

import kotlinx.serialization.json.Json

/**
 * The one JSON configuration used for EditState, SavedStateHandle and recovery snapshots.
 *
 * - `encodeDefaults` + `explicitNulls`: `schema` and `look: null` are always written, so the bytes
 *   do not depend on whether a value happens to equal its Kotlin default. iOS reads the same JSON.
 * - `ignoreUnknownKeys = false`: a snapshot from an unknown (newer) schema fails to decode and is
 *   discarded, rather than being half-read into a state that renders differently.
 */
val SessionJson: Json = Json {
    encodeDefaults = true
    explicitNulls = true
    ignoreUnknownKeys = false
    prettyPrint = false
}
