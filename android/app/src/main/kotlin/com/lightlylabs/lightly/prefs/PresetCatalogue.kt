package com.lightlylabs.lightly.prefs

import org.json.JSONObject

/** One Develop preset as the approved catalogue names it. */
data class CataloguePreset(val id: String, val displayName: String, val categoryName: String)

/**
 * The approved Develop catalogue (presets/develop-design-ui.json, bundled verbatim under
 * assets/catalogue/ by app/build.gradle.kts). Slice 1 only needs id → name/category for the
 * favourites page; slice 2 reads the categories and stops from the same file.
 */
class PresetCatalogue private constructor(private val presetsById: Map<String, CataloguePreset>) {

    fun preset(id: String): CataloguePreset? = presetsById[id]

    val size: Int get() = presetsById.size

    companion object {
        const val ASSET_PATH = "catalogue/develop-design-ui.json"

        val EMPTY = PresetCatalogue(emptyMap())

        /** Parses the catalogue JSON. Throws on a malformed file: a broken bundle is a build error. */
        fun parse(json: String): PresetCatalogue {
            val categories = JSONObject(json).getJSONArray("categories")
            val presets = LinkedHashMap<String, CataloguePreset>()
            for (categoryIndex in 0 until categories.length()) {
                val category = categories.getJSONObject(categoryIndex)
                val categoryName = category.getString("name")
                val categoryPresets = category.getJSONArray("presets")
                for (presetIndex in 0 until categoryPresets.length()) {
                    val preset = categoryPresets.getJSONObject(presetIndex)
                    val id = preset.getString("id")
                    presets[id] = CataloguePreset(id, preset.getString("displayName"), categoryName)
                }
            }
            return PresetCatalogue(presets)
        }
    }
}
