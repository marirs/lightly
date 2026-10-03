package com.lightlylabs.lightly.develop

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The shared parity fixtures (repo `shared/fixtures/look-pack/`) and the rendering contract, read in
 * place through system properties set by core-develop/build.gradle.kts. A missing file FAILS: a
 * parity test that skipped would report green while proving nothing.
 */
object LookPackFixtures {
    private fun file(property: String): File {
        val path = checkNotNull(System.getProperty(property)) { "$property is not set; run the tests through Gradle" }
        return File(path)
    }

    val directory: File by lazy { file("lightly.lookPackFixturesDir").also { check(it.isDirectory) { "Look-pack fixtures not found at $it" } } }

    val model: DevelopModel by lazy { DevelopModel.parse(file("lightly.renderingContract").readText()) }

    val golden: JsonObject by lazy { Json.parseToJsonElement(File(directory, "golden.json").readText()).jsonObject }

    val parityPack: LookPack by lazy { LookPack.parse(File(directory, "manifest-parity.json").readText(), model) }

    /** The full built pack (git-ignored); null when it has not been built in this checkout. */
    val builtManifest: File? get() = file("lightly.builtPackManifest").takeIf { it.isFile }

    /** A golden 17³ LUT: float16 little-endian RGB, [b][g][r], red fastest. */
    fun readLut17(relativePath: String): FloatArray {
        val bytes = File(directory, relativePath).readBytes()
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        return FloatArray(bytes.size / 2) { halfToFloat(buffer.getShort(it * 2).toInt() and 0xFFFF) }
    }

    /** IEEE 754 binary16 → float (the JVM 17 API has no Float.float16ToFloat). */
    fun halfToFloat(half: Int): Float {
        val sign = if (half and 0x8000 != 0) -1f else 1f
        val exponent = (half ushr 10) and 0x1F
        val mantissa = half and 0x3FF
        return when (exponent) {
            0 -> sign * mantissa * Math.pow(2.0, -24.0).toFloat()
            0x1F -> if (mantissa == 0) sign * Float.POSITIVE_INFINITY else Float.NaN
            else -> sign * (1f + mantissa / 1024f) * Math.pow(2.0, (exponent - 15).toDouble()).toFloat()
        }
    }
}
