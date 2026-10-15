package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.background.PlaneOps
import com.lightlylabs.lightly.render.image.FrameSource
import com.lightlylabs.lightly.session.NormalisedRect
import com.lightlylabs.lightly.vision.sunglasses.FaceSunglassesAnalysis
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * rendering-v2 §7.5 composite step 1 on Android: a face found wearing glasses has them painted out before the chosen pair
 * goes on, with Remove's LaMa model, and the fill is kept as a [RemovePatch] by digest exactly as a Remove stroke's is
 * (`faceEdit.sunglasses.removed`), so preview and export composite the same pixels and the model never runs again for it.
 * A port of iOS `SunglassesRemoval.swift`: the same dilation, window and feather.
 */
object SunglassesRemoval {
    /** The trial's MaxFilters 15, 15, 15 and 9 px on a 2000 px photo: a radius of 25 px per 2000 px of the long edge. */
    const val DILATION_OF_LONG_EDGE = 0.0125
    const val CONTEXT_FACTOR = 1.5
    const val MINIMUM_WINDOW = 256
    const val FEATHER_SIGMA = 3.0
    /** Glare on the old lenses (owner report 2026-10-15; iOS SunglassesRemoval.addGlare): in the lower part of each lens
     *  ellipse, outside the eye ellipses and clear of the nose, pixels brighter than their surroundings (blurred over
     *  GLARE_SIGMA × d) by GLARE_CONTRAST and brighter than GLARE_MIN_LUMINANCE are painted out too. */
    const val GLARE_SIGMA = 0.08f; const val GLARE_CONTRAST = 0.08f; const val GLARE_MIN_LUMINANCE = 0.45f
    const val KEEP_EYE_RADIUS_X = 0.3f; const val KEEP_EYE_RADIUS_Y = 0.14f
    const val LENS_RADIUS_X = 0.5f; const val LENS_RADIUS_Y = 0.42f
    const val GLARE_NOSE_CLEARANCE = 0.35f
    /** Past a turned face's outline on its far side, the fill comes from the surrounding background (normalized
     *  convolution at growing scales × d), blended by the background probability (owner report 2026-10-15: a
     *  skin-coloured smear past the cheek). */
    val BACKGROUND_FILL_SIGMAS = floatArrayOf(0.05f, 0.1f, 0.2f, 0.4f, 0.8f)
    const val TURNED_EYE_RATIO = 0.8f
    const val BACKGROUND_FILL_CELLS_PER_IRIS_SPAN = 24f

    class Result(val patch: RemovePatch, val rect: NormalisedRect)

    /** The patch for [analysis]'s face, or null when it wears no glasses. [frame] is the photo at full resolution. */
    fun patch(analysis: FaceSunglassesAnalysis, frame: FrameSource, inpainter: Inpainter, cancelled: () -> Boolean = { false }): Result? {
        val glasses = analysis.glassesMask() ?: return null
        val w = frame.width; val h = frame.height
        val f = w.toDouble() / analysis.analysisWidth   // source pixels per analysis pixel
        val radius = (DILATION_OF_LONG_EDGE * max(analysis.analysisWidth, analysis.analysisHeight)).roundToInt()
        val gx0 = glasses.x0 - radius; val gy0 = glasses.y0 - radius
        val gw = glasses.width + 2 * radius; val gh = glasses.height + 2 * radius
        val plane = FloatPlane(gw, gh)
        for (y in 0 until glasses.height) for (x in 0 until glasses.width) if (glasses.mask[y * glasses.width + x]) plane[x + radius, y + radius] = 1f
        // Square dilation, as iOS FloatImage.dilated: a box mean above zero marks every pixel within the radius.
        val spread = PlaneOps.boxFilter(plane, radius)
        val dilated = BooleanArray(gw * gh) { spread.values[it] > 1e-6f }
        addGlare(dilated, gw, gh, gx0, gy0, radius, analysis, frame, f)
        fun masked(sx: Double, sy: Double): Boolean {
            val ax = floor(sx / f).toInt() - gx0; val ay = floor(sy / f).toInt() - gy0
            return ax in 0 until gw && ay in 0 until gh && dilated[ay * gw + ax]
        }
        var lx = Int.MAX_VALUE; var ly = Int.MAX_VALUE; var hx = Int.MIN_VALUE; var hy = Int.MIN_VALUE
        for (y in 0 until gh) for (x in 0 until gw) if (dilated[y * gw + x]) { lx = min(lx, x); ly = min(ly, y); hx = max(hx, x); hy = max(hy, y) }
        if (lx > hx) return null
        val bx0 = max(0, ((lx + gx0) * f).toInt()); val by0 = max(0, ((ly + gy0) * f).toInt())
        val bx1 = min(w, ceil((hx + gx0 + 1) * f).toInt()); val by1 = min(h, ceil((hy + gy0 + 1) * f).toInt())
        if (bx1 <= bx0 || by1 <= by0) return null
        // The context window: 1.5 × the mask's extent, at least 256 px, inside the photo.
        val extent = max(bx1 - bx0, by1 - by0)
        val side = minOf(max((extent * CONTEXT_FACTOR).toInt(), MINIMUM_WINDOW), w, h)
        val wx = ((bx0 + bx1) / 2.0 - side / 2.0).toInt().coerceIn(0, w - side)
        val wy = ((by0 + by1) / 2.0 - side / 2.0).toInt().coerceIn(0, h - side)
        val window = frame.region(wx, wy, side, side)
        val n = RemoveEngine.MODEL_SIDE; val nn = n * n
        val scale = side.toDouble() / n
        val image = FloatArray(3 * nn); val mask = FloatArray(nn)
        for (my in 0 until n) for (mx in 0 until n) {
            val sx = (mx + 0.5) * scale - 0.5; val sy = (my + 0.5) * scale - 0.5
            val i = my * n + mx
            bilinear(window.pixels, side, sx, sy) { c, v -> image[c * nn + i] = v }
            if (masked(wx + sx + 0.5, wy + sy + 0.5)) mask[i] = 1f
        }
        if (cancelled()) throw kotlinx.coroutines.CancellationException("Sunglasses removal cancelled")
        val filled = inpainter.inpaint(image, mask)
        require(filled.size == 3 * nn) { "inpainter returned ${filled.size} values" }
        if (cancelled()) throw kotlinx.coroutines.CancellationException("Sunglasses removal cancelled")
        // Paste back over the mask's box, alpha = the mask feathered by a Gaussian.
        val pw = bx1 - bx0; val ph = by1 - by0
        val alphaPlane = FloatPlane(pw, ph)
        for (y in 0 until ph) for (x in 0 until pw) if (masked(bx0 + x + 0.5, by0 + y + 0.5)) alphaPlane[x, y] = 1f
        val alpha = PlaneOps.gaussianBlur(alphaPlane, FEATHER_SIGMA * max(1.0, f))
        val backdrop = backgroundFill(bx0, by0, pw, ph, frame, analysis, f, ::masked)
        val rgba = ByteArray(pw * ph * 4)
        for (y in 0 until ph) for (x in 0 until pw) {
            val a = alpha[x, y]
            if (a <= 0.002f) continue
            val mx = ((bx0 + x - wx + 0.5) / scale - 0.5).coerceIn(0.0, n - 1.0)
            val my = ((by0 + y - wy + 0.5) / scale - 0.5).coerceIn(0.0, n - 1.0)
            val o = (y * pw + x) * 4
            val t = backdrop.second[y * pw + x].toDouble()
            for (c in 0 until 3) {
                val v = bilinearPlane(filled, c * nn, n, mx, my) * (1 - t) + backdrop.first[(y * pw + x) * 3 + c] * t
                rgba[o + c] = (v * 255 + 0.5).toInt().coerceIn(0, 255).toByte()
            }
            rgba[o + 3] = (a * 255 + 0.5f).toInt().coerceIn(0, 255).toByte()
        }
        val patch = RemovePatch(bx0, by0, pw, ph, rgba, w, h)
        return Result(patch, NormalisedRect(bx0.toDouble() / w, by0.toDouble() / h, pw.toDouble() / w, ph.toDouble() / h))
    }

    private fun lm(a: FaceSunglassesAnalysis, i: Int) = floatArrayOf(a.landmarks[i * 3], a.landmarks[i * 3 + 1])

    /** iOS SunglassesRemoval.addGlare: the old lenses' glare added to [mask] (analysis pixels over the band box). */
    private fun addGlare(mask: BooleanArray, w: Int, h: Int, ox: Int, oy: Int, radius: Int, a: FaceSunglassesAnalysis, frame: FrameSource, f: Double) {
        val sx0 = max(0, (ox * f).toInt()); val sy0 = max(0, (oy * f).toInt())
        val sx1 = min(frame.width, ceil((ox + w) * f).toInt()); val sy1 = min(frame.height, ceil((oy + h) * f).toInt())
        if (sx1 <= sx0 || sy1 <= sy0) return
        val region = frame.region(sx0, sy0, sx1 - sx0, sy1 - sy0); val rw = sx1 - sx0
        val lum = FloatPlane(w, h)
        for (y in 0 until h) for (x in 0 until w) {
            val px = (((x + ox) + 0.5) * f).toInt().minus(sx0).coerceIn(0, rw - 1)
            val py = (((y + oy) + 0.5) * f).toInt().minus(sy0).coerceIn(0, sy1 - sy0 - 1)
            val o = (py * rw + px) * 4
            fun ch(c: Int) = (region.pixels[o + c].toInt() and 0xff) / 255f
            lum[x, y] = 0.2126f * ch(0) + 0.7152f * ch(1) + 0.0722f * ch(2)
        }
        val d = a.irisSpan
        val surround = PlaneOps.gaussianBlur(lum, max(1.0, (GLARE_SIGMA * d).toDouble()))
        val eyes = listOf(floatArrayOf((lm(a, 33)[0] + lm(a, 133)[0]) / 2, (lm(a, 33)[1] + lm(a, 133)[1]) / 2),
                          floatArrayOf((lm(a, 362)[0] + lm(a, 263)[0]) / 2, (lm(a, 362)[1] + lm(a, 263)[1]) / 2))
        val ex = lm(a, 263)[0] - lm(a, 33)[0]; val ey = lm(a, 263)[1] - lm(a, 33)[1]
        val el = kotlin.math.hypot(ex, ey); val ux = ex / el; val uy = ey / el; val vx = -uy; val vy = ux
        fun within(px: Float, py: Float, e: FloatArray, rx: Float, ry: Float): Boolean {
            val qx = px - e[0]; val qy = py - e[1]
            val s = (qx * ux + qy * uy) / (rx * d); val t = (qx * vx + qy * vy) / (ry * d)
            return s * s + t * t <= 1
        }
        val nose = intArrayOf(1, 4, 5, 195).map { lm(a, it) }
        val glare = FloatPlane(w, h)
        for (y in 0 until h) for (x in 0 until w) {
            val i = y * w + x
            if (mask[i]) continue
            if (lum.values[i] <= GLARE_MIN_LUMINANCE || lum.values[i] - surround.values[i] <= GLARE_CONTRAST) continue
            val px = x + ox + 0.5f; val py = y + oy + 0.5f
            val below = eyes.any { (px - it[0]) * vx + (py - it[1]) * vy > 0 }
            val nearNose = nose.any { kotlin.math.hypot(px - it[0], py - it[1]) < GLARE_NOSE_CLEARANCE * d }
            val inLens = below && !nearNose && eyes.any { within(px, py, it, LENS_RADIUS_X, LENS_RADIUS_Y) }
            val nearEye = eyes.any { within(px, py, it, KEEP_EYE_RADIUS_X, KEEP_EYE_RADIUS_Y) }
            if (inLens && !nearEye) glare.values[i] = 1f
        }
        val grown = PlaneOps.boxFilter(glare, max(1, radius / 2))
        for (i in 0 until w * h) if (grown.values[i] > 1e-6f) mask[i] = true
    }

    /** iOS SunglassesRemoval.backgroundFill: (rgb 0…1, weight) per patch pixel. */
    private fun backgroundFill(x0: Int, y0: Int, pw: Int, ph: Int, frame: FrameSource, a: FaceSunglassesAnalysis, f: Double,
                               masked: (Double, Double) -> Boolean): Pair<FloatArray, FloatArray> {
        val d = a.irisSpan * f.toFloat()
        val margin = ceil(BACKGROUND_FILL_SIGMAS.last() * d * 2).toInt()
        val ex0 = max(0, x0 - margin); val ey0 = max(0, y0 - margin)
        val ex1 = min(frame.width, x0 + pw + margin); val ey1 = min(frame.height, y0 + ph + margin)
        val ew = ex1 - ex0; val eh = ey1 - ey0
        val px = frame.region(ex0, ey0, ew, eh).pixels
        // The far side of a turned face (its eye at most TURNED_EYE_RATIO of the other's width).
        val leftEye = kotlin.math.hypot(lm(a, 33)[0] - lm(a, 133)[0], lm(a, 33)[1] - lm(a, 133)[1])
        val rightEye = kotlin.math.hypot(lm(a, 362)[0] - lm(a, 263)[0], lm(a, 362)[1] - lm(a, 263)[1])
        val farSign = if (rightEye < TURNED_EYE_RATIO * leftEye) 1f else if (leftEye < TURNED_EYE_RATIO * rightEye) -1f else 0f
        val ux0 = lm(a, 263)[0] - lm(a, 33)[0]; val uy0 = lm(a, 263)[1] - lm(a, 33)[1]; val ul = kotlin.math.hypot(ux0, uy0)
        val cx = (lm(a, 468)[0] + lm(a, 473)[0]) / 2; val cy = (lm(a, 468)[1] + lm(a, 473)[1]) / 2
        val hull = faceHull(a)
        // Background probability (real, and counting the far side's glasses) at a source pixel.
        fun bgAt(x: Int, y: Int): Pair<Float, Float> {
            val ax = ((x + 0.5) / f).toFloat(); val ay = ((y + 0.5) / f).toFloat()
            val b = a.background.sample(ax, ay) ?: 0f
            val far = farSign != 0f && ((ax - cx) * ux0 + (ay - cy) * uy0) / ul * farSign > 0 && !inside(hull, ax, ay)
            return b to (if (far) min(1f, b + (a.accessory.sample(ax, ay) ?: 0f)) else b)
        }
        val rgb = FloatArray(pw * ph * 3); val weight = FloatArray(pw * ph)
        // Which patch pixels may take the fill, at full resolution (one map sample each).
        val pendingJ = ArrayList<Int>(); val pendingT = ArrayList<Float>()
        for (j in 0 until pw * ph) {
            val x = x0 + j % pw; val y = y0 + j / pw
            if (!masked(x + 0.5, y + 0.5)) continue
            val t = bgAt(x, y).second
            if (t > 0.3f) { pendingJ.add(j); pendingT.add(t) }
        }
        if (pendingJ.isEmpty()) return rgb to weight
        // The normalized convolution on a grid of q × q source-pixel cells, ~BACKGROUND_FILL_CELLS_PER_IRIS_SPAN cells per d
        // (iOS backgroundFill): at full resolution its widest blur took most of a minute on the moto edge 60 (2026-10-15).
        val q = max(1, (d / BACKGROUND_FILL_CELLS_PER_IRIS_SPAN).toInt())
        val cw = (ew + q - 1) / q; val chh = (eh + q - 1) / q
        val weighted = Array(3) { FloatPlane(cw, chh) }; val weights = FloatPlane(cw, chh)
        for (y in 0 until eh) for (x in 0 until ew) {
            if (bgAt(ex0 + x, ey0 + y).first <= 0.5f || masked(ex0 + x + 0.5, ey0 + y + 0.5)) continue
            val i = y * ew + x; val c = (y / q) * cw + x / q
            weights.values[c] += 1f
            for (k in 0 until 3) weighted[k].values[c] += (px[i * 4 + k].toInt() and 0xff) / 255f
        }
        fun cell(plane: FloatPlane, gx: Float, gy: Float): Float {
            val fx = (gx - 0.5f).coerceIn(0f, (cw - 1).toFloat()); val fy = (gy - 0.5f).coerceIn(0f, (chh - 1).toFloat())
            val ix = fx.toInt(); val iy = fy.toInt(); val jx = min(ix + 1, cw - 1); val jy = min(iy + 1, chh - 1)
            val tx = fx - ix; val ty = fy - iy
            return (plane[ix, iy] * (1 - tx) + plane[jx, iy] * tx) * (1 - ty) + (plane[ix, jy] * (1 - tx) + plane[jx, jy] * tx) * ty
        }
        var open = pendingJ.indices.toList()
        for (sigma in BACKGROUND_FILL_SIGMAS) {
            if (open.isEmpty()) break
            val s = max(0.5, (sigma * d / q).toDouble())
            val num = Array(3) { PlaneOps.gaussianBlur(weighted[it], s) }; val den = PlaneOps.gaussianBlur(weights, s)
            open = open.filter { k ->
                val j = pendingJ[k]
                val gx = (x0 - ex0 + j % pw + 0.5f) / q; val gy = (y0 - ey0 + j / pw + 0.5f) / q
                val n = cell(den, gx, gy)
                if (n <= 0.05f * q * q) return@filter true   // cells hold pixel counts
                for (c in 0 until 3) rgb[j * 3 + c] = cell(num[c], gx, gy) / n
                weight[j] = ((pendingT[k] - 0.3f) / 0.4f).coerceIn(0f, 1f)
                false
            }
        }
        return rgb to weight
    }

    /** The face mesh's convex hull (analysis pixels). */
    private fun faceHull(a: FaceSunglassesAnalysis): List<FloatArray> {
        val pts = (0 until 468).map { lm(a, it) }.sortedWith(compareBy({ it[0] }, { it[1] }))
        fun cross(o: FloatArray, p: FloatArray, q: FloatArray) = (p[0] - o[0]) * (q[1] - o[1]) - (p[1] - o[1]) * (q[0] - o[0])
        val lower = ArrayList<FloatArray>(); val upper = ArrayList<FloatArray>()
        for (p in pts) { while (lower.size >= 2 && cross(lower[lower.size - 2], lower.last(), p) <= 0) lower.removeAt(lower.size - 1); lower.add(p) }
        for (p in pts.asReversed()) { while (upper.size >= 2 && cross(upper[upper.size - 2], upper.last(), p) <= 0) upper.removeAt(upper.size - 1); upper.add(p) }
        return lower.dropLast(1) + upper.dropLast(1)
    }

    private fun inside(hull: List<FloatArray>, x: Float, y: Float): Boolean {
        if (hull.size < 3) return false
        for (i in hull.indices) {
            val p = hull[i]; val q = hull[(i + 1) % hull.size]
            if ((q[0] - p[0]) * (y - p[1]) - (q[1] - p[1]) * (x - p[0]) < 0) return false
        }
        return true
    }

    /** Bilinear RGB (0…1) of a square RGBA8 window at pixel coordinates (centres at integers), edge-clamped. */
    private inline fun bilinear(px: ByteArray, side: Int, x: Double, y: Double, out: (Int, Float) -> Unit) {
        val cx = x.coerceIn(0.0, side - 1.0); val cy = y.coerceIn(0.0, side - 1.0)
        val x0 = cx.toInt(); val y0 = cy.toInt(); val x1 = min(x0 + 1, side - 1); val y1 = min(y0 + 1, side - 1)
        val fx = cx - x0; val fy = cy - y0
        for (c in 0 until 3) {
            val a = (px[(y0 * side + x0) * 4 + c].toInt() and 0xff) / 255.0; val b = (px[(y0 * side + x1) * 4 + c].toInt() and 0xff) / 255.0
            val d = (px[(y1 * side + x0) * 4 + c].toInt() and 0xff) / 255.0; val e = (px[(y1 * side + x1) * 4 + c].toInt() and 0xff) / 255.0
            out(c, ((a * (1 - fx) + b * fx) * (1 - fy) + (d * (1 - fx) + e * fx) * fy).toFloat())
        }
    }

    private fun bilinearPlane(plane: FloatArray, offset: Int, n: Int, x: Double, y: Double): Double {
        val x0 = x.toInt(); val y0 = y.toInt(); val x1 = min(x0 + 1, n - 1); val y1 = min(y0 + 1, n - 1)
        val fx = x - x0; val fy = y - y0
        fun at(xx: Int, yy: Int) = plane[offset + yy * n + xx].toDouble()
        return (at(x0, y0) * (1 - fx) + at(x1, y0) * fx) * (1 - fy) + (at(x0, y1) * (1 - fx) + at(x1, y1) * fx) * fy
    }
}
