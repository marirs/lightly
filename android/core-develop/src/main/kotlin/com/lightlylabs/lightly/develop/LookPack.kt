package com.lightlylabs.lightly.develop

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** One coverage record (`approximated`, `unsupported`, `notApplied`): a reason code and the source keys. */
data class CoverageRecord(val code: String, val keys: List<String>)

/**
 * One preset of the format-3 pack (docs/v1/preset-pack.md › Per preset). Display fields are the
 * approved catalogue's, verbatim. The recipe is parsed on first use: browsing the catalogue only
 * needs names and stops, and parsing 2,591 recipes up front would cost cold-start time for nothing.
 */
class LookPreset(
    val id: String,
    val displayName: String,
    val categoryId: String,
    /** 1-based position in its category (stop 0 is Auto/Original, which is not a preset). */
    val stop: Int,
    val lookVersion: String,
    val recipeVersion: Int,
    val operators: List<String>,
    val completeness: String,
    val approximated: List<CoverageRecord>,
    val unsupported: List<CoverageRecord>,
    val notApplied: List<CoverageRecord>,
    val hasGrain: Boolean,
    val hasVignette: Boolean,
    val validationStatus: String,
    private val recipeJson: JsonObject,
) {
    val recipe: PresetRecipe by lazy { PresetRecipe.parse(recipeJson) }

    /** The raw recipe object, for [LookVersion] (hashing needs the original literals). */
    val recipeObject: JsonObject get() = recipeJson
}

class LookCategory(val id: String, val name: String, val presets: List<LookPreset>)

/**
 * Reader for the format-3 look pack written by `shared/look-pack/build_pack.py` (`manifest.json`).
 *
 * The pack must be the one this build's [DevelopModel] describes: a different model id, version or
 * constants digest means the Look versions in it were computed for other constants, so the pack is
 * refused instead of rendering every Look subtly differently from its recorded version.
 */
class LookPack(
    val formatVersion: Int,
    val provisional: Boolean,
    val categories: List<LookCategory>,
) {
    private val byId: Map<String, LookPreset> = categories.flatMap { it.presets }.associateBy { it.id }

    fun preset(id: String): LookPreset? = byId[id]

    fun category(id: String): LookCategory? = categories.firstOrNull { it.id == id }

    val presetCount: Int get() = byId.size

    companion object {
        const val FORMAT = "lightly-look-pack"
        const val FORMAT_VERSION = 3
        const val RECIPE_VERSION = 1

        fun parse(json: String, model: DevelopModel): LookPack = parse(Json.parseToJsonElement(json).jsonObject, model)

        fun parse(root: JsonObject, model: DevelopModel): LookPack {
            require(root.string("format") == FORMAT) { "Not a Lightly look pack" }
            val format = root.getValue("formatVersion").jsonPrimitive.int
            require(format == FORMAT_VERSION) { "Look pack format $format is not supported (expected $FORMAT_VERSION)" }
            require(root.getValue("recipeVersion").jsonPrimitive.int == RECIPE_VERSION) { "Unsupported recipeVersion" }
            val packModel = root.getValue("developModel").jsonObject
            require(packModel.string("id") == model.id && packModel.getValue("version").jsonPrimitive.int == model.version &&
                packModel.string("constantsSha256") == model.constantsSha256) {
                "The look pack was built for a different Develop model (${packModel.string("constantsSha256")} != ${model.constantsSha256})"
            }
            val provisional = root["status"]?.jsonObject?.get("state")?.jsonPrimitive?.content == "provisional"
            val categories = root.getValue("categories").jsonArray.map { element ->
                val category = element.jsonObject
                val categoryId = category.string("id")
                val presets = category.getValue("presets").jsonArray.map { presetOf(it.jsonObject, categoryId) }
                LookCategory(categoryId, category.string("name"), presets)
            }
            val ids = categories.flatMap { c -> c.presets.map { it.id } }
            require(ids.size == ids.toSet().size) { "Duplicate preset ids in the look pack" }
            return LookPack(format, provisional, categories)
        }

        private fun presetOf(p: JsonObject, categoryId: String): LookPreset {
            val id = p.string("id")
            // No HALD override is implemented by this port; none exists today (all null). Refusing one
            // keeps a future pack from rendering the model where it promises a validated Lightroom LUT.
            require(p["globalOverride"] == null || p["globalOverride"] is JsonNull) { "Preset $id has a globalOverride, which this build cannot render" }
            val effects = p.getValue("effects").jsonObject
            return LookPreset(
                id = id,
                displayName = p.string("displayName"),
                categoryId = categoryId,
                stop = p.getValue("stop").jsonPrimitive.int,
                lookVersion = p.string("lookVersion"),
                recipeVersion = p.getValue("recipeVersion").jsonPrimitive.int.also { require(it == RECIPE_VERSION) { "Preset $id recipeVersion $it" } },
                operators = p.getValue("operators").jsonArray.map { it.jsonPrimitive.content },
                completeness = p.string("completeness"),
                approximated = coverage(p["approximated"]),
                unsupported = coverage(p["unsupported"]),
                notApplied = coverage(p["notApplied"]),
                hasGrain = effects.getValue("grain").jsonPrimitive.boolean,
                hasVignette = effects.getValue("vignette").jsonPrimitive.boolean,
                validationStatus = p["validation"]?.jsonObject?.get("status")?.let { (it as? JsonPrimitive)?.content } ?: "approximate",
                recipeJson = p.getValue("recipe").jsonObject,
            )
        }

        private fun coverage(element: kotlinx.serialization.json.JsonElement?): List<CoverageRecord> =
            (element as? JsonArray).orEmpty().map { record ->
                val o = record.jsonObject
                CoverageRecord(o.string("code"), o["keys"]?.jsonArray.orEmpty().map { it.jsonPrimitive.content })
            }
    }
}
