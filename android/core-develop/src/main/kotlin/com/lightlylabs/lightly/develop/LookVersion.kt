package com.lightlylabs.lightly.develop

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * rendering-v2.md §4.3: the first 12 hex digits of sha256 over the canonical JSON of
 * `{recipeVersion, recipe, developModel: {id, version, constantsSha256}, globalOverrideSha256}`.
 *
 * The app never needs to recompute it to render (it uses the pack's value); the parity tests do, to
 * prove that the recipe, the model constants and this port agree on what a Look version means.
 */
object LookVersion {
    fun of(recipe: JsonObject, recipeVersion: Int, model: DevelopModel, globalOverrideSha256: String?): String {
        val body = JsonObject(
            mapOf(
                "recipeVersion" to JsonPrimitive(recipeVersion),
                "recipe" to recipe,
                "developModel" to JsonObject(
                    mapOf(
                        "id" to JsonPrimitive(model.id),
                        "version" to JsonPrimitive(model.version),
                        "constantsSha256" to JsonPrimitive(model.constantsSha256),
                    ),
                ),
                "globalOverrideSha256" to (globalOverrideSha256?.let(::JsonPrimitive) ?: JsonNull),
            ),
        )
        return CanonicalJson.sha256Hex(body).substring(0, 12)
    }
}
