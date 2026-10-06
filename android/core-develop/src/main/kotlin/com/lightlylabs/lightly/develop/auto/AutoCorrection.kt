package com.lightlylabs.lightly.develop.auto

import com.lightlylabs.lightly.render.lut.Lut3D
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Auto on Android 1.0 (2026-10-06): Lightly's own global correction, analysed on the photo (Android has no Core Image;
 * iOS keeps Core Image's auto enhancement, owner decision). Same behaviour class as iOS: global, per-pixel corrections
 * that pass the same image-dependent guards ([AutoAnalysis]), baked into the stage-1 Auto LUT, identical in preview and
 * Save copy. The analysis engines differ, so the same photo is not corrected identically on both platforms.
 *
 * The correction is its parameters (stored with the session; a restored session rebuilds the LUT from them without
 * analysing the photo again), applied in this order, as the iOS filters are:
 * 1. vibrance ([vibrance], 0 = none): saturation raised more for less saturated colours;
 * 2. cast balance ([gains], linear-light channel gains, (1, 1, 1) = none);
 * 3. exposure ([exposure], a linear-light gain on all channels, 1 = none; never below 1).
 *
 * v3 differs from iOS: no tone curve. A first version proposed one (median toward 0.45); it brightened intentionally dark
 * photos (originals moved ΔE 13–16 on the studio and backlit portraits), so the tonal correction is an exposure gain
 * from the highlights instead (experiments/auto-android/eval.txt).
 */
data class AutoCorrection(
    val vibrance: Double = 0.0,
    val gains: List<Double> = listOf(1.0, 1.0, 1.0),
    val exposure: Double = 1.0,
    /** The guards' measurements and decisions, kept for review (never rendered). */
    val notes: List<String> = emptyList(),
) {
    init {
        require(gains.size == 3) { "three gains" }
    }

    val isIdentity: Boolean get() = vibrance == 0.0 && gains.all { it == 1.0 } && exposure == 1.0

    /** Applies the correction to one sRGB-encoded colour in [0, 1] (in place). */
    fun apply(rgb: DoubleArray) {
        if (vibrance != 0.0) {
            val hi = max(rgb[0], max(rgb[1], rgb[2]))
            val lo = min(rgb[0], min(rgb[1], rgb[2]))
            val luma = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
            val k = 1 + vibrance * (1 - (hi - lo))
            for (c in 0 until 3) rgb[c] = (luma + (rgb[c] - luma) * k).coerceIn(0.0, 1.0)
        }
        if (gains[0] != 1.0 || gains[1] != 1.0 || gains[2] != 1.0 || exposure != 1.0) {
            for (c in 0 until 3) rgb[c] = encode((decode(rgb[c]) * gains[c] * exposure).coerceIn(0.0, 1.0))
        }
    }

    /** The correction on every grid colour: the stage-1 Auto LUT (rendering contract layout, sRGB in and out). */
    fun lut(dimension: Int = Lut3D.CONTRACT_DIMENSION): Lut3D {
        val n = dimension
        val values = FloatArray(n * n * n * 4)
        val rgb = DoubleArray(3)
        for (b in 0 until n) for (g in 0 until n) for (r in 0 until n) {
            rgb[0] = r / (n - 1.0); rgb[1] = g / (n - 1.0); rgb[2] = b / (n - 1.0)
            apply(rgb)
            val i = (r + n * g + n * n * b) * 4
            values[i] = rgb[0].toFloat(); values[i + 1] = rgb[1].toFloat(); values[i + 2] = rgb[2].toFloat(); values[i + 3] = 1f
        }
        return Lut3D(n, values)
    }

    fun toJson(): String = JsonObject(mapOf(
        "engine" to JsonPrimitive(RECIPE_MODEL_ID), "version" to JsonPrimitive(RECIPE_MODEL_VERSION),
        "vibrance" to JsonPrimitive(vibrance), "gains" to JsonArray(gains.map(::JsonPrimitive)),
        "exposure" to JsonPrimitive(exposure), "notes" to JsonArray(notes.map(::JsonPrimitive)),
    )).toString()

    companion object {
        /** Recipe `auto.modelId` / `modelVersion` of this correction (the recipe's three weights are unused: zeros). */
        const val RECIPE_MODEL_ID = "lightly-auto-android"
        const val RECIPE_MODEL_VERSION = "1"
        /** The stored correction, or null when [json] is not one of this engine and version. */
        fun fromJson(json: String): AutoCorrection? = runCatching {
            val o = Json.parseToJsonElement(json).jsonObject
            require(o["engine"]?.jsonPrimitive?.content == RECIPE_MODEL_ID && o["version"]?.jsonPrimitive?.content == RECIPE_MODEL_VERSION)
            AutoCorrection(
                vibrance = o["vibrance"]!!.jsonPrimitive.double,
                gains = o["gains"]!!.jsonArray.map { it.jsonPrimitive.double },
                exposure = o["exposure"]!!.jsonPrimitive.double,
                notes = o["notes"]?.jsonArray?.map { it.jsonPrimitive.content }.orEmpty(),
            )
        }.getOrNull()

        fun decode(e: Double): Double = if (e <= 0.04045) e / 12.92 else ((e + 0.055) / 1.055).pow(2.4)
        fun encode(l: Double): Double = if (l <= 0.0031308) l * 12.92 else 1.055 * l.pow(1 / 2.4) - 0.055
    }
}
