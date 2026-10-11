package com.lightlylabs.lightly.prefs

import android.util.JsonReader
import java.io.Reader

/**
 * How many presets the editor ships, and in how many categories (About › Presets). Counted from the look pack the
 * editor loads (`lookpack/manifest.json`), never typed in, so adding or removing presets updates About by itself.
 */
data class PresetPackSize(val presets: Int, val categories: Int) {
    companion object {
        /**
         * Streams the manifest and counts each category's distinct preset ids; recipes are skipped, so this stays cheap
         * on the multi-megabyte pack. A preset listed in two categories counts once, as in the editor's index.
         */
        fun count(manifest: Reader): PresetPackSize {
            val ids = HashSet<String>()
            var categories = 0
            JsonReader(manifest).use { json ->
                json.beginObject()
                while (json.hasNext()) {
                    if (json.nextName() != "categories") { json.skipValue(); continue }
                    json.beginArray()
                    while (json.hasNext()) {
                        categories++
                        json.beginObject()
                        while (json.hasNext()) {
                            if (json.nextName() != "presets") { json.skipValue(); continue }
                            json.beginArray()
                            while (json.hasNext()) {
                                json.beginObject()
                                while (json.hasNext()) { if (json.nextName() == "id") ids.add(json.nextString()) else json.skipValue() }
                                json.endObject()
                            }
                            json.endArray()
                        }
                        json.endObject()
                    }
                    json.endArray()
                }
                json.endObject()
            }
            return PresetPackSize(ids.size, categories)
        }
    }
}
