package com.lightlylabs.lightly.develop

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * The calibrated Develop model of rendering contract v2 (`rendering-v2.json` › `developModel`).
 *
 * The constants are never typed in by hand: the app bundles the contract's `developModel` object and
 * [parse] verifies it against its own `constantsSha256` (recomputed over the canonical JSON exactly as
 * `build_rendering_v2.py` does), so a corrupted or hand-edited copy is refused rather than rendered.
 */
class DevelopModel(
    val id: String,
    val version: Int,
    val constantsSha256: String,
    val global: GlobalConstants,
    val spatial: SpatialConstants,
    val experimental: ExperimentalConstants,
    val provisional: ProvisionalConstants,
) {
    companion object {
        /** Parses `developModel` (the object, or a whole rendering-v2.json that contains it). */
        fun parse(json: String): DevelopModel {
            val root = Json.parseToJsonElement(json).jsonObject
            return parse(root["developModel"]?.jsonObject ?: root)
        }

        fun parse(model: JsonObject): DevelopModel {
            val hashed = JsonObject(HASHED_KEYS.associateWith { key -> model[key] ?: throw IllegalArgumentException("developModel.$key is missing") })
            val published = model.string("constantsSha256")
            val computed = CanonicalJson.sha256Hex(hashed)
            require(computed == published) { "developModel constants do not match constantsSha256 ($computed != $published)" }
            require(model.string("curveMethod") == "natural") { "Only the natural spline curve method is implemented" }
            return DevelopModel(
                id = model.string("id"),
                version = model.getValue("version").jsonPrimitive.int,
                constantsSha256 = published,
                global = GlobalConstants.parse(model.getValue("constants").jsonObject),
                spatial = SpatialConstants.parse(model.getValue("spatialConstants").jsonObject),
                experimental = ExperimentalConstants.parse(model.getValue("experimentalConstants").jsonObject),
                provisional = ProvisionalConstants.parse(model.getValue("provisionalConstants").jsonObject),
            )
        }

        /** The body build_rendering_v2.develop_model() hashes into constantsSha256. */
        private val HASHED_KEYS = listOf("constants", "curveMethod", "spatialConstants", "experimentalConstants", "provisionalConstants")
    }
}

/** developModel.constants: the global stage (rendering-v2.md §4.1, symbols as written there). */
class GlobalConstants(
    val kTemp: Double, val kTint: Double,
    val kContrast: Double, val kHi: Double, val kSh: Double, val kWh: Double, val kBl: Double,
    val cHi: Double, val cSh: Double, val wHi: Double, val wSh: Double,
    val kDehaze: Double, val dehazeAir: Double, val kParam: Double,
    val kHue: Double, val kHslSat: Double, val kHslLum: Double, val kSat: Double, val kVib: Double,
    val kCalHue: Double, val kCalSat: Double, val kShadowTint: Double, val kGrade: Double, val kGradeLum: Double,
    /** 6 rows (contrast, highlights, shadows, whites, blacks, dehaze) × 12 knots. */
    val toneA: Array<DoubleArray>,
    val toneB: Array<DoubleArray>,
    val hueBand: DoubleArray, val satBand: DoubleArray, val lumBand: DoubleArray,
    val gradeZone: DoubleArray, val calHue: DoubleArray, val calSat: DoubleArray,
) {
    companion object {
        fun parse(c: JsonObject) = GlobalConstants(
            kTemp = c.number("k_temp"), kTint = c.number("k_tint"),
            kContrast = c.number("k_contrast"), kHi = c.number("k_hi"), kSh = c.number("k_sh"), kWh = c.number("k_wh"), kBl = c.number("k_bl"),
            cHi = c.number("c_hi"), cSh = c.number("c_sh"), wHi = c.number("w_hi"), wSh = c.number("w_sh"),
            kDehaze = c.number("k_dehaze"), dehazeAir = c.number("dehaze_air"), kParam = c.number("k_param"),
            kHue = c.number("k_hue"), kHslSat = c.number("k_hsl_sat"), kHslLum = c.number("k_hsl_lum"), kSat = c.number("k_sat"), kVib = c.number("k_vib"),
            kCalHue = c.number("k_cal_hue"), kCalSat = c.number("k_cal_sat"), kShadowTint = c.number("k_shadow_tint"),
            kGrade = c.number("k_grade"), kGradeLum = c.number("k_grade_lum"),
            toneA = c.matrix("tone_A", rows = 6, columns = 12), toneB = c.matrix("tone_B", rows = 6, columns = 12),
            hueBand = c.vector("hue_band", 8), satBand = c.vector("sat_band", 8), lumBand = c.vector("lum_band", 8),
            gradeZone = c.vector("grade_zone", 4), calHue = c.vector("cal_hue", 3), calSat = c.vector("cal_sat", 3),
        )
    }
}

/** developModel.spatialConstants (clarity and texture, calibrated). */
class SpatialConstants(val kClarity: Double, val rClarity: Double, val kTexture: Double, val rTexture: Double) {
    companion object {
        fun parse(c: JsonObject) = SpatialConstants(c.number("k_clarity"), c.number("r_clarity"), c.number("k_texture"), c.number("r_texture"))
    }
}

/** developModel.experimentalConstants (vignette and grain, uncalibrated). */
class ExperimentalConstants(val vignetteK: Double, val grainK: Double, val grainRefLong: Double) {
    companion object {
        fun parse(c: JsonObject) = ExperimentalConstants(c.number("VIGNETTE_K"), c.number("GRAIN_K"), c.number("GRAIN_REF_LONG"))
    }
}

/** developModel.provisionalConstants (sharpening and noise reduction, uncalibrated). */
class ProvisionalConstants(
    val referenceLongEdgePx: Double,
    val kSharpen: Double,
    val sharpenDetailThreshold: Double,
    val sharpenEdgeScale: Double,
    val nrLumaRadiusPx: Double,
    val nrDetailScale: Double,
    val nrColourRadiusPx: Double,
) {
    companion object {
        fun parse(c: JsonObject) = ProvisionalConstants(
            c.number("referenceLongEdgePx"), c.number("k_sharpen"), c.number("sharpenDetailThreshold"), c.number("sharpenEdgeScale"),
            c.number("nrLumaRadiusPx"), c.number("nrDetailScale"), c.number("nrColourRadiusPx"),
        )
    }
}

internal fun JsonObject.string(key: String): String {
    val value = this[key] as? JsonPrimitive ?: throw IllegalArgumentException("'$key' is missing")
    require(value.isString) { "'$key' must be a string" }
    return value.content
}

internal fun JsonObject.number(key: String): Double = numberOf(this[key] ?: throw IllegalArgumentException("'$key' is missing"), key)

internal fun numberOf(element: JsonElement, label: String): Double {
    val primitive = element as? JsonPrimitive ?: throw IllegalArgumentException("'$label' must be a number")
    require(!primitive.isString) { "'$label' must be a number, not a string" }
    val value = primitive.double
    require(value.isFinite()) { "'$label' must be finite" }
    return value
}

internal fun JsonObject.vector(key: String, size: Int): DoubleArray {
    val array = (this[key] as? JsonArray)?.takeIf { it.size == size } ?: throw IllegalArgumentException("'$key' must be an array of $size numbers")
    return DoubleArray(size) { numberOf(array[it], "$key[$it]") }
}

private fun JsonObject.matrix(key: String, rows: Int, columns: Int): Array<DoubleArray> {
    val array = (this[key] as? JsonArray)?.takeIf { it.size == rows } ?: throw IllegalArgumentException("'$key' must have $rows rows")
    return Array(rows) { row ->
        val values = array[row].jsonArray
        require(values.size == columns) { "'$key'[$row] must have $columns columns" }
        DoubleArray(columns) { numberOf(values[it], "$key[$row][$it]") }
    }
}
