package com.lightlylabs.lightly.background

import java.io.File
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Focus & Blur renderer: reference vectors from refocus.py, and the behaviours §R4–R8 require. */
class RefocusTest {
    private val vectors: String = File(checkNotNull(System.getProperty("lightly.refocusVectorsDir")), "vectors.json").readText()

    private fun numbers(json: String, key: String): List<Double> {
        val start = json.indexOf("\"$key\"")
        val open = json.indexOf('[', start)
        val close = json.indexOf(']', open)
        return json.substring(open + 1, close).split(',').map { it.trim().toDouble() }
    }

    @Test
    fun `aperture kernels equal refocus py`() {
        val cases = mapOf(
            "round-3.0" to Kernels.bokeh("round", 3.0), "round-7.3" to Kernels.bokeh("round", 7.3),
            "hex-3.0" to Kernels.bokeh("hex", 3.0), "hex-7.3" to Kernels.bokeh("hex", 7.3),
            "heart-3.0" to Kernels.bokeh("heart", 3.0), "heart-7.3" to Kernels.bokeh("heart", 7.3),
            "star-3.0" to Kernels.bokeh("star", 3.0), "star-7.3" to Kernels.bokeh("star", 7.3),
            "motion-6.0-30" to Kernels.motion(6.0, 30.0), "gaussian-5.0" to Kernels.gaussian(5.0),
        )
        for ((name, kernel) in cases) {
            val expected = numbers(vectors, name)
            assertEquals(expected.size, kernel.values.size, "$name size")
            val worst = expected.indices.maxOf { abs(expected[it] - kernel.values[it]) }
            assertTrue(worst < 1e-6, "$name differs by $worst")
        }
    }

    @Test
    fun `highlight expansion and its inverse equal refocus py`() {
        val input = numbers(vectors, "input")
        val expanded = numbers(vectors, "expanded")
        val image = FloatImage(4, 1, 3, input.map { it.toFloat() }.toFloatArray())
        Refocus.expandHighlights(image)
        input.indices.forEach { assertEquals(expanded[it], image.data[it].toDouble(), 1e-5) }
        Refocus.compressHighlights(image)
        input.indices.forEach { assertEquals(input[it], image.data[it].toDouble(), 1e-5) }
    }

    @Test
    fun `blur zero is the identity`() {
        val (colour, nearness) = twoPlaneScene()
        val scene = Refocus.buildScene(colour, nearness, null)
        val out = Refocus.render(scene, FocusParams(0.0, 40.0, "lens", "round", 50.0), focal = 0.9)
        colour.data.indices.forEach { assertEquals(colour.data[it], out.data[it], 1e-4f) }
    }

    @Test
    fun `focusing near keeps the near half sharp and blurs the far half, and the reverse`() {
        val (colour, nearness) = twoPlaneScene()
        val scene = Refocus.buildScene(colour, nearness, null)
        val params = FocusParams(100.0, 20.0, "lens", "round", 50.0)
        val sharpVariance = variance(colour, 4, 24)
        val focusNear = Refocus.render(scene, params, Refocus.focalNearness(scene, 0.2, 0.5))
        assertEquals(sharpVariance, variance(focusNear, 4, 24), sharpVariance * 0.02)
        assertTrue(variance(focusNear, 40, 60) < sharpVariance * 0.2, "far half is blurred")
        val focusFar = Refocus.render(scene, params, Refocus.focalNearness(scene, 0.8, 0.5))
        assertEquals(sharpVariance, variance(focusFar, 40, 60), sharpVariance * 0.02)
        assertTrue(variance(focusFar, 4, 24) < sharpVariance * 0.2, "near half is blurred")
    }

    @Test
    fun `every style renders and keeps mean brightness`() {
        val (colour, nearness) = twoPlaneScene()
        val scene = Refocus.buildScene(colour, nearness, null)
        val mean = colour.data.average()
        for (style in listOf("lens", "soft", "swirl", "motion")) for (bokeh in listOf("round", "hex", "heart", "star")) {
            if (style != "lens" && bokeh != "round") continue
            val out = Refocus.render(scene, FocusParams(80.0, 30.0, style, bokeh, if (style == "soft") 0.0 else 50.0), 0.9, layersPerSide = 4)
            assertEquals(mean, out.data.average(), 0.03, "$style/$bokeh")
        }
    }

    @Test
    fun `a subject plane stays sharp in front of a blurred replacement`() {
        // 200 px so the maximum radius (0.03 of the long edge) is 6 px: enough to average a 1 px checker.
        val w = 200
        val h = 200
        val photo = FloatImage(w, h, 3, FloatArray(w * h * 3) { 0.5f })
        val matte = FloatPlane(w, h, FloatArray(w * h) { p -> val x = p % w; val y = p / w; if ((x - 100) * (x - 100) + (y - 100) * (y - 100) < 2500) 1f else 0f })
        val nearness = FloatPlane(w, h, FloatArray(w * h) { if (matte.values[it] > 0.5f) 0.9f else 0.2f })
        val replacement = FloatImage(w, h, 3, FloatArray(w * h * 3) { i -> val p = i / 3; if ((p % w + p / w) % 2 == 0) 0.6f else 0.2f })
        val scene = Refocus.buildScene(photo, nearness, matte, replacement)
        assertTrue(scene.background.nearness.values.all { it <= 0.8f + 1e-6f }, "replacement stays behind the subject")
        val out = Refocus.render(scene, FocusParams(100.0, 10.0, "lens", "round", 50.0), Refocus.focalNearness(scene, 0.5, 0.5))
        assertEquals(0.5f, out.data[(100 * w + 100) * 3], 0.02f)
        val corner = (10 until 30).flatMap { y -> (10 until 30).map { x -> out.data[(y * w + x) * 3] } }
        val mean = corner.average()
        val std = kotlin.math.sqrt(corner.sumOf { (it - mean) * (it - mean) } / corner.size)
        assertTrue(std < 0.05, "checker replacement (std 0.2) is blurred toward its mean, std was $std")
    }

    @Test
    fun `pull push leaves full coverage unchanged and fills holes from neighbours`() {
        val w = 20
        val h = 20
        val colour = FloatImage(w, h, 1, FloatArray(w * h) { 0.7f })
        val full = Refocus.pullPushFill(colour, FloatPlane.filled(w, h, 1f))
        full.data.forEach { assertEquals(0.7f, it, 1e-5f) }
        val coverage = FloatPlane(w, h, FloatArray(w * h) { if (it % w < 10) 1f else 0f })
        val premultiplied = FloatImage(w, h, 1, FloatArray(w * h) { 0.7f * coverage.values[it] })
        // Revision 1 (contract fixes 1, G7): the pyramid is pulled to 1 × 1, so every hole takes the
        // covered colour; the earlier reference filled far holes toward black (that pin is gone).
        Refocus.pullPushFill(premultiplied, coverage).data.forEach { assertEquals(0.7f, it, 1e-4f) }
    }

    @Test
    fun `refine strokes add and erase within their radius only`() {
        val matte = FloatPlane(40, 20, FloatArray(800))
        val added = MatteRefinement.apply(matte, listOf(MatteStroke(true, 0.1, listOf(0.5 to 0.5))))
        assertEquals(1f, added[20, 10], 1e-6f)
        assertEquals(0f, added[0, 0], 1e-6f)
        val erased = MatteRefinement.apply(added, listOf(MatteStroke(false, 0.05, listOf(0.5 to 0.5))))
        assertEquals(0f, erased[20, 10], 1e-6f)
        assertEquals(1f, erased[22, 10], 1e-6f, "outside the eraser (2 px) the added area stays")
    }

    private fun twoPlaneScene(): Pair<FloatImage, FloatPlane> {
        // Left half near (nearness 0.9), right half far (0.1); a fine checker so blur is measurable.
        val w = 64
        val h = 48
        val colour = FloatImage(w, h, 3, FloatArray(w * h * 3) { i -> val p = i / 3; val x = p % w; val y = p / w; if ((x + y) % 2 == 0) 0.6f else 0.2f })
        val nearness = FloatPlane(w, h, FloatArray(w * h) { if (it % w < w / 2) 0.9f else 0.1f })
        return colour to nearness
    }

    private fun variance(image: FloatImage, fromX: Int, toX: Int): Double {
        val values = ArrayList<Float>()
        for (y in 8 until image.height - 8) for (x in fromX until toX) values += image.data[(y * image.width + x) * 3]
        val mean = values.average()
        return values.sumOf { (it - mean) * (it - mean) } / values.size
    }

}
