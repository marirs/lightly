package com.lightlylabs.lightly.develop

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/** A stroke ink shows the photo through its mask on paper; an overlay ink is multiplied over the whole photo. */
enum class InkKind(val wireName: String) { STROKE("stroke"), OVERLAY("overlay") }

/** One ink of the pack: its stable id, display name, kind, files (relative to the pack root) and the image's size and digest. */
data class InkPackEntry(
    val id: String,
    val name: String,
    val kind: InkKind,
    /** `img/<id>.png` (a stroke mask) or `img/<id>.jpg` (an overlay). */
    val image: String,
    /** `thumb/<id>.png|jpg`: the panel's tile. */
    val thumbnail: String,
    val imageSha256: String,
    val width: Int,
    val height: Int,
)

/**
 * The ink pack (format "lightly-ink-pack" 1, shared/ink/build_inks.py; Effects › Ink, owner-approved 2026-10-31), in pack
 * order: the Ink gallery lists the inks in this order after None. Git-ignored like the leak pack, so a build without it has
 * an empty pack and the gallery offers only None.
 */
class InkPack(val inks: List<InkPackEntry>) {
    private val byId = inks.associateBy { it.id }

    fun entry(id: String): InkPackEntry? = byId[id]

    companion object {
        const val FORMAT = "lightly-ink-pack"
        const val FORMAT_VERSION = 1

        /** Where the app bundles the pack: the manifest and its img/ and thumb/ beside it. */
        const val ASSET_ROOT = "inkpack/"
        const val ASSET_MANIFEST = "inkpack/inks.json"

        val EMPTY = InkPack(emptyList())

        private val ID = Regex("^ink-[0-9a-f]{12}$")
        private val SHA256 = Regex("^[0-9a-f]{64}$")

        /**
         * Parses and checks inks.json. The file paths must be exactly `img/<id>.<ext>` and `thumb/<id>.<ext>`, with the
         * kind's extension: they are joined onto the asset root, so a manifest must not be able to name any other file.
         */
        fun parse(text: String): InkPack {
            val root = Json.parseToJsonElement(text).jsonObject
            val format = root["format"]?.jsonPrimitive?.content
            val version = root["formatVersion"]?.jsonPrimitive?.int
            require(format == FORMAT && version == FORMAT_VERSION) { "ink pack is $format $version; this app reads $FORMAT $FORMAT_VERSION" }
            val inks = root.getValue("inks").jsonArray.map { entry(it.jsonObject) }
            require(inks.map { it.id }.toSet().size == inks.size) { "ink pack repeats an id" }
            return InkPack(inks)
        }

        private fun entry(o: JsonObject): InkPackEntry {
            fun text(key: String) = o.getValue(key).jsonPrimitive.content
            val id = text("id")
            require(ID.matches(id)) { "ink id $id is not ink-<12 lowercase hex>" }
            val kind = InkKind.entries.firstOrNull { it.wireName == text("kind") } ?: throw IllegalArgumentException("ink $id has no known kind")
            val entry = InkPackEntry(id, text("name"), kind, text("image"), text("thumbnail"), text("imageSha256"),
                o.getValue("width").jsonPrimitive.int, o.getValue("height").jsonPrimitive.int)
            val ext = if (kind == InkKind.STROKE) "png" else "jpg"
            require(entry.image == "img/$id.$ext" && entry.thumbnail == "thumb/$id.$ext") { "ink $id files are ${entry.image}, ${entry.thumbnail}" }
            require(SHA256.matches(entry.imageSha256)) { "ink $id has no lowercase SHA-256" }
            require(entry.width > 0 && entry.height > 0 && entry.name.isNotBlank()) { "ink $id has no size or name" }
            return entry
        }
    }
}

/** A decoded ink image: one 8-bit grey channel (a stroke ink's mask, 255 where the photo shows; an overlay ink's grey). */
class GreyImage(val width: Int, val height: Int, val grey: ByteArray) {
    init { require(width > 0 && height > 0 && grey.size == width * height) { "grey image is ${width}x$height with ${grey.size} bytes" } }
}

/** The ink [EffectsStage] draws: the recipe's values and the decoded image of the ink they name. */
data class InkParams(
    val kind: InkKind,
    val image: GreyImage,
    val x: Double = 50.0,
    val y: Double = 50.0,
    val size: Double = 100.0,
    val rotation: Double = 0.0,
    /** `#RRGGBB`. */
    val paper: String = "#F4F1EC",
    val intensity: Double = 60.0,
)

/**
 * `effects.ink` (rendering-v2 revision 10 §Ink), first in the effects stage. A stroke ink: the photo through the mask, paper
 * elsewhere, `out = a·in + (1 − a)·paper`; the whole stroke fitted inside the frame with a 6 % margin at size 100, turned 90°
 * on a portrait frame, centred at (x, y) % and turned by rotation. An overlay ink: the grey image aspect-filled and centred,
 * `out = in·(1 − k·(1 − g))`. All on sRGB-encoded values; the same code as iOS InkEvaluator.
 */
class InkOverlay private constructor(
    private val kind: InkKind,
    private val image: GreyImage,
    private val centreX: Double, private val centreY: Double,
    private val scale: Double,
    private val cosine: Double, private val sine: Double,
    private val paper: FloatArray,
    private val strength: Float,
) {
    fun apply(rgb: FloatArray, x: Int, y: Int) {
        val dx = x + 0.5 - centreX
        val dy = y + 0.5 - centreY
        // R(−θ)·d undoes the clockwise turn (y points down).
        val ux = (cosine * dx + sine * dy) / scale + image.width / 2.0
        val uy = (-sine * dx + cosine * dy) / scale + image.height / 2.0
        val g = (sample(ux, uy) / 255.0).toFloat()
        when (kind) {
            InkKind.STROKE -> for (c in 0 until 3) rgb[c] = rgb[c] * g + paper[c] * (1 - g)
            InkKind.OVERLAY -> { val k = 1 - strength * (1 - g); for (c in 0 until 3) rgb[c] = rgb[c] * k }
        }
    }

    /**
     * Bilinear between pixel centres (pixel i covers [i, i + 1)); texels outside the image read 0 for a stroke mask
     * (paper) and 255 for an overlay (no ink), so the cropped mask never smears its edge.
     */
    internal fun sample(ux: Double, uy: Double): Double {
        val outside = if (kind == InkKind.STROKE) 0.0 else 255.0
        val px = ux - 0.5
        val py = uy - 0.5
        val x0 = floor(px).toInt()
        val y0 = floor(py).toInt()
        val fx = px - x0
        val fy = py - y0
        fun texel(x: Int, y: Int): Double =
            if (x < 0 || y < 0 || x >= image.width || y >= image.height) outside else (image.grey[y * image.width + x].toInt() and 0xff).toDouble()
        val top = texel(x0, y0) * (1 - fx) + texel(x0 + 1, y0) * fx
        val bottom = texel(x0, y0 + 1) * (1 - fx) + texel(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }

    companion object {
        /** The fit inside the frame at size 100: 6 % of paper on each side. */
        const val STROKE_FIT = 0.88

        /** Null when it draws nothing: an overlay at intensity 0. */
        fun of(ink: InkParams, frameWidth: Int, frameHeight: Int): InkOverlay? {
            if (frameWidth <= 0 || frameHeight <= 0) return null
            if (ink.kind == InkKind.OVERLAY && ink.intensity <= 0) return null
            val w = frameWidth.toDouble()
            val h = frameHeight.toDouble()
            // φ: the stroke turns with a portrait photo (the masks are stored landscape).
            val quarterTurn = h > w
            val turnedWidth = (if (quarterTurn) ink.image.height else ink.image.width).toDouble()
            val turnedHeight = (if (quarterTurn) ink.image.width else ink.image.height).toDouble()
            val stroke = ink.kind == InkKind.STROKE
            val centreX = if (stroke) ink.x / 100 * w else w / 2
            val centreY = if (stroke) ink.y / 100 * h else h / 2
            val scale = if (stroke) ink.size / 100 * STROKE_FIT * min(w / turnedWidth, h / turnedHeight) else max(w / turnedWidth, h / turnedHeight)
            val theta = Math.toRadians(ink.rotation) + if (quarterTurn) Math.PI / 2 else 0.0
            return InkOverlay(ink.kind, ink.image, centreX, centreY, scale, cos(theta), sin(theta), colour(ink.paper),
                (ink.intensity.coerceIn(0.0, 100.0) / 100).toFloat())
        }

        /** `#RRGGBB` → 0…1; an unreadable colour (the recipe refuses one) falls back to Warm white. */
        fun colour(hex: String): FloatArray {
            val value = hex.removePrefix("#").takeIf { it.length == 6 }?.toIntOrNull(16) ?: return colour("#F4F1EC")
            return floatArrayOf(((value shr 16) and 0xff) / 255f, ((value shr 8) and 0xff) / 255f, (value and 0xff) / 255f)
        }
    }
}
