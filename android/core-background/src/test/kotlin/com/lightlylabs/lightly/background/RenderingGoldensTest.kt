package com.lightlylabs.lightly.background

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * background.focus against the shared parity goldens (shared/fixtures/rendering, rendering-v2 revision 1,
 * contract fixes 1 G5): the constants, the scalar vectors, the kernels, pull-push, and the nine whole
 * renders of the synthetic scene. Tolerances are the ones `index.json` states.
 */
class RenderingGoldensTest {
    private val dir = File(checkNotNull(System.getProperty("lightly.renderingGoldensDir")))
    private val index = Json.parseToJsonElement(File(dir, "index.json").readText()).jsonObject
    private val focus = index.getValue("backgroundFocus").jsonObject

    private fun array(entry: JsonObject): FloatArray {
        val bytes = File(dir, entry.getValue("file").jsonPrimitive.content).readBytes()
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        return FloatArray(buffer.remaining()).also { buffer.get(it) }
    }

    private fun shape(entry: JsonObject) = entry.getValue("shape").jsonArray.map { it.jsonPrimitive.int }
    private fun JsonObject.num(key: String) = getValue(key).jsonPrimitive.double
    private fun JsonArray.doubles() = map { it.jsonPrimitive.double }

    @Test
    fun `the goldens are for rendering-v2 revision 4 and our constants equal the contract's`() {
        val version = index.getValue("renderingContract").jsonObject
        assertEquals(2, version.getValue("version").jsonPrimitive.int)
        // Revisions 2 and 4 kept every background.focus golden byte-identical.
        assertEquals(4, version.getValue("revision").jsonPrimitive.int)
        val contract = Json.parseToJsonElement(File(checkNotNull(System.getProperty("lightly.renderingContract"))).readText()).jsonObject
        assertEquals(4, contract.getValue("revision").jsonPrimitive.int, "bundled contract revision")
        val stage = contract.getValue("stages").jsonArray.map { it.jsonObject }.first { it.getValue("id").jsonPrimitive.content == "background.focus" }
        val constants = stage.getValue("operators").jsonArray[0].jsonObject.getValue("constants").jsonObject
        assertEquals(Refocus.FocusConstants.MAX_BLUR_FRACTION_OF_LONG_EDGE, constants.getValue("maxBlurRadius").jsonObject.num("value"))
        assertEquals(Refocus.FocusConstants.DOF_HALF_WIDTH_SCALE, constants.getValue("focusHalfWidthPerUnit").jsonObject.num("value"))
        val layers = constants.getValue("layersPerSide").jsonObject
        assertEquals(Refocus.FocusConstants.LAYERS_PER_SIDE_EXPORT, layers.getValue("export").jsonPrimitive.int)
        assertEquals(Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW, layers.getValue("interactivePreview").jsonPrimitive.int)
        assertEquals(Refocus.FocusConstants.SUBJECT_DEPTH_COMPRESSION, constants.num("subjectDepthCompression"))
        assertEquals(Refocus.FocusConstants.REPLACEMENT_MIN_GAP, constants.num("replacementMinGap"))
        val highlights = constants.getValue("highlightExpansion").jsonObject
        assertEquals(Refocus.FocusConstants.HIGHLIGHT_THRESHOLD, highlights.num("threshold"))
        assertEquals(Refocus.FocusConstants.HIGHLIGHT_GAIN, highlights.num("gain"))
    }

    @Test
    fun `signed CoC, half width, defocus range and maximum radius equal the goldens`() {
        for (case in focus.getValue("scalars").jsonObject.getValue("signedCoc").jsonArray.map { it.jsonObject }) {
            val focal = case.num("focal")
            val dof = case.num("depthOfField")
            val longEdge = case.getValue("longEdge").jsonPrimitive.int
            val half = Refocus.halfWidth(dof)
            val radius = Refocus.maxRadiusPx(case.num("blur"), longEdge)
            assertEquals(case.num("halfWidth"), half, 1e-4)
            assertEquals(case.num("defocusRange"), Refocus.defocusRange(focal), 1e-4)
            assertEquals(case.num("radiusMaxPx"), radius, 1e-4)
            val disparity = case.getValue("disparity").jsonArray.doubles()
            val expected = case.getValue("signedCocPx").jsonArray.doubles()
            for (i in disparity.indices) {
                assertEquals(expected[i], Refocus.signedCoc(disparity[i].toFloat(), focal, half, radius), 1e-4, "focal $focal dof $dof D=${disparity[i]}")
            }
        }
    }

    @Test
    fun `highlight expansion and its inverse equal the goldens`() {
        val h = focus.getValue("scalars").jsonObject.getValue("highlights").jsonObject
        val linear = h.getValue("linear").jsonArray.flatMap { it.jsonArray.doubles() }
        val image = FloatImage(linear.size / 3, 1, 3, FloatArray(linear.size) { linear[it].toFloat() })
        Refocus.expandHighlights(image)
        val expanded = h.getValue("expanded").jsonArray.flatMap { it.jsonArray.doubles() }
        for (i in expanded.indices) assertEquals(expanded[i], image.data[i].toDouble(), 1e-4, "expanded[$i]")
        Refocus.compressHighlights(image)
        val back = h.getValue("roundTrip").jsonArray.flatMap { it.jsonArray.doubles() }
        for (i in back.indices) assertEquals(back[i], image.data[i].toDouble(), 1e-4, "roundTrip[$i]")
    }

    @Test
    fun `kernels equal the goldens`() {
        for (k in focus.getValue("kernels").jsonArray.map { it.jsonObject }) {
            val radius = k.num("radius")
            val kernel = when (k.getValue("kind").jsonPrimitive.content) {
                // The generator merges the array's own "shape" into the entry, so the bokeh name comes from
                // the file name (kernel-<name>-<radius>.f32).
                "bokeh" -> Kernels.bokeh(k.getValue("file").jsonPrimitive.content.removePrefix("kernel-").substringBefore('-'), radius)
                "gaussian" -> Kernels.gaussian(radius)
                else -> Kernels.motion(radius, k.num("directionDegrees"))
            }
            val expected = array(k)
            assertEquals(shape(k)[0], kernel.size, "${k.getValue("file")} size")
            val worst = expected.indices.maxOf { abs(expected[it] - kernel.values[it]) }
            assertTrue(worst <= 1e-5, "${k.getValue("file")} differs by $worst")
        }
    }

    @Test
    fun `pull-push fills holes from neighbours, never black, as the goldens`() {
        for (case in focus.getValue("pullPush").jsonArray.map { it.jsonObject }) {
            val colourEntry = case.getValue("colour").jsonObject
            val (h, w) = shape(colourEntry)
            val colour = array(colourEntry)
            val coverage = FloatPlane(w, h, array(case.getValue("coverage").jsonObject))
            val premultiplied = FloatImage(w, h, 3, FloatArray(w * h * 3) { colour[it] * coverage.values[it / 3] })
            val filled = Refocus.pullPushFill(premultiplied, coverage)
            val expected = array(case.getValue("expected").jsonObject)
            val worst = expected.indices.maxOf { abs(expected[it] - filled.data[it]) }
            assertTrue(worst <= 1e-4, "${case.getValue("name")} differs by $worst")
        }
    }

    @Test
    fun `whole renders match the goldens perceptually`() {
        val scene = focus.getValue("scene").jsonObject
        val imageEntry = scene.getValue("image").jsonObject
        val (h, w) = shape(imageEntry)
        val srgb = array(imageEntry)
        val photoLinear = FloatImage(w, h, 3, FloatArray(srgb.size) { Refocus.srgbToLinear(srgb[it]) })
        val nearness = FloatPlane(w, h, array(scene.getValue("disparity").jsonObject))
        val matte = FloatPlane(w, h, array(scene.getValue("matte").jsonObject))
        val replacementEntry = focus.getValue("replacement").jsonObject
        val (rh, rw) = shape(replacementEntry)
        val replacementSrgb = ReplacementImage.photo(FloatImage(rw, rh, 3, array(replacementEntry)), w, h, 100.0, 50.0, 50.0)
        val replacementLinear = FloatImage(w, h, 3, FloatArray(w * h * 3) { Refocus.srgbToLinear(replacementSrgb.data[it]) })
        val report = StringBuilder()
        var failures = 0
        for (case in focus.getValue("renders").jsonArray.map { it.jsonObject }) {
            val p = case.getValue("params").jsonObject
            val withMatte = case.getValue("matte").jsonPrimitive.boolean
            val withReplacement = case.getValue("replacement").jsonPrimitive.boolean
            val built = Refocus.buildScene(photoLinear, nearness, if (withMatte) matte else null, if (withReplacement) replacementLinear else null)
            val tx = p.num("target_x")
            val ty = p.num("target_y")
            val params = FocusParams(
                blur = p.num("blur"), depthOfField = p.num("focus_depth"),
                style = p["style"]?.jsonPrimitive?.content ?: "lens", bokeh = p["bokeh"]?.jsonPrimitive?.content ?: "round",
                styleAmount = p["style_amount"]?.jsonPrimitive?.double ?: 50.0,
            )
            val focal = Refocus.focalNearness(built, tx, ty)
            assertEquals(case.num("focalDisparity"), focal, 1e-3, "${case.getValue("name")} focal")
            val subjectInFocus = withMatte && Refocus.focusIsOnSubject(built, tx, ty)
            assertEquals(case.getValue("subjectInFocus").jsonPrimitive.boolean, subjectInFocus, "${case.getValue("name")} subject in focus")
            val rendered = Refocus.render(built, params, focal, Refocus.FocusConstants.LAYERS_PER_SIDE_EXPORT, subjectInFocus)
            val expected = array(case.getValue("expected").jsonObject)
            val deltas = DoubleArray(w * h) { px ->
                deltaE00(
                    expected[px * 3].toDouble(), expected[px * 3 + 1].toDouble(), expected[px * 3 + 2].toDouble(),
                    Refocus.linearToSrgb(rendered.data[px * 3]).toDouble(), Refocus.linearToSrgb(rendered.data[px * 3 + 1]).toDouble(), Refocus.linearToSrgb(rendered.data[px * 3 + 2]).toDouble(),
                )
            }
            val mean = deltas.average()
            val p99 = deltas.sorted()[(deltas.size * 99) / 100]
            report.append("${case.getValue("name")}: ΔE00 mean %.3f p99 %.3f\n".format(mean, p99))
            if (mean > 1.0 || p99 > 4.0) failures++
        }
        println(report)
        assertEquals(0, failures, "renders outside ΔE00 mean ≤ 1, p99 ≤ 4:\n$report")
    }

    // --- CIEDE2000 on sRGB (D65), as depth-evaluation.md §R9 compares renders --------------------------

    private fun lab(r: Double, g: Double, b: Double): DoubleArray {
        fun lin(c: Double) = if (c <= 0.04045) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
        val lr = lin(r.coerceIn(0.0, 1.0)); val lg = lin(g.coerceIn(0.0, 1.0)); val lb = lin(b.coerceIn(0.0, 1.0))
        val x = (0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb) / 0.95047
        val y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb
        val z = (0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb) / 1.08883
        fun f(t: Double) = if (t > 216.0 / 24389) Math.cbrt(t) else (24389.0 / 27 * t + 16) / 116
        return doubleArrayOf(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    private fun deltaE00(r1: Double, g1: Double, b1: Double, r2: Double, g2: Double, b2: Double): Double {
        val (l1, a1, bb1) = lab(r1, g1, b1).let { Triple(it[0], it[1], it[2]) }
        val (l2, a2, bb2) = lab(r2, g2, b2).let { Triple(it[0], it[1], it[2]) }
        val c1 = sqrt(a1 * a1 + bb1 * bb1); val c2 = sqrt(a2 * a2 + bb2 * bb2)
        val cBar = (c1 + c2) / 2
        val g = 0.5 * (1 - sqrt(cBar.pow(7) / (cBar.pow(7) + 25.0.pow(7))))
        val ap1 = (1 + g) * a1; val ap2 = (1 + g) * a2
        val cp1 = sqrt(ap1 * ap1 + bb1 * bb1); val cp2 = sqrt(ap2 * ap2 + bb2 * bb2)
        fun hue(b: Double, a: Double) = if (b == 0.0 && a == 0.0) 0.0 else Math.toDegrees(atan2(b, a)).let { if (it < 0) it + 360 else it }
        val hp1 = hue(bb1, ap1); val hp2 = hue(bb2, ap2)
        val dL = l2 - l1; val dC = cp2 - cp1
        val dh = when {
            cp1 * cp2 == 0.0 -> 0.0
            abs(hp2 - hp1) <= 180 -> hp2 - hp1
            hp2 - hp1 > 180 -> hp2 - hp1 - 360
            else -> hp2 - hp1 + 360
        }
        val dH = 2 * sqrt(cp1 * cp2) * sin(Math.toRadians(dh / 2))
        val lBar = (l1 + l2) / 2; val cpBar = (cp1 + cp2) / 2
        val hBar = when {
            cp1 * cp2 == 0.0 -> hp1 + hp2
            abs(hp1 - hp2) <= 180 -> (hp1 + hp2) / 2
            hp1 + hp2 < 360 -> (hp1 + hp2 + 360) / 2
            else -> (hp1 + hp2 - 360) / 2
        }
        val t = 1 - 0.17 * cos(Math.toRadians(hBar - 30)) + 0.24 * cos(Math.toRadians(2 * hBar)) + 0.32 * cos(Math.toRadians(3 * hBar + 6)) - 0.20 * cos(Math.toRadians(4 * hBar - 63))
        val sl = 1 + 0.015 * (lBar - 50).pow(2) / sqrt(20 + (lBar - 50).pow(2))
        val sc = 1 + 0.045 * cpBar
        val sh = 1 + 0.015 * cpBar * t
        val rt = -2 * sqrt(cpBar.pow(7) / (cpBar.pow(7) + 25.0.pow(7))) * sin(Math.toRadians(60 * exp(-((hBar - 275) / 25).pow(2))))
        return sqrt((dL / sl).pow(2) + (dC / sc).pow(2) + (dH / sh).pow(2) + rt * (dC / sc) * (dH / sh))
    }

}
