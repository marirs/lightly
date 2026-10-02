package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.render.lut.Lut3D
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import java.security.MessageDigest

/**
 * Where a Look pack's files come from: app assets in production, an in-memory map in tests.
 * Paths are relative to the pack root (`manifest.json`, `luts/<lookId>.f32`).
 */
fun interface LookPackSource {
    /** The file's bytes, or null when it does not exist. */
    fun read(relativePath: String): ByteArray?
}

/**
 * Reads a Look pack (format `lightly-look-pack` v2, built by
 * experiments/presets/look_pack/build_look_pack.py) into a [LookBook].
 *
 * Format 2 replaced the single `validation` flag with `globalColour`, `fullRecipe`, `conversion`
 * and `status`. A format 1 pack is refused as a whole ([FORMAT_1_REASON]) rather than read with
 * guessed statuses. A Look's `status` is re-checked against its own evidence with the builder's
 * rule (`promoted_status`): a claim the evidence does not back is demoted and reported.
 *
 * Failure policy, so a bad pack never crashes the editor and never shows a wrong Look:
 * - Missing or unusable manifest (bad JSON, other format, version, dimension or encoding): an
 *   empty book carrying [LookBook.unavailableReason]. The editor then offers no Looks.
 * - One bad Look (missing field, unsafe path, missing file, wrong size, sha256 mismatch): that Look
 *   is dropped and listed in [LookBook.problems]; the rest of the pack still loads.
 * - A category left with no Looks is dropped and listed too.
 *
 * Categories and stops keep manifest order: the order is the catalog's browse order, decided
 * offline, and must not be re-sorted here.
 */
object LookPackLoader {
    const val FORMAT = "lightly-look-pack"
    const val FORMAT_VERSION = 2
    const val LUT_ENCODING = "rgba-float32-red-fastest"
    const val MANIFEST = "manifest.json"
    const val FORMAT_1_REASON = "This Look pack is format 1, which this build no longer reads (it needs format 2). Rebuild it with build_look_pack.py."
    const val NO_PACK_REASON = "This build has no Look pack."

    private val lutByteSize = Lut3D.floatCount(Lut3D.CONTRACT_DIMENSION) * Float.SIZE_BYTES

    fun load(source: LookPackSource): LookBook {
        val manifestBytes = source.read(MANIFEST) ?: return LookBook.unavailable(NO_PACK_REASON)
        val manifest = try {
            Json.parseToJsonElement(manifestBytes.decodeToString()) as? JsonObject
        } catch (malformed: SerializationException) {
            null
        } ?: return LookBook.unavailable("The Look pack manifest is not a JSON object.")
        headerProblem(manifest)?.let { return LookBook.unavailable(it) }
        val categoriesJson = manifest["categories"] as? JsonArray
            ?: return LookBook.unavailable("The Look pack manifest has no categories list.")
        return CategoryReader(source).read(categoriesJson)
    }

    /** Rejects any manifest whose LUTs this renderer would misread. */
    private fun headerProblem(manifest: JsonObject): String? {
        val format = manifest.string("format")
        val version = (manifest["formatVersion"] as? JsonPrimitive)?.intOrNull
        val dimension = (manifest["lutDimension"] as? JsonPrimitive)?.intOrNull
        val encoding = manifest.string("lutEncoding")
        return when {
            format != FORMAT -> "Unsupported Look pack format \"$format\" (expected \"$FORMAT\")."
            version == 1 -> FORMAT_1_REASON
            version != FORMAT_VERSION -> "Unsupported Look pack version $version (expected $FORMAT_VERSION)."
            dimension != Lut3D.CONTRACT_DIMENSION -> "Unsupported LUT size $dimension (expected ${Lut3D.CONTRACT_DIMENSION})."
            encoding != LUT_ENCODING -> "Unsupported LUT encoding \"$encoding\" (expected \"$LUT_ENCODING\")."
            else -> null
        }
    }

    /** Per-load state: problems found so far and Looks already loaded (a Look may be in two categories). */
    private class CategoryReader(private val source: LookPackSource) {
        private val problems = mutableListOf<String>()
        /** lookId → the Look already loaded and the LUT hash its manifest entry declared. */
        private val loadedById = mutableMapOf<String, LoadedLook>()

        fun read(categoriesJson: JsonArray): LookBook {
            val categories = mutableListOf<LookCategory>()
            categoriesJson.forEachIndexed { position, element ->
                readCategory(element as? JsonObject, position, categories.map { it.id }.toSet())?.let(categories::add)
            }
            return LookBook(categories, problems.toList())
        }

        private fun readCategory(json: JsonObject?, position: Int, takenIds: Set<String>): LookCategory? {
            val id = json?.string("id")
            val label = json?.string("label")
            val stopsJson = json?.get("stops") as? JsonArray
            if (id.isNullOrBlank() || label.isNullOrBlank() || stopsJson == null) {
                problems += "Category #${position + 1}: missing id, label or stops; dropped."
                return null
            }
            if (id in takenIds) {
                problems += "Category $id: listed twice; the second one is dropped."
                return null
            }
            val stops = mutableListOf<LookDefinition>()
            stopsJson.forEachIndexed { stopPosition, stopJson ->
                val look = readLook(stopJson as? JsonObject, "$id stop ${stopPosition + 1}") ?: return@forEachIndexed
                if (stops.any { it.lookId == look.lookId }) {
                    problems += "${look.lookId}: listed twice in category $id; the second stop is dropped."
                } else {
                    stops += look
                }
            }
            if (stops.isEmpty()) {
                problems += "Category $id ($label): no Look could be loaded; dropped."
                return null
            }
            return LookCategory(id, label, stops)
        }

        private fun readLook(json: JsonObject?, where: String): LookDefinition? {
            val fields = json?.let(::LookFields) ?: run {
                problems += "$where: not an object; dropped."
                return null
            }
            fields.missing().takeIf { it.isNotEmpty() }?.let { missing ->
                problems += "${fields.lookId ?: where}: missing ${missing.joinToString()}; dropped."
                return null
            }
            val lookId = fields.lookId!!
            loadedById[lookId]?.let { earlier ->
                if (earlier.look.lookVersion == fields.lookVersion && earlier.declaredSha256 == fields.lutSha256) return earlier.look
                problems += "$lookId: listed again with a different version or LUT; dropped."
                return null
            }
            val lut = readLut(lookId, fields.lutFile!!, fields.lutSha256!!) ?: return null
            return LookDefinition(
                lookId = lookId,
                lookVersion = fields.lookVersion!!,
                name = fields.name!!,
                lut = lut,
                lutSource = fields.lutSource!!,
                omittedOperators = fields.omittedOperators!!,
                approximatedGlobally = fields.approximatedGlobally!!,
                conversion = fields.conversion!!,
                globalColour = fields.globalColour!!,
                fullRecipe = fields.fullRecipe!!,
                status = checkedStatus(lookId, fields),
            ).also { loadedById[lookId] = LoadedLook(it, fields.lutSha256) }
        }

        /** The declared status, demoted (and reported) when its own evidence does not support it. */
        private fun checkedStatus(lookId: String, fields: LookFields): LookStatus {
            val declared = LookStatus.fromPack(fields.status!!)
            val supported = supportedStatus(fields.lutSource!!, fields.omittedOperators!!, fields.globalColour!!, fields.fullRecipe!!)
            if (declared.ordinal <= supported.ordinal) return declared
            problems += "$lookId: status \"${fields.status}\" is not backed by its evidence; treated as \"${supported.packValue}\"."
            return supported
        }

        private fun readLut(lookId: String, lutFile: String, expectedSha256: String): Lut3D? {
            if (!isSafeRelativePath(lutFile)) {
                problems += "$lookId: LUT path \"$lutFile\" leaves the pack; dropped."
                return null
            }
            val bytes = source.read(lutFile) ?: run {
                problems += "$lookId: LUT file $lutFile is missing; dropped."
                return null
            }
            if (bytes.size != lutByteSize) {
                problems += "$lookId: LUT file is ${bytes.size} bytes, expected $lutByteSize; dropped."
                return null
            }
            if (!sha256Hex(bytes).equals(expectedSha256, ignoreCase = true)) {
                problems += "$lookId: LUT sha256 does not match the manifest; dropped."
                return null
            }
            return Lut3D.fromLittleEndianBytes(bytes)
        }
    }

    private class LoadedLook(val look: LookDefinition, val declaredSha256: String)

    /**
     * Mirrors `promoted_status` in build_look_pack.py: only Lightroom's own LUT can be promoted,
     * because a report measures Lightroom's HALD, not a model-derived LUT.
     */
    private fun supportedStatus(lutSource: String, omitted: List<String>, globalColour: ValidationRecord, fullRecipe: ValidationRecord): LookStatus = when {
        lutSource != LookDefinition.LUT_SOURCE_LIGHTROOM_HALD || !globalColour.passed -> LookStatus.APPROXIMATE
        fullRecipe.passed && omitted.isEmpty() -> LookStatus.VALIDATED
        else -> LookStatus.GLOBAL_COLOUR_VALIDATED
    }

    /** Required stop fields; anything absent or of the wrong JSON type reads as null. */
    private class LookFields(json: JsonObject) {
        val lookId = json.string("lookId")?.takeIf { it.isNotBlank() }
        val lookVersion = json.string("lookVersion")?.takeIf { it.isNotBlank() }
        val name = json.string("name")?.takeIf { it.isNotBlank() }
        val lutFile = json.string("lutFile")
        val lutSha256 = json.string("lutSha256")
        val lutSource = json.string("lutSource")
        val omittedOperators = json.stringList("omittedOperators")
        val approximatedGlobally = json.stringList("approximatedGlobally")
        val conversion = json.string("conversion")
        val globalColour = json.validation("globalColour")
        val fullRecipe = json.validation("fullRecipe")
        val status = json.string("status")

        fun missing(): List<String> = listOfNotNull(
            "lookId".takeIf { lookId == null },
            "lookVersion".takeIf { lookVersion == null },
            "name".takeIf { name == null },
            "lutFile".takeIf { lutFile == null },
            "lutSha256".takeIf { lutSha256 == null },
            "lutSource".takeIf { lutSource == null },
            "omittedOperators".takeIf { omittedOperators == null },
            "approximatedGlobally".takeIf { approximatedGlobally == null },
            "conversion".takeIf { conversion == null },
            "globalColour".takeIf { globalColour == null },
            "fullRecipe".takeIf { fullRecipe == null },
            "status".takeIf { status == null },
        )
    }

    /** Asset paths cannot be absolute or climb out of `lookpack/`; a manifest must not try either. */
    private fun isSafeRelativePath(path: String): Boolean =
        path.isNotBlank() && !path.startsWith("/") && !path.contains('\\') && path.split('/').none { it == ".." || it.isEmpty() }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** `{status, evidence}`; evidence is a report name or JSON null. */
    private fun JsonObject.validation(key: String): ValidationRecord? {
        val record = this[key] as? JsonObject ?: return null
        val status = record.string("status") ?: return null
        val evidence = record["evidence"]
        if (evidence != null && evidence !is JsonNull && (evidence as? JsonPrimitive)?.isString != true) return null
        return ValidationRecord(status, (evidence as? JsonPrimitive)?.takeIf { it.isString }?.content)
    }

    private fun JsonObject.stringList(key: String): List<String>? {
        val array = this[key] as? JsonArray ?: return null
        val values = array.map { (it as? JsonPrimitive)?.takeIf { primitive -> primitive.isString }?.content }
        return if (values.any { it == null }) null else values.filterNotNull()
    }
}
