package com.lightlylabs.lightly.background

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** background.replace's foreground estimate (rendering-v2 revision 5) against the shared goldens (`foreground`). */
class ForegroundEstimateGoldensTest {
    private val dir = java.io.File(checkNotNull(System.getProperty("lightly.renderingGoldensDir")))
    private val index = Json.parseToJsonElement(java.io.File(dir, "index.json").readText()) as JsonObject

    private fun array(entry: JsonObject, key: String): FloatArray {
        val name = ((entry.getValue(key) as JsonObject).getValue("file") as JsonPrimitive).content
        val buffer = java.nio.ByteBuffer.wrap(java.io.File(dir, name).readBytes()).order(java.nio.ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        return FloatArray(buffer.remaining()).also { buffer.get(it) }
    }

    @Test
    fun `the foreground estimate and the composite equal the goldens`() {
        val cases = (index.getValue("foreground") as JsonArray).map { it as JsonObject }
        assertEquals(2, cases.size)
        for (case in cases) {
            val name = (case.getValue("name") as JsonPrimitive).content
            val width = (case.getValue("width") as JsonPrimitive).content.toInt()
            val height = (case.getValue("height") as JsonPrimitive).content.toInt()
            val image = FloatImage(width, height, 3, array(case, "image"))
            val alpha = FloatPlane(width, height, array(case, "alpha"))
            val expected = array(case, "foreground")
            val composite = array(case, "composite")
            val replacement = (case.getValue("replacement") as JsonArray).map { (it as JsonPrimitive).content.toFloat() }
            val foreground = ForegroundEstimate.estimate(image, alpha)
            var worstF = 0f
            var worstComposite = 0f
            for (i in expected.indices) {
                worstF = maxOf(worstF, abs(foreground.data[i] - expected[i]))
                val a = alpha.values[i / 3]
                worstComposite = maxOf(worstComposite, abs(foreground.data[i] * a + replacement[i % 3] * (1 - a) - composite[i]))
            }
            assertTrue(worstF <= 1e-4f, "$name foreground differs by $worstF")
            assertTrue(worstComposite <= 1e-4f, "$name composite differs by $worstComposite")
        }
    }
}
