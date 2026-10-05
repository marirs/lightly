package com.lightlylabs.lightly.background

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/** What the Background tool needs from the photo, computed once per photo at the working resolution. */
class BackgroundAnalysis(
    val width: Int,
    val height: Int,
    /** Null when no depth is available (no embedded map, no estimator in this build). */
    val depth: NormalisedDepth?,
    /** Null when no subject matte is available (segmentation pending, or no clear subject). */
    val matte: FloatPlane?,
)

/** A Refine edges stroke (recipe `subject.refinements`): add to or erase from the matte, radius as a fraction of the long edge. */
class MatteStroke(val add: Boolean, val radius: Double, val points: List<Pair<Double, Double>>)

object MatteRefinement {
    /**
     * Applies strokes in order: every pixel within the stroke's radius of its polyline becomes subject
     * (add) or background (erase), with a 1 px soft edge. Points are normalised frame coordinates.
     */
    fun apply(matte: FloatPlane, strokes: List<MatteStroke>): FloatPlane {
        if (strokes.isEmpty()) return matte
        val out = matte.copy()
        val longSide = maxOf(matte.width, matte.height)
        for (stroke in strokes) {
            val r = stroke.radius * longSide
            val pts = stroke.points.map { (x, y) -> x * (matte.width - 1) to y * (matte.height - 1) }
            for (y in 0 until matte.height) for (x in 0 until matte.width) {
                var best = Double.MAX_VALUE
                for (i in pts.indices) {
                    val (ax, ay) = pts[i]
                    val (bx, by) = if (i + 1 < pts.size) pts[i + 1] else pts[i]
                    val dx = bx - ax
                    val dy = by - ay
                    val len2 = dx * dx + dy * dy
                    val t = if (len2 == 0.0) 0.0 else (((x - ax) * dx + (y - ay) * dy) / len2).coerceIn(0.0, 1.0)
                    val px = ax + t * dx - x
                    val py = ay + t * dy - y
                    best = minOf(best, px * px + py * py)
                }
                val coverage = (r + 0.5 - kotlin.math.sqrt(best)).coerceIn(0.0, 1.0).toFloat()
                if (coverage <= 0f) continue
                val target = if (stroke.add) 1f else 0f
                out[x, y] = out[x, y] * (1 - coverage) + target * coverage
            }
        }
        return out
    }
}

/** One render of stages background.replace + background.focus, resolved from the recipe. */
class BackgroundPlan(
    /** sRGB replacement at the working size, already graded with the photo's global colour; null = none. */
    val replacement: FloatImage?,
    val focus: FocusParams,
    /** Focal nearness (1 = near): resolved from the stored focusDepth, else from the target / subject. */
    val focalNearness: Double,
    /**
     * The recipe's focus target, null when the recipe has none. Decides revision 1's subject-in-focus rule:
     * a null target with a subject, or a target on the matte (M ≥ 0.5), keeps the subject plane sharp.
     */
    val focusTarget: Pair<Double, Double>? = null,
    /** The replacement at the analysis size (graded), sampled for the full-resolution composite; null = none. */
    val replacementFull: ReplacementPixels? = null,
) {
    val isIdentity: Boolean get() = replacement == null && focus.blur <= 0.0
}

/**
 * A replacement background that can be sampled at any frame position: sRGB RGBA8 pixels drawn for the
 * whole frame at some resolution (the frame's own, or a capped one), sampled bilinearly.
 */
class ReplacementPixels(val width: Int, val height: Int, val rgba: ByteArray) {
    init { require(rgba.size == width * height * 4) }

    /** Linear RGB at normalised frame position (u, v) into [out]. */
    fun sampleLinear(u: Double, v: Double, out: FloatArray) {
        val x = (u * width - 0.5).coerceIn(0.0, (width - 1).toDouble())
        val y = (v * height - 0.5).coerceIn(0.0, (height - 1).toDouble())
        val x0 = x.toInt()
        val y0 = y.toInt()
        val x1 = minOf(x0 + 1, width - 1)
        val y1 = minOf(y0 + 1, height - 1)
        val fx = (x - x0).toFloat()
        val fy = (y - y0).toFloat()
        for (c in 0 until 3) {
            fun at(xx: Int, yy: Int) = Refocus.srgbToLinear((rgba[(yy * width + xx) * 4 + c].toInt() and 0xff) / 255f)
            out[c] = (at(x0, y0) * (1 - fx) + at(x1, y0) * fx) * (1 - fy) + (at(x0, y1) * (1 - fx) + at(x1, y1) * fx) * fy
        }
    }
}

/**
 * Focus & Blur and the replacement resolved at the working resolution, ready to be applied to the frame at
 * any larger size by [BackgroundStage.applyRegion] (iOS `LayeredStages.render`): the refocused result
 * ([blurred], null without blur), the sharp composite it was made from ([sharp]) and the defocus weight
 * (1 where the blur clearly departs from the sharp composite), all linear, plus the refined matte.
 */
class WorkingBackground(
    val width: Int,
    val height: Int,
    val matte: FloatPlane?,
    /** Linear RGB, interleaved. */
    val blurred: FloatImage?,
    val sharp: FloatImage?,
    val weight: FloatPlane?,
    /**
     * With a replacement: the estimated foreground colour minus the observed colour (linear RGB, F − I at the
     * working size; rendering-v2 revision 5). A frame pixel's subject colour is I + this (clamped), so the old
     * background's colour leaves soft matte edges (hair) while the frame keeps its own detail; otherwise null.
     */
    val foregroundShift: FloatImage? = null,
) {
    /** Bilinear sample of channel [c] of an interleaved RGB image at working-pixel coordinates, edges clamped. */
    fun sample(image: FloatImage, x: Double, y: Double, c: Int): Float {
        val sx = x.coerceIn(0.0, (width - 1).toDouble())
        val sy = y.coerceIn(0.0, (height - 1).toDouble())
        val x0 = sx.toInt()
        val y0 = sy.toInt()
        val x1 = minOf(x0 + 1, width - 1)
        val y1 = minOf(y0 + 1, height - 1)
        val fx = (sx - x0).toFloat()
        val fy = (sy - y0).toFloat()
        val d = image.data
        val top = d[(y0 * width + x0) * 3 + c] * (1 - fx) + d[(y0 * width + x1) * 3 + c] * fx
        val bottom = d[(y1 * width + x0) * 3 + c] * (1 - fx) + d[(y1 * width + x1) * 3 + c] * fx
        return top * (1 - fy) + bottom * fy
    }
}

/**
 * Applies a [BackgroundPlan] to the developed frame (RGBA8, sRGB) at the analysis's working resolution,
 * and to a full-resolution frame by [composeFullResolution].
 */
object BackgroundStage {
    /** iOS LayeredStages working caps (long edge): a slider moving, and the settled preview. */
    const val INTERACTIVE_CAP = 640
    const val PREVIEW_CAP = 1024

    /**
     * v3 differs: iOS renders Save copy's Focus & Blur at 2048 px. Android's 192 MB app heap cannot hold the
     * layered renderer's planes at that size next to the decoded full-resolution frame (a 12 MP frame is
     * 49 MB as RGBA8): at 1024 px it already exceeded a 150 MB budget (BackgroundMemoryTest). Save copy
     * renders at 768 px; full-resolution detail is kept wherever the result is sharp ([applyRegion]), and
     * defocused areas have no detail to lose.
     */
    const val EXPORT_CAP = 768

    /**
     * @return the rendered RGBA8 frame and the per-pixel "defocus" of what is visible (0 sharp … 1 at
     *   the maximum blur, 1 also wherever the replacement shows), used to rebuild full resolution.
     */
    fun render(developed: ByteArray, analysis: BackgroundAnalysis, plan: BackgroundPlan, layersPerSide: Int): Pair<ByteArray, FloatPlane> {
        val w = analysis.width
        val h = analysis.height
        require(developed.size == w * h * 4) { "frame is not ${w}x$h" }
        if (plan.isIdentity) return developed.copyOf() to FloatPlane(w, h)
        val photo = FloatImage(w, h, 3, FloatArray(w * h * 3) { Refocus.srgbToLinear((developed[(it / 3) * 4 + it % 3].toInt() and 0xff) / 255f) })
        val replacementLinear = plan.replacement?.let { r -> FloatImage(w, h, 3, FloatArray(w * h * 3) { Refocus.srgbToLinear(r.data[it]) }) }
        val matte = analysis.matte
        require(replacementLinear == null || matte != null) { "a replacement needs a subject matte" }
        // Without depth, only a sharp replacement composite (blur 0) is possible; blur needs depth (§R8).
        val nearness = analysis.depth?.nearness ?: run {
            require(plan.focus.blur <= 0.0) { "blur needs depth" }
            FloatPlane.filled(w, h, 0.5f)
        }
        val scene = Refocus.buildScene(photo, nearness, matte, replacementLinear)
        val subjectInFocus = scene.subject != null &&
            (plan.focusTarget?.let { (x, y) -> Refocus.focusIsOnSubject(scene, x, y) } ?: true)
        val rendered = Refocus.render(scene, plan.focus, plan.focalNearness, layersPerSide, subjectInFocus)
        val out = ByteArray(w * h * 4)
        for (p in 0 until w * h) {
            for (c in 0 until 3) out[p * 4 + c] = encode(Refocus.linearToSrgb(rendered.data[p * 3 + c]))
            out[p * 4 + 3] = developed[p * 4 + 3]
        }
        val radiusMax = Refocus.maxRadiusPx(plan.focus.blur, max(w, h), plan.focus.maxBlurFraction)
        val half = Refocus.halfWidth(plan.focus.depthOfField)
        val defocus = FloatPlane(w, h, FloatArray(w * h) { p ->
            val background = if (radiusMax > 0) (abs(Refocus.signedCoc(scene.background.nearness.values[p], plan.focalNearness, half, radiusMax)) / radiusMax).toFloat() else 0f
            val backgroundWeight = if (replacementLinear != null) 1f else background
            val subject = scene.subject
            if (subject == null) backgroundWeight else {
                val s = if (radiusMax > 0) (abs(Refocus.signedCoc(subject.nearness.values[p], plan.focalNearness, half, radiusMax)) / radiusMax).toFloat() else 0f
                backgroundWeight * (1 - subject.alpha.values[p]) + s * subject.alpha.values[p]
            }
        })
        return out to defocus
    }

    /**
     * The working-resolution part of iOS `LayeredStages.render`: [developed] (RGBA8 sRGB) and [analysis]
     * are already at the working size; [plan]'s replacement too. The layered renderer runs only here;
     * [applyRegion] then brings the result to the frame at any size.
     */
    fun renderWorking(developed: ByteArray, analysis: BackgroundAnalysis, plan: BackgroundPlan, layersPerSide: Int): WorkingBackground {
        val w = analysis.width
        val h = analysis.height
        require(developed.size == w * h * 4) { "frame is not ${w}x$h" }
        val matte = analysis.matte
        val blur = if (analysis.depth == null) 0.0 else plan.focus.blur
        val shift = if (plan.replacement != null && matte != null) foregroundShift(developed, w, h, matte) else null
        if (blur <= 0.0) return WorkingBackground(w, h, matte, null, null, null, shift)
        require(plan.replacement == null || matte != null) { "a replacement needs a subject matte" }
        // Memory: the linear photo and replacement exist only inside renderScene; the scene's colours are expanded in place.
        val blurred = renderScene(developed, w, h, analysis.depth!!.nearness, matte, plan, blur, layersPerSide)
        // The sharp composite at the working size (the subject over the replaced background), made after the
        // scene is gone, from the bytes and the plan's (unexpanded) replacement.
        val replacementSrgb = plan.replacement
        // Per-element loops below run rows in parallel (forEachRow); the arithmetic is unchanged.
        val sharp = FloatImage(w, h, 3, parallelFloatArray(w, h, 3) { i ->
            val p = i / 3
            val photo = Refocus.srgbToLinear((developed[p * 4 + i % 3].toInt() and 0xff) / 255f)
            if (replacementSrgb == null) photo else { val a = matte!!.values[p].coerceIn(0f, 1f); (photo + shift!!.data[i]).coerceIn(0f, 1f) * a + Refocus.srgbToLinear(replacementSrgb.data[i]) * (1 - a) }
        })
        // iOS: how far the blurred result departs from the sharp composite, relative to 0.02; softened.
        val weight = PlaneOps.gaussianBlur(FloatPlane(w, h, parallelFloatArray(w, h, 1) { p ->
            var d = 0f
            for (c in 0 until 3) d = max(d, abs(blurred.data[p * 3 + c] - sharp.data[p * 3 + c]))
            minOf(d / 0.02f, 1f)
        }), 1.5)
        return WorkingBackground(w, h, matte, blurred, sharp, weight, shift)
    }

    /**
     * F − I at the working size (rendering-v2 revision 5): F the estimated foreground colour
     * ([ForegroundEstimate], Germer multilevel), I the observed linear photo.
     */
    private fun foregroundShift(developed: ByteArray, w: Int, h: Int, matte: FloatPlane): FloatImage {
        // The estimate depends on the photo and the matte only, not on the replacement or the blur: a preview that
        // changes those reuses it (it is sequential by definition, ~1–3 s at 682 × 1024 on the emulator). One entry,
        // keyed by content, so memory stays bounded (w·h·3 floats).
        val key = ShiftKey(w, h, java.util.Arrays.hashCode(developed), java.util.Arrays.hashCode(matte.values))
        synchronized(this) { lastShift?.takeIf { it.first == key }?.let { return it.second } }
        val shift = computeForegroundShift(developed, w, h, matte)
        synchronized(this) { lastShift = key to shift; foregroundEstimates++ }
        return shift
    }

    private data class ShiftKey(val width: Int, val height: Int, val developed: Int, val matte: Int)
    private var lastShift: Pair<ShiftKey, FloatImage>? = null
    /** How many foreground estimates ran (tests). */
    @Volatile internal var foregroundEstimates = 0

    private fun computeForegroundShift(developed: ByteArray, w: Int, h: Int, matte: FloatPlane): FloatImage {
        val photo = FloatImage(w, h, 3, parallelFloatArray(w, h, 3) { SRGB_TO_LINEAR[developed[(it / 3) * 4 + it % 3].toInt() and 0xff] })
        val foreground = ForegroundEstimate.estimate(photo, FloatPlane(w, h, FloatArray(w * h) { matte.values[it].coerceIn(0f, 1f) }))
        return FloatImage(w, h, 3, parallelFloatArray(w, h, 3) { foreground.data[it] - photo.data[it] })
    }

    private fun renderScene(developed: ByteArray, w: Int, h: Int, nearness: FloatPlane, matte: FloatPlane?, plan: BackgroundPlan, blur: Double, layersPerSide: Int): FloatImage {
        val scene = Refocus.buildScene(
            FloatImage(w, h, 3, parallelFloatArray(w, h, 3) { Refocus.srgbToLinear((developed[(it / 3) * 4 + it % 3].toInt() and 0xff) / 255f) }), nearness, matte,
            plan.replacement?.let { r -> FloatImage(w, h, 3, parallelFloatArray(w, h, 3) { Refocus.srgbToLinear(r.data[it]) }) })
        val subjectInFocus = scene.subject != null && (plan.focusTarget?.let { (x, y) -> Refocus.focusIsOnSubject(scene, x, y) } ?: true)
        return Refocus.render(scene, plan.focus.copy(blur = blur), plan.focalNearness, layersPerSide, subjectInFocus, consumeScene = true)
    }

    /**
     * iOS `LayeredStages.render`, at the frame's resolution, for one region [x, y, width, height] of a
     * frameWidth × frameHeight frame whose developed pixels are [region]: the subject over the replacement
     * at full resolution (matte upsampled), then, with a blur, full detail plus the working-resolution change
     * where the result is sharp and the working-resolution blur where it is defocused.
     */
    fun applyRegion(region: ByteArray, x: Int, y: Int, width: Int, height: Int, frameWidth: Int, frameHeight: Int, working: WorkingBackground, replacement: ReplacementPixels?): ByteArray {
        val out = ByteArray(region.size)
        val sx = working.width.toDouble() / frameWidth
        val sy = working.height.toDouble() / frameHeight
        // Rows in parallel (0.6–0.7 s single-threaded for a 1065×1600 preview on the Pixel 9 Pro emulator);
        // every pixel's arithmetic is unchanged. 8-bit sRGB decodes through a table of the same function.
        java.util.stream.IntStream.range(0, height).parallel().forEach { row ->
            val repl = FloatArray(3)
            val fy = y + row
            val wy = (fy + 0.5) * sy - 0.5
            for (column in 0 until width) {
                val fx = x + column
                val wx = (fx + 0.5) * sx - 0.5
                val i = (row * width + column) * 4
                val a = if (replacement != null && working.matte != null) working.matte.sample(wx, wy).coerceIn(0f, 1f) else 1f
                if (replacement != null && a < 1f) replacement.sampleLinear((fx + 0.5) / frameWidth, (fy + 0.5) / frameHeight, repl)
                val w = working.weight?.sample(wx, wy) ?: 0f
                for (c in 0 until 3) {
                    val full = SRGB_TO_LINEAR[region[i + c].toInt() and 0xff]
                    var v = if (replacement != null && a < 1f) {
                        val subject = working.foregroundShift?.let { (full + working.sample(it, wx, wy, c)).coerceIn(0f, 1f) } ?: full
                        subject * a + repl[c] * (1 - a)
                    } else full
                    if (working.blurred != null) {
                        val b = working.sample(working.blurred, wx, wy, c)
                        val keep = v + (b - working.sample(working.sharp!!, wx, wy, c))
                        v = keep * (1 - w) + b * w
                    }
                    out[i + c] = encode(Refocus.linearToSrgb(v))
                }
                out[i + 3] = region[i + 3]
            }
        }
        return out
    }

    /** [Refocus.srgbToLinear] of each 8-bit value, exactly as computed per pixel before. */
    private val SRGB_TO_LINEAR = FloatArray(256) { Refocus.srgbToLinear(it / 255f) }

    /**
     * Full-resolution result from a working-resolution render: where the visible content is in focus
     * the full-resolution developed pixels are kept; where it is defocused (or replaced) the
     * working-resolution render is upsampled, blending by the defocus map. Blurred content has no
     * detail that the upsampling could lose; this is the approximation recorded in
     * docs/v1/slice3-android.md (Save copy renders Background at ≤ 2048 px, then this).
     */
    fun composeFullResolution(full: ByteArray, fullWidth: Int, fullHeight: Int, rendered: ByteArray, defocus: FloatPlane): ByteArray =
        composeTile(full, 0, 0, fullWidth, fullHeight, fullWidth, fullHeight, rendered, defocus)

    /**
     * [composeFullResolution] for one tile: [tile] holds the developed pixels of the rectangle
     * (tileX, tileY, tileWidth, tileHeight) of a fullWidth × fullHeight frame.
     */
    fun composeTile(tile: ByteArray, tileX: Int, tileY: Int, tileWidth: Int, tileHeight: Int, fullWidth: Int, fullHeight: Int, rendered: ByteArray, defocus: FloatPlane): ByteArray {
        val w = defocus.width
        val h = defocus.height
        val sx = w.toDouble() / fullWidth
        val sy = h.toDouble() / fullHeight
        val renderedPlanes = (0 until 3).map { c -> FloatPlane(w, h, FloatArray(w * h) { Refocus.srgbToLinear((rendered[it * 4 + c].toInt() and 0xff) / 255f) }) }
        val out = ByteArray(tile.size)
        for (row in 0 until tileHeight) {
            val srcY = (tileY + row + 0.5) * sy - 0.5
            for (column in 0 until tileWidth) {
                val srcX = (tileX + column + 0.5) * sx - 0.5
                // Soft step: below 5 % of the maximum blur the full-resolution pixel is kept, above 15 % the render.
                val weight = ((defocus.sample(srcX, srcY) - 0.05f) / 0.10f).coerceIn(0f, 1f)
                val i = (row * tileWidth + column) * 4
                for (c in 0 until 3) {
                    if (weight <= 0f) { out[i + c] = tile[i + c]; continue }
                    val sharp = Refocus.srgbToLinear((tile[i + c].toInt() and 0xff) / 255f)
                    val blurred = renderedPlanes[c].sample(srcX, srcY)
                    out[i + c] = encode(Refocus.linearToSrgb(sharp * (1 - weight) + blurred * weight))
                }
                out[i + 3] = tile[i + 3]
            }
        }
        return out
    }

    /** Working size for an analysis: the frame scaled so its long edge is at most [maxLongEdge]. */
    fun workingSize(width: Int, height: Int, maxLongEdge: Int): Pair<Int, Int> {
        val scale = minOf(1.0, maxLongEdge.toDouble() / max(width, height))
        return max(1, (width * scale).roundToInt()) to max(1, (height * scale).roundToInt())
    }

    private fun encode(v: Float): Byte = (v * 255f + 0.5f).toInt().coerceIn(0, 255).toByte()
}
