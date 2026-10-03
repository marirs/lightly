package com.lightlylabs.lightly.develop

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Preset grain (rendering-v2 F2, revision 1: chromaticity kept, supersampled below two pixels per cell)
 * against the shared goldens in shared/fixtures/rendering (`grain` section): the unit noise field and the
 * grained image of `grain_input`, inside the stored crop. Tolerances from index.json.
 */
class GrainGoldensTest {
    private val dir = File(checkNotNull(System.getProperty("lightly.renderingGoldensDir")))
    private val index = Json.parseToJsonElement(File(dir, "index.json").readText()).jsonObject
    private val experimental = LookPackFixtures.model.experimental

    private fun array(entry: JsonObject): FloatArray {
        val bytes = File(dir, entry.getValue("file").jsonPrimitive.content).readBytes()
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        return FloatArray(buffer.remaining()).also { buffer.get(it) }
    }

    /** make_rendering_goldens.grain_input: two ramps and a saturated red block (chromaticity must survive). */
    private fun input(x: Int, y: Int, width: Int, height: Int): FloatArray =
        if (y < height / 3 && x < width / 3) floatArrayOf(0.75f, 0.2f, 0.15f)
        else floatArrayOf((0.35 + 0.5 * x / width).toFloat(), (0.25 + 0.4 * x / width).toFloat(), (0.2 + 0.3 * y / height).toFloat())

    @Test
    fun `grain noise and grained pixels equal the goldens, including supersampled cases`() {
        val report = StringBuilder()
        for (case in index.getValue("grain").jsonArray.map { it.jsonObject }) {
            val name = case.getValue("name").jsonPrimitive.content
            val height = case.getValue("height").jsonPrimitive.int
            val width = case.getValue("width").jsonPrimitive.int
            val p = case.getValue("params").jsonObject
            val grain = Grain(p.getValue("amount").jsonPrimitive.double, p.getValue("size").jsonPrimitive.double, p.getValue("roughness").jsonPrimitive.double, p.getValue("seed").jsonPrimitive.long)
            val pass = FinishingPass(null, grain, experimental, width, height)
            val crop = case["crop"]?.takeIf { it != JsonNull }?.jsonArray?.map { it.jsonPrimitive.int }
            val (row0, col0, rows, cols) = crop ?: listOf(0, 0, height, width)
            val noise = array(case.getValue("noise").jsonObject)
            val expected = array(case.getValue("expected").jsonObject)
            var worstNoise = 0.0
            var worstPixel = 0.0
            val work = DoubleArray(8)
            for (r in 0 until rows) for (c in 0 until cols) {
                val x = col0 + c
                val y = row0 + r
                worstNoise = maxOf(worstNoise, abs(pass.grainNoise(x, y, grain.roughness / 100) - noise[r * cols + c]))
                val rgb = input(x, y, width, height)
                pass.apply(rgb, x, y, work)
                for (k in 0 until 3) worstPixel = maxOf(worstPixel, abs(rgb[k] - expected[(r * cols + c) * 3 + k]).toDouble())
            }
            report.append("$name: noise %.2e, pixels %.2e\n".format(worstNoise, worstPixel))
            assertTrue(worstNoise <= 1e-4, "$name noise differs by $worstNoise")
            assertTrue(worstPixel <= 2e-4, "$name pixels differ by $worstPixel")
        }
        println(report)
    }

    @Test
    fun `the supersampling factors are the goldens'`() {
        for (case in index.getValue("grain").jsonArray.map { it.jsonObject }) {
            val height = case.getValue("height").jsonPrimitive.int
            val width = case.getValue("width").jsonPrimitive.int
            val size = case.getValue("params").jsonObject.getValue("size").jsonPrimitive.double / 100
            val cells = maxOf(8, Math.rint(experimental.grainRefLong / (1 + 4 * size)).toInt())
            val factor = maxOf(1, kotlin.math.ceil(2.0 * cells / maxOf(height, width)).toInt())
            assertEquals(case.getValue("supersampling").jsonPrimitive.int, factor, case.getValue("name").jsonPrimitive.content)
        }
    }
}
