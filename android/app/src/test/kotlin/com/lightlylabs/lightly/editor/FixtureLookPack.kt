package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.render.lut.Lut3D
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

/**
 * Writes tiny Look packs in the real pack format (manifest + 33³ RGBA float32 LUTs) for tests.
 *
 * TEST FIXTURE ONLY: the LUTs are simple per-channel formulas, not presets. Spec §4.5 forbids
 * formula Looks as shipped content, which is why this lives in src/test and nowhere else.
 */
object FixtureLookPack {

    class Stop(
        val lookId: String,
        val name: String,
        /** Seeds the formula so each fixture Look renders differently. */
        val tint: Int,
        val lutSource: String = "lr-model-approximation",
        /** Pack format 2 `status`: approximate | global-colour-validated | validated. */
        val status: String = "approximate",
        val globalColour: String = "not-run",
        val fullRecipe: String = "not-run",
        val omittedOperators: List<String> = listOf("grain"),
    )

    class Category(val id: String, val label: String, val stops: List<Stop>)

    /** A three-category pack used by the editor tests. Labels are deliberately not today's taxonomy. */
    val standardCategories: List<Category> = listOf(
        Category("cat-film", "Film", listOf(Stop("retro-a1", "Retro Wedding Tone (15)", 1), Stop("rainy-b2", "Rainy Tone (10)", 2), Stop("t2-c3", "T2", 3))),
        Category("cat-warm", "Warm", listOf(Stop("earthy-d4", "Earthy Wedding Tone (6)", 4), Stop("nordic-e5", "Nordic Tone (10)", 5))),
        Category("cat-mono", "Mono", listOf(validatedStop("vintage-f6", "Vintage Flim Tone (7)", 6))),
    )

    /**
     * The real catalog's shape: its 5 categories, 18 preset names verbatim and their lookIds, in
     * browse order (experiments/presets/look_pack/README.md). Only the LUTs are fixture formulas, so
     * UI tests run without the git-ignored pack. Labels are provisional in the pack too.
     */
    val catalogShapedCategories: List<Category> = run {
        var tint = 0
        fun stop(lookId: String, name: String) = Stop(lookId, name, ++tint % 9)
        listOf(
            Category("cat-natural", "Natural", listOf(stop("s1-vibes-6de3bf", "S1 - Vibes"), stop("s7-retro-mood-155d3d", "S7 - Retro Mood"), stop("portrait-1-2e3940", "Portrait-1"), stop("08-f77c4a", "08"))),
            Category("cat-warm", "Warm", listOf(stop("earthy-wedding-tone-6-8813aa", "Earthy Wedding Tone (6)"), stop("nordic-tone-10-7b6a3a", "Nordic Tone (10)"), stop("adventure-tone-3-afb354", "Adventure Tone (3)"), stop("golden-hour-9-26b448", "Golden Hour 9"))),
            Category("cat-cool", "Cool", listOf(stop("cinematic-light-tone-11-a047f9", "Cinematic Light Tone (11)"), stop("old-street-4-3070c8", "Old Street-4"), stop("black-paris-tone-11-a01dc1", "Black Paris Tone (11)"))),
            Category("cat-film", "Film", listOf(stop("retro-wedding-tone-15-aa27b2", "Retro Wedding Tone (15)"), stop("rainy-tone-10-faf297", "Rainy Tone (10)"), stop("t2-8d51bb", "T2"), stop("c4-teals-004c94", "C4 - Teals"))),
            Category("cat-mono", "Mono", listOf(stop("vintage-flim-tone-7-e96e54", "Vintage Flim Tone (7)"), stop("03-black-and-white-03-d5341f", "03 Black and White 03"), stop("11-black-and-white-11-f6f246", "11 Black and White 11"))),
        )
    }

    /** A Lightroom-HALD Look with nothing omitted and both validations passed: the only `validated` kind. */
    fun validatedStop(lookId: String, name: String, tint: Int) = Stop(
        lookId, name, tint, lutSource = "lightroom-hald", status = "validated", globalColour = "validated", fullRecipe = "validated", omittedOperators = emptyList(),
    )

    fun standardBook(): LookBook = LookPackLoader.load(source(files(standardCategories)))

    fun book(categories: List<Category>): LookBook = LookPackLoader.load(source(files(categories)))

    fun source(files: Map<String, ByteArray>) = LookPackSource { path -> files[path] }

    /** Pack files keyed by relative path; mutable so a test can corrupt one. */
    fun files(categories: List<Category>, header: (JsonObject) -> JsonObject = { it }): MutableMap<String, ByteArray> {
        val files = mutableMapOf<String, ByteArray>()
        val categoriesJson = buildJsonArray {
            categories.forEach { category ->
                add(buildJsonObject {
                    put("id", category.id)
                    put("label", category.label)
                    put("labelStatus", "provisional")
                    put("stops", buildJsonArray { category.stops.forEach { stop -> add(stopJson(stop, files)) } })
                })
            }
        }
        val manifest = header(buildJsonObject {
            put("format", LookPackLoader.FORMAT)
            put("formatVersion", LookPackLoader.FORMAT_VERSION)
            put("catalogVersion", 1)
            put("lutDimension", Lut3D.CONTRACT_DIMENSION)
            put("lutEncoding", LookPackLoader.LUT_ENCODING)
            put("categories", categoriesJson)
        })
        files[LookPackLoader.MANIFEST] = manifest.toString().encodeToByteArray()
        return files
    }

    /** Replaces one top-level manifest field, for the header validation tests. */
    fun JsonObject.with(key: String, value: JsonPrimitive) = JsonObject(this + (key to value))

    fun lutPath(lookId: String) = "luts/$lookId.f32"

    fun lutBytes(tint: Int): ByteArray {
        val dimension = Lut3D.CONTRACT_DIMENSION
        val buffer = ByteBuffer.allocate(Lut3D.floatCount(dimension) * Float.SIZE_BYTES).order(ByteOrder.LITTLE_ENDIAN)
        val gain = 1f - 0.04f * tint
        for (b in 0 until dimension) for (g in 0 until dimension) for (r in 0 until dimension) {
            buffer.putFloat(Lut3D.gridValue(r, dimension))
            buffer.putFloat(Lut3D.gridValue(g, dimension) * gain)
            buffer.putFloat(Lut3D.gridValue(b, dimension) * gain * gain)
            buffer.putFloat(1f)
        }
        return buffer.array()
    }

    fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun validationJson(status: String) = buildJsonObject {
        put("status", status)
        put("evidence", if (status == "not-run") null else "report.json")
    }

    private fun stopJson(stop: Stop, files: MutableMap<String, ByteArray>): JsonObject {
        val bytes = lutBytes(stop.tint)
        val digest = sha256Hex(bytes)
        files[lutPath(stop.lookId)] = bytes
        return buildJsonObject {
            put("lookId", stop.lookId)
            put("lookVersion", digest.take(12)) // as build_look_pack.py does
            put("name", stop.name)
            put("lutFile", lutPath(stop.lookId))
            put("lutSha256", digest)
            put("lutSource", stop.lutSource)
            put("lightroomHald", null as String?)
            put("omittedOperators", buildJsonArray { stop.omittedOperators.forEach { add(it) } })
            put("approximatedGlobally", JsonArray(emptyList()))
            put("conversion", if (stop.lutSource == "lightroom-hald" && stop.omittedOperators.isEmpty()) "complete" else "approximate")
            put("globalColour", validationJson(stop.globalColour))
            put("fullRecipe", validationJson(stop.fullRecipe))
            put("status", stop.status)
        }
    }
}
