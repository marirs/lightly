package com.lightlylabs.lightly.develop

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/**
 * A preset's `recipe` (rendering-v2.md §3, recipeVersion 1): `{global, spatial, finishing}`.
 *
 * Strict: an operator or parameter this port does not know is an error, never ignored. A newer pack
 * with an operator added would otherwise render without it while claiming the same Look.
 * [json] keeps the original object so [LookVersion] can hash it byte-for-byte as build_pack.py does.
 */
class PresetRecipe(val global: GlobalRecipe, val spatial: SpatialRecipe, val finishing: FinishingRecipe, val json: JsonObject) {
    companion object {
        fun parse(recipe: JsonObject): PresetRecipe {
            recipe.requireOnly("recipe", setOf("global", "spatial", "finishing"))
            return PresetRecipe(
                global = GlobalRecipe.parse(recipe["global"]?.jsonObject ?: JsonObject(emptyMap())),
                spatial = SpatialRecipe.parse(recipe["spatial"]?.jsonObject ?: JsonObject(emptyMap())),
                finishing = FinishingRecipe.parse(recipe["finishing"]?.jsonObject ?: JsonObject(emptyMap())),
                json = recipe,
            )
        }
    }
}

class Calibration(val redHue: Double, val redSaturation: Double, val greenHue: Double, val greenSaturation: Double, val blueHue: Double, val blueSaturation: Double)
class WhiteBalance(val temperature: Double, val tint: Double)
class ToneSliders(val contrast: Double, val highlights: Double, val shadows: Double, val whites: Double, val blacks: Double)
class ParametricCurve(
    val shadows: Double, val darks: Double, val lights: Double, val highlights: Double,
    val shadowSplit: Double, val midtoneSplit: Double, val highlightSplit: Double,
)

/** Point curves, [[x, y], …] in 0…255 per channel; null = identity for that channel. */
class ToneCurve(val master: List<DoubleArray>?, val red: List<DoubleArray>?, val green: List<DoubleArray>?, val blue: List<DoubleArray>?)
class Hsl(val hue: DoubleArray, val saturation: DoubleArray, val luminance: DoubleArray)
class VibranceSaturation(val vibrance: Double, val saturation: Double)
class GradeZone(val hue: Double, val saturation: Double, val luminance: Double)
class ColorGrading(val shadows: GradeZone, val midtones: GradeZone, val highlights: GradeZone, val global: GradeZone, val balance: Double, val blending: Double)

/** recipe.global: every operator is optional; an absent one is neutral. */
class GlobalRecipe(
    val calibration: Calibration? = null,
    val whiteBalance: WhiteBalance? = null,
    val exposureEv: Double = 0.0,
    val shadowTint: Double = 0.0,
    val toneSliders: ToneSliders? = null,
    val dehaze: Double = 0.0,
    val parametricCurve: ParametricCurve? = null,
    val toneCurve: ToneCurve? = null,
    val hsl: Hsl? = null,
    val vibranceSaturation: VibranceSaturation? = null,
    val colorGrading: ColorGrading? = null,
    val grayscaleMix: DoubleArray? = null,
) {
    companion object {
        val NEUTRAL = GlobalRecipe()

        fun parse(g: JsonObject): GlobalRecipe {
            g.requireOnly("recipe.global", OPERATORS)
            return GlobalRecipe(
                calibration = g.operator("calibration", setOf("redHue", "redSaturation", "greenHue", "greenSaturation", "blueHue", "blueSaturation")) {
                    Calibration(it.number("redHue"), it.number("redSaturation"), it.number("greenHue"), it.number("greenSaturation"), it.number("blueHue"), it.number("blueSaturation"))
                },
                whiteBalance = g.operator("whiteBalance", setOf("temperature", "tint")) { WhiteBalance(it.number("temperature"), it.number("tint")) },
                exposureEv = g.operator("exposure", setOf("ev")) { it.number("ev") } ?: 0.0,
                shadowTint = g.operator("shadowTint", setOf("amount")) { it.number("amount") } ?: 0.0,
                toneSliders = g.operator("toneSliders", setOf("contrast", "highlights", "shadows", "whites", "blacks")) {
                    ToneSliders(it.number("contrast"), it.number("highlights"), it.number("shadows"), it.number("whites"), it.number("blacks"))
                },
                dehaze = g.operator("dehaze", setOf("amount")) { it.number("amount") } ?: 0.0,
                parametricCurve = g.operator("parametricCurve", setOf("shadows", "darks", "lights", "highlights", "shadowSplit", "midtoneSplit", "highlightSplit")) {
                    ParametricCurve(it.number("shadows"), it.number("darks"), it.number("lights"), it.number("highlights"), it.number("shadowSplit"), it.number("midtoneSplit"), it.number("highlightSplit"))
                },
                toneCurve = g.operator("toneCurve", setOf("master", "red", "green", "blue"), requireAll = false) {
                    ToneCurve(it.points("master"), it.points("red"), it.points("green"), it.points("blue"))
                },
                hsl = g.operator("hsl", setOf("hue", "saturation", "luminance")) { Hsl(it.vector("hue", 8), it.vector("saturation", 8), it.vector("luminance", 8)) },
                vibranceSaturation = g.operator("vibranceSaturation", setOf("vibrance", "saturation")) { VibranceSaturation(it.number("vibrance"), it.number("saturation")) },
                colorGrading = g.operator("colorGrading", setOf("shadows", "midtones", "highlights", "global", "balance", "blending")) {
                    ColorGrading(it.zone("shadows"), it.zone("midtones"), it.zone("highlights"), it.zone("global"), it.number("balance"), it.number("blending"))
                },
                grayscaleMix = g.operator("grayscale", setOf("mix")) { it.vector("mix", 8) },
            )
        }

        /** recipe.global operators in pipeline order (manifest operatorOrder.global). */
        val OPERATORS = setOf(
            "calibration", "whiteBalance", "exposure", "shadowTint", "toneSliders", "dehaze",
            "parametricCurve", "toneCurve", "hsl", "vibranceSaturation", "colorGrading", "grayscale",
        )

        private fun JsonObject.zone(key: String): GradeZone {
            val zone = getValue(key).jsonObject
            zone.requireOnly("colorGrading.$key", setOf("hue", "saturation", "luminance"), requireAll = true)
            return GradeZone(zone.number("hue"), zone.number("saturation"), zone.number("luminance"))
        }

        private fun JsonObject.points(key: String): List<DoubleArray>? {
            val array = this[key] as? JsonArray ?: return null
            require(array.size >= 2) { "toneCurve.$key needs at least two points" }
            val points = array.map { point ->
                val pair = point.jsonArray
                require(pair.size == 2) { "toneCurve.$key points are [x, y]" }
                doubleArrayOf(numberOf(pair[0], "toneCurve.$key.x"), numberOf(pair[1], "toneCurve.$key.y"))
            }
            // The generator normalises curves (sorted, unique x); a curve that is not is refused, not repaired.
            require(points.zipWithNext().all { (a, b) -> b[0] > a[0] }) { "toneCurve.$key x values must strictly increase" }
            return points
        }
    }
}

class NoiseReduction(
    val luminance: Double, val luminanceDetail: Double, val luminanceContrast: Double,
    val color: Double, val colorDetail: Double, val colorSmoothness: Double,
)
class Sharpening(val amount: Double, val radius: Double, val detail: Double, val edgeMasking: Double)

/** recipe.spatial (stage develop.spatial). */
class SpatialRecipe(
    val noiseReduction: NoiseReduction? = null,
    val clarity: Double = 0.0,
    val texture: Double = 0.0,
    val sharpening: Sharpening? = null,
) {
    val isNeutral: Boolean
        get() = (noiseReduction == null || (noiseReduction.luminance == 0.0 && noiseReduction.color == 0.0)) &&
            clarity == 0.0 && texture == 0.0 && (sharpening == null || sharpening.amount == 0.0)

    companion object {
        val NEUTRAL = SpatialRecipe()

        fun parse(s: JsonObject): SpatialRecipe {
            s.requireOnly("recipe.spatial", setOf("noiseReduction", "clarity", "texture", "sharpening"))
            return SpatialRecipe(
                noiseReduction = s.operator("noiseReduction", setOf("luminance", "luminanceDetail", "luminanceContrast", "color", "colorDetail", "colorSmoothness")) {
                    NoiseReduction(it.number("luminance"), it.number("luminanceDetail"), it.number("luminanceContrast"), it.number("color"), it.number("colorDetail"), it.number("colorSmoothness"))
                },
                clarity = s.operator("clarity", setOf("amount")) { it.number("amount") } ?: 0.0,
                texture = s.operator("texture", setOf("amount")) { it.number("amount") } ?: 0.0,
                sharpening = s.operator("sharpening", setOf("amount", "radius", "detail", "edgeMasking")) {
                    Sharpening(it.number("amount"), it.number("radius"), it.number("detail"), it.number("edgeMasking"))
                },
            )
        }
    }
}

class Vignette(val amount: Double, val midpoint: Double, val feather: Double, val roundness: Double, val style: Int, val highlightContrast: Double)
class Grain(val amount: Double, val size: Double, val roughness: Double, val seed: Long)

/** recipe.finishing: evaluated in the Effects stage (rendering-v2.md §1), not in develop.spatial. */
class FinishingRecipe(val vignette: Vignette? = null, val grain: Grain? = null) {
    companion object {
        val NEUTRAL = FinishingRecipe()

        fun parse(f: JsonObject): FinishingRecipe {
            f.requireOnly("recipe.finishing", setOf("vignette", "grain"))
            return FinishingRecipe(
                vignette = f.operator("vignette", setOf("amount", "midpoint", "feather", "roundness", "style", "highlightContrast")) {
                    val style = it.number("style")
                    require(style == 1.0 || style == 2.0 || style == 3.0) { "vignette.style must be 1, 2 or 3" }
                    Vignette(it.number("amount"), it.number("midpoint"), it.number("feather"), it.number("roundness"), style.toInt(), it.number("highlightContrast"))
                },
                grain = f.operator("grain", setOf("amount", "size", "roughness", "seed")) {
                    val seed = it.number("seed")
                    require(seed >= 0 && seed <= 4294967295.0 && seed == Math.floor(seed)) { "grain.seed must be a uint32" }
                    Grain(it.number("amount"), it.number("size"), it.number("roughness"), seed.toLong())
                },
            )
        }
    }
}

private fun <T> JsonObject.operator(key: String, params: Set<String>, requireAll: Boolean = true, read: (JsonObject) -> T): T? {
    val operator = this[key] ?: return null
    val body = operator as? JsonObject ?: throw IllegalArgumentException("operator '$key' must be an object")
    body.requireOnly(key, params, requireAll)
    return read(body)
}

/** Rejects unknown keys; with [requireAll], every listed key must be present (contract: fully specified). */
internal fun JsonObject.requireOnly(label: String, allowed: Set<String>, requireAll: Boolean = false) {
    val unknown = keys - allowed
    require(unknown.isEmpty()) { "$label has unknown keys $unknown" }
    if (requireAll) {
        val missing = allowed - keys
        require(missing.isEmpty()) { "$label is missing $missing" }
    }
}
