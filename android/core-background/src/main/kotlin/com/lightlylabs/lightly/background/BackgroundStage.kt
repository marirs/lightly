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
) {
    val isIdentity: Boolean get() = replacement == null && focus.blur <= 0.0
}

/**
 * Applies a [BackgroundPlan] to the developed frame (RGBA8, sRGB) at the analysis's working resolution,
 * and to a full-resolution frame by [composeFullResolution].
 */
object BackgroundStage {
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
