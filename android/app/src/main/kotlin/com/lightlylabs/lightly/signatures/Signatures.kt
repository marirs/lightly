package com.lightlylabs.lightly.signatures

import com.lightlylabs.lightly.session.SignatureKind
import com.lightlylabs.lightly.session.SignatureRef
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID

/**
 * A drawn signature, kept as vector strokes (approved "Draw signature"), as on iOS (SavedSignature.swift).
 * Strokes are polylines in the pad's coordinates; [viewBox] is what the watermark stage maps onto the
 * watermark's height (as the prototype's `sigSvg` maps `viewBox="0 0 170 50"`), and [strokeWidth] is in
 * the same units, so a signature keeps its own look at every size.
 */
data class DrawnSignature(val strokes: List<List<Point>>, val viewBox: Box, val strokeWidth: Double) {
    data class Point(val x: Double, val y: Double)
    data class Box(val x: Double, val y: Double, val width: Double, val height: Double)

    val aspectRatio: Double get() = viewBox.width / viewBox.height

    fun lineWidth(atHeight: Double): Double = strokeWidth * atHeight / viewBox.height

    /** Canonical JSON with fixed two-decimal numbers: the same strokes always give the same bytes (and version). Same format as iOS. */
    val canonicalData: ByteArray
        get() {
            fun n(v: Double) = String.format(Locale.ROOT, "%.2f", v)
            val strokesText = strokes.joinToString(",") { stroke -> "[" + stroke.joinToString(",") { "[${n(it.x)},${n(it.y)}]" } + "]" }
            return ("{\"format\":1,\"strokeWidth\":${n(strokeWidth)},\"strokes\":[$strokesText]," +
                "\"viewBox\":[${n(viewBox.x)},${n(viewBox.y)},${n(viewBox.width)},${n(viewBox.height)}]}").toByteArray()
        }

    companion object {
        /** The prototype's drawn signature: stroke 2.4 in a 50-unit-tall view box. */
        const val STROKE_WIDTH_PER_HEIGHT = 2.4 / 50

        /** Reads [canonicalData]; null for anything else. */
        fun parse(bytes: ByteArray): DrawnSignature? = runCatching {
            val root = kotlinx.serialization.json.Json.parseToJsonElement(bytes.toString(Charsets.UTF_8)) as kotlinx.serialization.json.JsonObject
            fun num(e: kotlinx.serialization.json.JsonElement) = (e as kotlinx.serialization.json.JsonPrimitive).content.toDouble()
            require(num(root.getValue("format")).toInt() == 1)
            val box = (root.getValue("viewBox") as kotlinx.serialization.json.JsonArray).map(::num)
            val strokes = (root.getValue("strokes") as kotlinx.serialization.json.JsonArray).map { stroke ->
                (stroke as kotlinx.serialization.json.JsonArray).map { p -> (p as kotlinx.serialization.json.JsonArray).let { Point(num(it[0]), num(it[1])) } }
            }
            require(box.size == 4 && box[2] > 0 && box[3] > 0 && strokes.any { it.isNotEmpty() })
            DrawnSignature(strokes, Box(box[0], box[1], box[2], box[3]), num(root.getValue("strokeWidth")))
        }.getOrNull()

        /**
         * A pad drawing as a signature (as iOS `fromPad`): the view box is as tall as the pen width implies
         * (the prototype's 2.4 : 50), centred on the ink and at least as tall as it; 6/50 of the height of
         * margin left and right. Null when nothing was drawn.
         */
        fun fromPad(strokes: List<List<Point>>, penWidth: Double): DrawnSignature? {
            val points = strokes.flatten()
            if (points.isEmpty()) return null
            val minX = points.minOf { it.x }; val maxX = points.maxOf { it.x }
            val minY = points.minOf { it.y }; val maxY = points.maxOf { it.y }
            val height = maxOf(penWidth / STROKE_WIDTH_PER_HEIGHT, maxY - minY + penWidth)
            val margin = height * 6 / 50
            val centreY = (minY + maxY) / 2
            return DrawnSignature(strokes.filter { it.isNotEmpty() }, Box(minX - margin, centreY - height / 2, maxX - minX + 2 * margin, height), penWidth)
        }

        /** The prototype's `SIG_DRAWN` (view box 170 × 50, stroke 2.4), flattened to points (16 per cubic), as iOS. */
        val PROTOTYPE_SAMPLE: DrawnSignature by lazy {
            val path = "M6 38c10-20 16-30 20-28 5 3-9 28-3 30 6 2 10-18 15-17 4 1-1 15 4 15 5 0 7-12 12-12 4 0 2 10 6 10 6 0 10-14 18-14 6 0 3 9 9 9 7 0 12-8 22-10"
            val numbers = path.drop(1).replace("c", " ").replace("-", " -").split(" ").filter { it.isNotBlank() }.map { it.toDouble() }
            var current = Point(numbers[0], numbers[1])
            val points = arrayListOf(current)
            var i = 2
            while (i + 5 < numbers.size) {
                val c1 = Point(current.x + numbers[i], current.y + numbers[i + 1])
                val c2 = Point(current.x + numbers[i + 2], current.y + numbers[i + 3])
                val end = Point(current.x + numbers[i + 4], current.y + numbers[i + 5])
                for (step in 1..16) {
                    val t = step / 16.0
                    val u = 1 - t
                    points += Point(u * u * u * current.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x,
                        u * u * u * current.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y)
                }
                current = end
                i += 6
            }
            DrawnSignature(listOf(points), Box(0.0, 0.0, 170.0, 50.0), 2.4)
        }
    }
}

/** One saved signature: stable id, kind, stored bytes (canonical strokes for drawn, a PNG with the paper removed for imported). */
class SavedSignature(val id: String, val kind: SignatureKind, val data: ByteArray) {
    /** edit-recipe `signatureVersion`: the first 12 hex digits of the SHA-256 of the stored bytes. */
    val version: String = sha256(data).take(12)
    val reference: SignatureRef get() = SignatureRef(id, version, kind)
    val drawn: DrawnSignature? get() = if (kind == SignatureKind.DRAWN) DrawnSignature.parse(data) else null

    override fun equals(other: Any?) = other is SavedSignature && other.id == id && other.kind == kind && other.version == version
    override fun hashCode() = (id + version).hashCode()
}

internal fun sha256(data: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }

/**
 * The saved signatures (approved Watermark › Signature and Preferences › Saved signature), as iOS
 * SignatureStore: one drawn and one imported at a time. Saving again replaces that kind and keeps its id,
 * so an edit that used the earlier one sees a changed version; deleting makes it missing. A recipe's
 * reference resolves to the signature, or to nothing: never substituted (edit-recipe `signatureRef`).
 *
 * Files in [directory]: `index.json` (ids, most recent kind) and one content file per signature; logo
 * images chosen in Watermark › Logo as `logo-<sha256>.png` (`assetRef` kind file). Null = memory only.
 */
class SignatureStore(private val directory: File?) {
    data class Contents(val drawn: SavedSignature? = null, val imported: SavedSignature? = null, val mostRecent: SignatureKind? = null) {
        fun of(kind: SignatureKind) = if (kind == SignatureKind.DRAWN) drawn else imported

        /** What Preferences › Saved signature shows: the one saved last, else whichever exists. */
        val shown: SavedSignature? get() = mostRecent?.let(::of) ?: drawn ?: imported
        val isEmpty: Boolean get() = drawn == null && imported == null
    }

    private val state = MutableStateFlow(load())
    val contents: StateFlow<Contents> = state.asStateFlow()
    private val logos = java.util.concurrent.ConcurrentHashMap<String, ByteArray>()

    fun saveDrawn(signature: DrawnSignature): SavedSignature = save(SignatureKind.DRAWN, signature.canonicalData)

    fun saveImported(png: ByteArray): SavedSignature = save(SignatureKind.IMPORTED, png)

    fun delete(kind: SignatureKind) {
        val current = state.value
        current.of(kind)?.let { existing -> directory?.let { File(it, fileName(existing.id, kind)).delete() } }
        val remaining = if (kind == SignatureKind.DRAWN) current.copy(drawn = null) else current.copy(imported = null)
        val mostRecent = if (remaining.mostRecent == kind) (if (remaining.of(other(kind)) != null) other(kind) else null) else remaining.mostRecent
        state.value = remaining.copy(mostRecent = mostRecent)
        writeIndex()
    }

    /** A recipe reference: the signature when its id and version match; null when missing or changed (rendered without it). */
    fun resolve(reference: SignatureRef): SavedSignature? =
        state.value.let { listOfNotNull(it.drawn, it.imported) }.firstOrNull { it.id == reference.signatureId }?.takeIf { it.version == reference.signatureVersion }

    /** Stores a logo image (PNG) and returns its SHA-256 for the recipe. */
    fun saveLogo(png: ByteArray): String {
        val digest = sha256(png)
        logos[digest] = png
        directory?.let { dir -> runCatching { dir.mkdirs(); atomicWrite(File(dir, "logo-$digest.png"), png) } }
        return digest
    }

    fun logo(sha256: String): ByteArray? = logos[sha256] ?: directory?.let { File(it, "logo-$sha256.png") }?.takeIf { it.isFile }?.readBytes()?.takeIf { sha256(it) == sha256 }?.also { logos[sha256] = it }

    /** Debug captures only: replaces the contents without touching the disk (the prototype's sample signature). */
    fun debugReplace(drawn: DrawnSignature?, importedPng: ByteArray?) {
        state.value = Contents(drawn?.let { SavedSignature("debug-drawn", SignatureKind.DRAWN, it.canonicalData) },
            importedPng?.let { SavedSignature("debug-imported", SignatureKind.IMPORTED, it) },
            if (drawn != null) SignatureKind.DRAWN else if (importedPng != null) SignatureKind.IMPORTED else null)
    }

    private fun other(kind: SignatureKind) = if (kind == SignatureKind.DRAWN) SignatureKind.IMPORTED else SignatureKind.DRAWN

    private fun save(kind: SignatureKind, data: ByteArray): SavedSignature {
        val current = state.value
        val saved = SavedSignature(current.of(kind)?.id ?: UUID.randomUUID().toString().lowercase(), kind, data)
        // Kept in memory for this run even if the write fails; the next launch then finds it missing.
        directory?.let { dir -> runCatching { dir.mkdirs(); atomicWrite(File(dir, fileName(saved.id, kind)), data) } }
        state.value = (if (kind == SignatureKind.DRAWN) current.copy(drawn = saved) else current.copy(imported = saved)).copy(mostRecent = kind)
        writeIndex()
        return saved
    }

    private fun fileName(id: String, kind: SignatureKind) = if (kind == SignatureKind.DRAWN) "$id.strokes.json" else "$id.png"

    private fun writeIndex() {
        val dir = directory ?: return
        val c = state.value
        fun q(s: String?) = s?.let { "\"$it\"" } ?: "null"
        val recent = c.mostRecent?.let { if (it == SignatureKind.DRAWN) "drawn" else "imported" }
        runCatching { dir.mkdirs(); atomicWrite(File(dir, "index.json"), "{\"drawn\":${q(c.drawn?.id)},\"imported\":${q(c.imported?.id)},\"mostRecent\":${q(recent)}}".toByteArray()) }
    }

    private fun load(): Contents {
        val dir = directory ?: return Contents()
        val index = runCatching { kotlinx.serialization.json.Json.parseToJsonElement(File(dir, "index.json").readText()) as kotlinx.serialization.json.JsonObject }.getOrNull() ?: return Contents()
        fun field(key: String) = (index[key] as? kotlinx.serialization.json.JsonPrimitive)?.takeIf { it.isString }?.content
        // The version is always recomputed from the bytes on disk, never trusted from the index.
        fun read(id: String?, kind: SignatureKind) = id?.let { File(dir, fileName(it, kind)) }?.takeIf { it.isFile }?.let { SavedSignature(id, kind, it.readBytes()) }
        val recent = when (field("mostRecent")) { "drawn" -> SignatureKind.DRAWN; "imported" -> SignatureKind.IMPORTED; else -> null }
        return Contents(read(field("drawn"), SignatureKind.DRAWN), read(field("imported"), SignatureKind.IMPORTED), recent)
    }

    private fun atomicWrite(target: File, bytes: ByteArray) {
        val temporary = File(target.parentFile, target.name + ".tmp")
        temporary.writeBytes(bytes)
        if (!temporary.renameTo(target)) { target.delete(); temporary.renameTo(target) }
    }
}
