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
        val validation: String = "unvalidated",
    )

    class Category(val id: String, val label: String, val stops: List<Stop>)

    /** A three-category pack used by the editor tests. Labels are deliberately not today's taxonomy. */
    val standardCategories: List<Category> = listOf(
        Category("cat-film", "Film", listOf(Stop("retro-a1", "Retro Wedding Tone (15)", 1), Stop("rainy-b2", "Rainy Tone (10)", 2), Stop("t2-c3", "T2", 3))),
        Category("cat-warm", "Warm", listOf(Stop("earthy-d4", "Earthy Wedding Tone (6)", 4), Stop("nordic-e5", "Nordic Tone (10)", 5))),
        Category("cat-mono", "Mono", listOf(Stop("vintage-f6", "Vintage Flim Tone (7)", 6, lutSource = "lightroom-hald", validation = "validated"))),
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
            put("validation", stop.validation)
            put("omittedOperators", buildJsonArray { add("grain") })
            put("approximatedGlobally", JsonArray(emptyList()))
        }
    }
}
