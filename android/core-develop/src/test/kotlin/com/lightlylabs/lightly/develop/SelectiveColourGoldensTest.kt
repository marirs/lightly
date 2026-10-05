package com.lightlylabs.lightly.develop

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Selective colour (rendering-v2 revision 4) against the shared goldens (`selectiveColour`): the sampled picks, keep, output. */
class SelectiveColourGoldensTest {
    private val dir = java.io.File(checkNotNull(System.getProperty("lightly.renderingGoldensDir")))
    private val index = Json.parseToJsonElement(java.io.File(dir, "index.json").readText()) as JsonObject

    private fun array(entry: JsonObject, key: String): FloatArray {
        val name = ((entry.getValue(key) as JsonObject).getValue("file") as JsonPrimitive).content
        val buffer = java.nio.ByteBuffer.wrap(java.io.File(dir, name).readBytes()).order(java.nio.ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        return FloatArray(buffer.remaining()).also { buffer.get(it) }
    }

    private fun num(o: JsonObject, k: String) = (o.getValue(k) as JsonPrimitive).content.toDouble()

    @Test
    fun `selective colour equals the goldens`() {
        val cases = (index.getValue("selectiveColour") as JsonArray).map { it as JsonObject }
        assertEquals(5, cases.size)
        for (case in cases) {
            val name = (case.getValue("name") as JsonPrimitive).content
            val width = num(case, "width").toInt()
            val height = num(case, "height").toInt()
            val params = case.getValue("params") as JsonObject
            val input = array(case, "input")
            val keepExpected = array(case, "keep")
            val expected = array(case, "expected")

            // The sampled picks.
            val picks = (case.getValue("picks") as JsonArray).map { p -> (p as JsonArray).map { (it as JsonPrimitive).content.toDouble() } }
            val colours = (params.getValue("colours") as JsonArray).map { c -> (c as JsonArray).map { (it as JsonPrimitive).content.toDouble() } }
            for ((pick, colour) in picks.zip(colours)) {
                val sampled = SelectiveColour.sample(width, height, pick[0], pick[1]) { x, y, c -> ColourMath.srgbToLinear(input[(y * width + x) * 3 + c].toDouble()) }
                assertEquals(colour[0], sampled.lightness, 1e-4, "$name pick L")
                assertEquals(colour[1], sampled.a, 1e-4, "$name pick a")
                assertEquals(colour[2], sampled.b, 1e-4, "$name pick b")
            }

            val effects = EffectsParams(selectiveColours = colours.map { KeptColour(it[0], it[1], it[2]) },
                selectiveRange = num(params, "range"), selectiveStrength = num(params, "strength"))
            val operator = SelectiveColour.of(effects)
            val work = DoubleArray(6)
            val lab = DoubleArray(3)
            var worstKeep = 0.0
            var worstOut = 0.0
            for (p in 0 until width * height) {
                val rgb = floatArrayOf(input[p * 3], input[p * 3 + 1], input[p * 3 + 2])
                ColourMath.linearToOklab(ColourMath.srgbToLinear(rgb[0].toDouble()), ColourMath.srgbToLinear(rgb[1].toDouble()), ColourMath.srgbToLinear(rgb[2].toDouble()), lab)
                val keep = operator?.keep(lab[0], lab[1], lab[2]) ?: 0.0
                worstKeep = maxOf(worstKeep, abs(keep - keepExpected[p]))
                operator?.apply(rgb, work)
                for (c in 0 until 3) worstOut = maxOf(worstOut, abs(rgb[c] - expected[p * 3 + c]).toDouble())
            }
            assertTrue(worstKeep <= 2e-4, "$name keep differs by $worstKeep")
            assertTrue(worstOut <= 2e-4, "$name output differs by $worstOut")
        }
    }

    @Test
    fun `no kept colours leaves the effects stage empty`() {
        assertTrue(!EffectsParams().anyEnabled)
        assertTrue(EffectsParams(selectiveColours = listOf(KeptColour(0.5, 0.2, 0.1))).anyEnabled)
    }
}
