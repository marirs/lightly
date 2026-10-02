package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.render.lut.Lut3D

/**
 * Procedural placeholder Looks for DEBUG builds and unit tests only. They are NOT vendor presets,
 * NOT derived from any preset collection, and NOT validated Looks: each LUT is generated in code
 * from a simple per-channel formula, so no LUT file exists in the repo or the APK. They only exist
 * so the stepped slider, two-pass rendering and Save copy can be exercised end to end until the
 * curated look-book (core-looks, M3/M4) lands.
 *
 * Lives in the debug source set so a release build cannot contain it (see BundledLookBook).
 */
object PlaceholderLookBook {
    const val PROVISIONAL_NOTICE = "Provisional Looks (debug build): procedural placeholders, not validated."

    fun create(): LookBook = LookBook(
        provisionalNotice = PROVISIONAL_NOTICE,
        looks = listOf(
            look("natural.soft", "Natural", 1, "Soft") { r, g, b -> Triple(lift(r, 0.04f), lift(g, 0.04f), lift(b, 0.04f)) },
            look("natural.crisp", "Natural", 2, "Crisp") { r, g, b -> Triple(contrast(r, 1.15f), contrast(g, 1.15f), contrast(b, 1.15f)) },
            look("warm.golden", "Warm", 1, "Golden") { r, g, b -> Triple(r * 1.06f + 0.02f, g * 1.02f, b * 0.9f) },
            look("warm.amber", "Warm", 2, "Amber") { r, g, b -> Triple(r * 1.1f + 0.03f, g * 1.03f, b * 0.82f) },
            look("cool.nordic", "Cool", 1, "Nordic") { r, g, b -> Triple(r * 0.92f, g * 1.0f, b * 1.08f + 0.02f) },
            look("film.fade", "Film", 1, "Fade") { r, g, b -> Triple(0.06f + 0.9f * r, 0.06f + 0.9f * g, 0.08f + 0.88f * b) },
            look("film.punch", "Film", 2, "Punch") { r, g, b -> Triple(contrast(r, 1.25f), contrast(g, 1.2f), contrast(b, 1.1f)) },
            look("film.teal", "Film", 3, "Teal") { r, g, b -> Triple(r * 1.04f, g, b * 0.95f + 0.05f * (1 - r)) },
            look("mono.silver", "Mono", 1, "Silver") { r, g, b ->
                val luma = 0.2126f * r + 0.7152f * g + 0.0722f * b
                Triple(luma, luma, luma)
            },
        ),
    )

    private fun lift(v: Float, amount: Float) = amount + (1 - amount) * v
    private fun contrast(v: Float, k: Float) = (0.5f + (v - 0.5f) * k)

    private fun look(id: String, category: String, stop: Int, name: String, transform: (Float, Float, Float) -> Triple<Float, Float, Float>): LookDefinition {
        val dimension = Lut3D.CONTRACT_DIMENSION
        val rgba = FloatArray(Lut3D.floatCount(dimension))
        for (b in 0 until dimension) for (g in 0 until dimension) for (r in 0 until dimension) {
            val (outR, outG, outB) = transform(Lut3D.gridValue(r, dimension), Lut3D.gridValue(g, dimension), Lut3D.gridValue(b, dimension))
            val base = (r + dimension * (g + dimension * b)) * 4
            rgba[base] = outR; rgba[base + 1] = outG; rgba[base + 2] = outB; rgba[base + 3] = 1f
        }
        return LookDefinition(id, "1", category, stop, name, Lut3D(dimension, rgba))
    }
}
