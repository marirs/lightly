package com.lightlylabs.lightly.develop

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
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
 * One preset of the format-3 pack (docs/v1/preset-pack.md › Per preset). Display fields (id, name,
 * stop, lookVersion, completeness, effects) are read when the pack is indexed; the rest of the entry
 * (recipe, coverage records, validation) is parsed from its own JSON text on first use. Browsing the
 * catalogue needs only names and stops, and building a tree of 2,591 entries up front took seconds on
 * the emulator (docs/v1/slice2-android.md › Performance).
 */
class LookPreset internal constructor(
    val id: String,
    val displayName: String,
    val categoryId: String,
    /** 1-based position in its category (stop 0 is Auto/Original, which is not a preset). */
    val stop: Int,
    val lookVersion: String,
    val recipeVersion: Int,
    val completeness: String,
    val hasGrain: Boolean,
    val hasVignette: Boolean,
    private val entryText: () -> String,
) {
    private val entry: JsonObject by lazy { Json.parseToJsonElement(entryText()).jsonObject }

    val operators: List<String> get() = entry.getValue("operators").jsonArray.map { it.jsonPrimitive.content }
    val approximated: List<CoverageRecord> get() = coverage(entry["approximated"])
    val unsupported: List<CoverageRecord> get() = coverage(entry["unsupported"])
    val notApplied: List<CoverageRecord> get() = coverage(entry["notApplied"])
    val validationStatus: String get() = entry["validation"]?.jsonObject?.get("status")?.let { (it as? JsonPrimitive)?.content } ?: "approximate"

    /** The raw recipe object, for [LookVersion] (hashing needs the original literals). */
    val recipeObject: JsonObject get() = entry.getValue("recipe").jsonObject

    val recipe: PresetRecipe by lazy { PresetRecipe.parse(recipeObject) }

    private fun coverage(element: JsonElement?): List<CoverageRecord> = (element as? JsonArray).orEmpty().map { record ->
        val o = record.jsonObject
        CoverageRecord(o.string("code"), o["keys"]?.jsonArray.orEmpty().map { it.jsonPrimitive.content })
    }
}

class LookCategory(val id: String, val name: String, val presets: List<LookPreset>)

/** Parses shared/look-pack/names/display-names.json ({"formatVersion": 1, "names": {id: name}}); empty when absent or unknown. */
object PresetDisplayNames {
    const val ASSET_PATH = "catalogue/display-names.json"

    fun parse(json: String?): Map<String, String> {
        if (json.isNullOrBlank()) return emptyMap()
        val root = Json.parseToJsonElement(json).jsonObject
        if (root["formatVersion"]?.jsonPrimitive?.int != 1) return emptyMap()
        return root["names"]?.jsonObject?.mapValues { it.value.jsonPrimitive.content }.orEmpty()
    }
}

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

        /**
         * Indexes the manifest in one pass over its text ([JsonScanner]): top-level fields other than
         * `categories` are parsed normally (they are small); each preset entry is located, its display
         * fields read, and the entry's text range kept for lazy parsing.
         */
        /**
         * [displayNames]: readable names by preset id, shared with iOS (shared/look-pack/names/display-names.json),
         * applied over the manifest's catalogue names; ids, versions and recipes are unchanged.
         */
        fun parse(json: String, model: DevelopModel, displayNames: Map<String, String> = emptyMap()): LookPack {
            val scanner = JsonScanner(json)
            // Memory (completion plan A1 step 4, 2026-10-07): the presets keep the manifest as UTF-8 bytes, not the
            // parsed String. The manifest has non-Latin-1 characters, so ART stores the String as UTF-16: 12.3 MB held
            // for the whole session (13.5 MP stress heap dump), half of that as UTF-8.
            val utf8 = Utf8Text(json)
            val header = mutableMapOf<String, JsonElement>()
            val categories = mutableListOf<LookCategory>()
            scanner.objectFields { key ->
                if (key == "categories") {
                    scanner.arrayItems { categories += scanCategory(scanner, utf8, displayNames) }
                } else {
                    header[key] = scanner.valueElement()
                }
            }
            checkHeader(JsonObject(header), model)
            val ids = categories.flatMap { c -> c.presets.map { it.id } }
            require(ids.size == ids.toSet().size) { "Duplicate preset ids in the look pack" }
            val provisional = (header["status"] as? JsonObject)?.get("state")?.jsonPrimitive?.content == "provisional"
            return LookPack(FORMAT_VERSION, provisional, categories)
        }

        private fun checkHeader(root: JsonObject, model: DevelopModel) {
            require(root.string("format") == FORMAT) { "Not a Lightly look pack" }
            val format = root.getValue("formatVersion").jsonPrimitive.int
            require(format == FORMAT_VERSION) { "Look pack format $format is not supported (expected $FORMAT_VERSION)" }
            require(root.getValue("recipeVersion").jsonPrimitive.int == RECIPE_VERSION) { "Unsupported recipeVersion" }
            val packModel = root.getValue("developModel").jsonObject
            require(packModel.string("id") == model.id && packModel.getValue("version").jsonPrimitive.int == model.version &&
                packModel.string("constantsSha256") == model.constantsSha256) {
                "The look pack was built for a different Develop model (${packModel.string("constantsSha256")} != ${model.constantsSha256})"
            }
        }

        private fun scanCategory(scanner: JsonScanner, utf8: Utf8Text, displayNames: Map<String, String>): LookCategory {
            var id: String? = null
            var name: String? = null
            val pending = mutableListOf<(String) -> LookPreset>()
            scanner.objectFields { key ->
                when (key) {
                    "id" -> id = scanner.string()
                    "name" -> name = scanner.string()
                    "presets" -> scanner.arrayItems { pending += scanPreset(scanner, utf8, displayNames) }
                    else -> scanner.skipValue()
                }
            }
            val categoryId = requireNotNull(id) { "category without id" }
            return LookCategory(categoryId, requireNotNull(name) { "category $categoryId without name" }, pending.map { it(categoryId) })
        }

        /** Reads the display fields of one preset entry and remembers its text range. */
        private fun scanPreset(scanner: JsonScanner, utf8: Utf8Text, displayNames: Map<String, String>): (String) -> LookPreset {
            val start = utf8.byteOffset(scanner.position)
            var id: String? = null
            var displayName: String? = null
            var stop = -1
            var lookVersion: String? = null
            var recipeVersion = -1
            var completeness: String? = null
            var grain: Boolean? = null
            var vignette: Boolean? = null
            var hasRecipe = false
            scanner.objectFields { key ->
                when (key) {
                    "id" -> id = scanner.string()
                    "displayName" -> displayName = scanner.string()
                    "stop" -> stop = scanner.int()
                    "lookVersion" -> lookVersion = scanner.string()
                    "recipeVersion" -> recipeVersion = scanner.int()
                    "completeness" -> completeness = scanner.string()
                    "effects" -> scanner.objectFields { effect ->
                        when (effect) {
                            "grain" -> grain = scanner.boolean()
                            "vignette" -> vignette = scanner.boolean()
                            else -> scanner.skipValue()
                        }
                    }
                    // No HALD override is implemented by this port; none exists today (all null). Refusing one
                    // keeps a future pack from rendering the model where it promises a validated Lightroom LUT.
                    "globalOverride" -> require(scanner.isNull()) { "Preset ${id ?: "?"} has a globalOverride, which this build cannot render" }
                    "recipe" -> { hasRecipe = true; scanner.skipValue() }
                    else -> scanner.skipValue()
                }
            }
            val end = utf8.byteOffset(scanner.position)
            val presetId = requireNotNull(id) { "preset without id" }
            require(recipeVersion == RECIPE_VERSION) { "Preset $presetId recipeVersion $recipeVersion" }
            require(hasRecipe) { "Preset $presetId has no recipe" }
            require(stop >= 1) { "Preset $presetId has no stop" }
            val name = displayNames[presetId] ?: requireNotNull(displayName) { "Preset $presetId has no displayName" }
            val version = requireNotNull(lookVersion) { "Preset $presetId has no lookVersion" }
            val complete = requireNotNull(completeness) { "Preset $presetId has no completeness" }
            val hasGrain = requireNotNull(grain) { "Preset $presetId has no effects" }
            val hasVignette = vignette!!
            // Captured by the preset instead of [utf8], which also holds the String.
            val manifestBytes = utf8.bytes
            return { categoryId ->
                LookPreset(presetId, name, categoryId, stop, version, recipeVersion, complete, hasGrain, hasVignette) { manifestBytes.decode(start, end) }
            }
        }
    }
}

/**
 * The manifest's UTF-16 positions (the [JsonScanner]'s) converted to offsets into its UTF-8 bytes ([bytes]), used only
 * while the manifest is indexed. Positions must be asked for in increasing order (the scanner's order): one pass over
 * the text in total. Every position asked for is at a JSON structural character, never inside a surrogate pair, so a
 * byte range decodes to exactly the substring between the two positions. The presets keep [bytes] (as [Utf8Bytes]),
 * never this object, so the String is released once the manifest is indexed.
 */
internal class Utf8Text(private val text: String) {
    val bytes = Utf8Bytes(text.toByteArray(Charsets.UTF_8))
    private var charIndex = 0
    private var byteIndex = 0

    fun byteOffset(position: Int): Int {
        require(position >= charIndex) { "positions must increase" }
        while (charIndex < position) {
            val code = text[charIndex].code
            // A surrogate pair is 4 bytes in UTF-8: 2 for each of its two UTF-16 units.
            byteIndex += when {
                code < 0x80 -> 1
                code < 0x800 -> 2
                Character.isSurrogate(text[charIndex]) -> 2
                else -> 3
            }
            charIndex++
        }
        return byteIndex
    }
}

/** The manifest as UTF-8 bytes, shared by every preset: [decode] returns one entry's text by its byte range. */
internal class Utf8Bytes(private val bytes: ByteArray) {
    fun decode(start: Int, end: Int): String = String(bytes, start, end - start, Charsets.UTF_8)
}

/**
 * A minimal pull scanner over JSON text: walks objects and arrays without building a tree, skips
 * values by bracket depth (respecting strings and escapes), and hands small values to kotlinx.
 * Positions are UTF-16 indices into the text, so substrings re-parse exactly.
 */
internal class JsonScanner(private val text: String) {
    var position = 0
        private set

    private fun skipWhitespace() {
        while (position < text.length && text[position].isWhitespace()) position++
    }

    private fun expect(char: Char) {
        skipWhitespace()
        require(position < text.length && text[position] == char) { "Expected '$char' at $position" }
        position++
    }

    /** Calls [field] for each key of the object at the cursor; [field] must consume the value. */
    fun objectFields(field: (String) -> Unit) {
        expect('{')
        skipWhitespace()
        if (text[position] == '}') { position++; return }
        while (true) {
            val key = string()
            expect(':')
            skipWhitespace()
            field(key)
            skipWhitespace()
            when (text[position++]) {
                ',' -> continue
                '}' -> return
                else -> throw IllegalArgumentException("Expected ',' or '}' at ${position - 1}")
            }
        }
    }

    /** Calls [item] for each element of the array at the cursor; [item] must consume it. */
    fun arrayItems(item: () -> Unit) {
        expect('[')
        skipWhitespace()
        if (text[position] == ']') { position++; return }
        while (true) {
            skipWhitespace()
            item()
            skipWhitespace()
            when (text[position++]) {
                ',' -> continue
                ']' -> return
                else -> throw IllegalArgumentException("Expected ',' or ']' at ${position - 1}")
            }
        }
    }

    fun string(): String {
        skipWhitespace()
        val start = position
        skipString()
        // Most strings have no escapes: take the characters between the quotes directly.
        if ((start until position).none { text[it] == '\\' }) return text.substring(start + 1, position - 1)
        return Json.parseToJsonElement(text.substring(start, position)).jsonPrimitive.content
    }

    /** A plain JSON integer token (no fraction or exponent). */
    fun int(): Int {
        skipWhitespace()
        val start = position
        skipValue()
        return text.substring(start, position).toInt()
    }

    fun boolean(): Boolean {
        skipWhitespace()
        val value = when {
            text.startsWith("true", position) -> true
            text.startsWith("false", position) -> false
            else -> throw IllegalArgumentException("Expected a boolean at $position")
        }
        skipValue()
        return value
    }

    fun isNull(): Boolean {
        skipWhitespace()
        val isNull = text.startsWith("null", position)
        skipValue()
        return isNull
    }

    /** The value at the cursor as a kotlinx element (for small values only). */
    fun valueElement(): JsonElement {
        skipWhitespace()
        val start = position
        skipValue()
        return Json.parseToJsonElement(text.substring(start, position))
    }

    fun skipValue() {
        skipWhitespace()
        when (text[position]) {
            '"' -> skipString()
            '{', '[' -> {
                var depth = 0
                while (true) {
                    when (text[position]) {
                        '"' -> { skipString(); continue }
                        '{', '[' -> depth++
                        '}', ']' -> { depth--; if (depth == 0) { position++; return } }
                    }
                    position++
                }
            }
            else -> while (position < text.length && text[position] !in ",}] \n\r\t") position++
        }
    }

    private fun skipString() {
        require(text[position] == '"') { "Expected a string at $position" }
        position++
        while (true) {
            when (text[position]) {
                '\\' -> position += 2
                '"' -> { position++; return }
                else -> position++
            }
        }
    }
}
