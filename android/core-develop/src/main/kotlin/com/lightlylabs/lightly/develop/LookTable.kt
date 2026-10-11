package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.lut.Lut3D
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * A "table look": a preset whose develop.global stage is a precomputed 33³ table shipped next to the manifest
 * (`globalOverride` with `source: "cube"`), not a bake of its recipe. The recipe's global stage is empty for
 * these presets; spatial and finishing still come from the recipe (today also empty).
 *
 * The table uses the bake's own grid, layout and domain (rendering-v2.md §Bake: `linspace(0,1,33)` per axis,
 * `[b][g][r]` red fastest, sRGB-encoded in and out), so once decoded it IS the Lut3D a bake would have produced
 * and every downstream path (strength blend, preview, export, thumbnails) treats it exactly like a bake.
 */
class LookGlobalTable(
    /** Path relative to the manifest's directory, e.g. `luts/look-<id>.f16`. */
    val lutFile: String,
    /** Lowercase hex SHA-256 of the file's bytes; also the lookVersion's `globalOverrideSha256`. */
    val lutSha256: String,
    val lutDimension: Int,
    val lutEncoding: String,
) {
    companion object {
        const val SOURCE_CUBE = "cube"
        const val SUPPORTED_DIMENSION = Lut3D.CONTRACT_DIMENSION
        const val ENCODING_RGB_FLOAT16_RED_FASTEST = "rgb-float16-red-fastest"

        /**
         * Only `luts/<name>.f16` with a plain file name: the path is joined onto an asset root, so a `..` or an
         * absolute path in a pack must not reach other files.
         */
        private val LUT_FILE_PATTERN = Regex("""luts/[A-Za-z0-9._-]+\.f16""")
        private val SHA256_PATTERN = Regex("""[0-9a-f]{64}""")
        private val KNOWN_FIELDS = setOf("source", "lutFile", "lutSha256", "lutDimension", "lutEncoding", "note")

        /** Strict: an override this build cannot render exactly is refused, never rendered as the recipe. */
        fun parse(presetId: String, override: JsonObject): LookGlobalTable {
            val unknown = override.keys - KNOWN_FIELDS
            require(unknown.isEmpty()) { "Preset $presetId globalOverride has unknown fields $unknown" }
            val source = override.stringField(presetId, "source")
            require(source == SOURCE_CUBE) { "Preset $presetId globalOverride source '$source' is not supported (expected '$SOURCE_CUBE')" }
            val lutFile = override.stringField(presetId, "lutFile")
            require(LUT_FILE_PATTERN.matches(lutFile) && !lutFile.contains("..")) { "Preset $presetId globalOverride lutFile '$lutFile' is not a luts/*.f16 path" }
            val lutSha256 = override.stringField(presetId, "lutSha256")
            require(SHA256_PATTERN.matches(lutSha256)) { "Preset $presetId globalOverride lutSha256 is not a lowercase SHA-256" }
            val dimension = (override["lutDimension"] as? JsonPrimitive)?.content?.toIntOrNull()
            require(dimension == SUPPORTED_DIMENSION) { "Preset $presetId globalOverride lutDimension $dimension (expected $SUPPORTED_DIMENSION)" }
            val encoding = override.stringField(presetId, "lutEncoding")
            require(encoding == ENCODING_RGB_FLOAT16_RED_FASTEST) { "Preset $presetId globalOverride lutEncoding '$encoding' is not supported" }
            return LookGlobalTable(lutFile, lutSha256, dimension, encoding)
        }

        private fun JsonObject.stringField(presetId: String, key: String): String {
            val value = this[key] as? JsonPrimitive
            require(value != null && value.isString) { "Preset $presetId globalOverride has no string '$key'" }
            return value.content
        }
    }
}

/**
 * Reads a table look's file by its manifest-relative path ([LookGlobalTable.lutFile]). The app reads APK assets
 * under `lookpack/`; tests read the built pack directory. Kept as an interface so this module stays Android-free.
 */
fun interface LookTableSource {
    fun read(relativePath: String): ByteArray

    companion object {
        /** For libraries built without table files (fixtures with recipe presets only): any table look fails loudly. */
        val UNAVAILABLE = LookTableSource { path -> throw IllegalStateException("No look-table source: cannot read $path") }
    }
}

/** Decoding and resampling of table-look files into the bake's [Lut3D]. */
object LookTableDecoder {
    /**
     * Decodes [bytes] (RGB IEEE binary16, little-endian, `[b][g][r][rgb]` red fastest) into float32 RGBA with alpha 1.
     * [verifySha256]: the expected lowercase hex digest, or null when this exact file was already verified once
     * (the caller remembers that, so re-decoding after a cache eviction does not re-hash).
     */
    fun decode(bytes: ByteArray, dimension: Int, verifySha256: String?): Lut3D {
        val entryCount = dimension * dimension * dimension
        require(bytes.size == entryCount * 3 * 2) { "A ${dimension}³ RGB float16 table is ${entryCount * 6} bytes, got ${bytes.size}" }
        if (verifySha256 != null) {
            val actual = sha256Hex(bytes)
            require(actual == verifySha256) { "Look table SHA-256 $actual does not match the manifest's $verifySha256" }
        }
        val halves = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val rgba = FloatArray(Lut3D.floatCount(dimension))
        for (entry in 0 until entryCount) {
            for (channel in 0 until 3) {
                rgba[entry * 4 + channel] = halfToFloat(halves.getShort((entry * 3 + channel) * 2).toInt() and 0xFFFF)
            }
            rgba[entry * 4 + 3] = 1f
        }
        return Lut3D(dimension, rgba)
    }

    /**
     * The table on another grid (thumbnails' and drags' 17³): each new grid point is the trilinear lookup of [table]
     * at that point, i.e. exactly what rendering with the full table would give there. For a bake the smaller grid is
     * re-evaluated from the model instead; a table has no model behind it, so its own interpolant is the best source.
     */
    fun resample(table: Lut3D, dimension: Int): Lut3D {
        if (dimension == table.dimension) return table
        val rgba = FloatArray(Lut3D.floatCount(dimension))
        val sampled = FloatArray(3)
        for (b in 0 until dimension) for (g in 0 until dimension) for (r in 0 until dimension) {
            table.sample(Lut3D.gridValue(r, dimension), Lut3D.gridValue(g, dimension), Lut3D.gridValue(b, dimension), sampled)
            val base = (r + dimension * (g + dimension * b)) * 4
            rgba[base] = sampled[0]
            rgba[base + 1] = sampled[1]
            rgba[base + 2] = sampled[2]
            rgba[base + 3] = 1f
        }
        return Lut3D(dimension, rgba)
    }

    fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /**
     * IEEE 754 binary16 → float32, exact for every value (all halves are representable). JVM 17 has no
     * Float.float16ToFloat, and Android's android.util.Half would tie this module to Android.
     */
    fun halfToFloat(half: Int): Float {
        val sign = (half and 0x8000) shl 16
        val exponent = (half ushr 10) and 0x1F
        val mantissa = half and 0x3FF
        return when {
            exponent == 0x1F -> Float.fromBits(sign or 0x7F800000 or (mantissa shl 13)) // infinity / NaN
            exponent != 0 -> Float.fromBits(sign or ((exponent + 127 - 15) shl 23) or (mantissa shl 13))
            mantissa == 0 -> Float.fromBits(sign) // signed zero
            else -> (if (sign != 0) -1f else 1f) * mantissa * SUBNORMAL_UNIT // subnormal: mantissa × 2⁻²⁴, exact in float32
        }
    }

    private const val SUBNORMAL_UNIT = 5.9604645E-8f // 2⁻²⁴
}
