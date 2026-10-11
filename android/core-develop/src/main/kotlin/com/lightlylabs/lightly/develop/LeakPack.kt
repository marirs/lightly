package com.lightlylabs.lightly.develop

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** One leak of the pack: its stable id, display name, files (relative to the pack root) and the image's size and digest. */
data class LeakPackEntry(
    val id: String,
    val name: String,
    /** `img/<id>.jpg`: the overlay the renderer screens over the frame. */
    val image: String,
    /** `thumb/<id>.jpg`: the panel's tile. */
    val thumbnail: String,
    val imageSha256: String,
    val width: Int,
    val height: Int,
)

/**
 * The light-leak pack (format "lightly-leak-pack" 1, shared/leaks/build_leaks.py, owner 2026-10-11), in pack order: the
 * Light Leaks gallery lists the leaks in this order after None. Git-ignored like the look pack, so a build without it has
 * an empty pack and the gallery offers only None.
 */
class LeakPack(val leaks: List<LeakPackEntry>) {
    private val byId = leaks.associateBy { it.id }

    fun entry(id: String): LeakPackEntry? = byId[id]

    companion object {
        const val FORMAT = "lightly-leak-pack"
        const val FORMAT_VERSION = 1

        /** Where both apps bundle the pack: the manifest and its img/ and thumb/ beside it. */
        const val ASSET_ROOT = "leakpack/"
        const val ASSET_MANIFEST = "leakpack/leaks.json"

        val EMPTY = LeakPack(emptyList())

        private val ID = Regex("^leak-[0-9a-f]{12}$")
        private val SHA256 = Regex("^[0-9a-f]{64}$")

        /**
         * Parses and checks leaks.json. The file paths must be exactly `img/<id>.jpg` and `thumb/<id>.jpg`: they are joined
         * onto the asset root, so a manifest must not be able to name any other file.
         */
        fun parse(text: String): LeakPack {
            val root = Json.parseToJsonElement(text).jsonObject
            val format = root["format"]?.jsonPrimitive?.content
            val version = root["formatVersion"]?.jsonPrimitive?.int
            require(format == FORMAT && version == FORMAT_VERSION) { "leak pack is $format $version; this app reads $FORMAT $FORMAT_VERSION" }
            val leaks = root.getValue("leaks").jsonArray.map { entry(it.jsonObject) }
            require(leaks.map { it.id }.toSet().size == leaks.size) { "leak pack repeats an id" }
            return LeakPack(leaks)
        }

        private fun entry(o: JsonObject): LeakPackEntry {
            fun text(key: String) = o.getValue(key).jsonPrimitive.content
            val id = text("id")
            require(ID.matches(id)) { "leak id $id is not leak-<12 lowercase hex>" }
            val entry = LeakPackEntry(id, text("name"), text("image"), text("thumbnail"), text("imageSha256"),
                o.getValue("width").jsonPrimitive.int, o.getValue("height").jsonPrimitive.int)
            require(entry.image == "img/$id.jpg" && entry.thumbnail == "thumb/$id.jpg") { "leak $id files are ${entry.image}, ${entry.thumbnail}" }
            require(SHA256.matches(entry.imageSha256)) { "leak $id has no lowercase SHA-256" }
            require(entry.width > 0 && entry.height > 0 && entry.name.isNotBlank()) { "leak $id has no size or name" }
            return entry
        }
    }
}
