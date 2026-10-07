package com.lightlylabs.lightly.background

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sign
import kotlin.math.sin

/** Interleaved float image with [channels] channels (3 = linear RGB, 4 = premultiplied RGBA). */
class FloatImage(val width: Int, val height: Int, val channels: Int, val data: FloatArray = FloatArray(width * height * channels)) {
    init { require(data.size == width * height * channels) }
    fun copy() = FloatImage(width, height, channels, data.copyOf())
}

/** Focus & Blur parameters as stored in the recipe (`tools.background.focus`). */
data class FocusParams(
    val blur: Double,
    /** The "Focus depth" slider = depth of field (owner decision, T3). */
    val depthOfField: Double,
    val style: String,
    val bokeh: String,
    val styleAmount: Double,
    /**
     * R_max at blur 100 as a fraction of the long edge. The contract's 0.06 by default; the app passes the
     * on-screen-matched value (PROVISIONAL: the prototype's blur/9 dp on the displayed photo, every device).
     */
    val maxBlurFraction: Double = Refocus.FocusConstants.MAX_BLUR_FRACTION_OF_LONG_EDGE,
)

/** One plane of the scene model (§R2): colour (linear, not premultiplied), coverage, nearness (1 = near). */
class ScenePlane(val colour: FloatImage, val alpha: FloatPlane, val nearness: FloatPlane)

class FocusScene(val background: ScenePlane, val subject: ScenePlane?) {
    val width: Int get() = background.alpha.width
    val height: Int get() = background.alpha.height
}

/**
 * Background › Focus & Blur: the layered, depth-linear circle-of-confusion renderer of
 * docs/v1/depth-evaluation.md §6, a CPU port of `experiments/depth/refocus.py`.
 *
 * Constants: where shared/contracts/rendering-v2 defines one it is used (max blur radius 0.03 of the
 * long edge; a sharp band of half-width depthOfField/100·0.5 around the focus). The depth evaluation's
 * §R4 proposes 0.035 and 0.30·(dof/100)^1.5 instead: that disagreement is reported as a contract gap
 * (docs/v1/slice3-android.md) and both constants live in [FocusConstants] only.
 *
 * Implementation latitude used (§R7): each layer is blurred at reduced resolution (r/2ⁿ ≥ 6 px), by
 * direct convolution with the anti-aliased kernel, then upsampled bilinearly.
 */
object Refocus {
    object FocusConstants {
        /**
         * rendering-v2.json revision 1 `constants.maxBlurRadius` (contract fixes 1): the radius at blur 100
         * for the depth farthest from the focal plane. Was 0.03, which barely blurred the background.
         */
        const val MAX_BLUR_FRACTION_OF_LONG_EDGE = 0.06

        /** rendering-v2.md §7: half-width of the sharp band = depthOfField/100·0.5. */
        const val DOF_HALF_WIDTH_SCALE = 0.5
        const val LAYERS_PER_SIDE_EXPORT = 8
        const val LAYERS_PER_SIDE_PREVIEW = 4
        const val SUBJECT_DEPTH_COMPRESSION = 0.5
        const val REPLACEMENT_MIN_GAP = 0.10
        const val HIGHLIGHT_THRESHOLD = 0.70
        const val HIGHLIGHT_GAIN = 0.85
    }

    fun halfWidth(depthOfField: Double) = (depthOfField.coerceIn(0.0, 100.0) / 100.0) * FocusConstants.DOF_HALF_WIDTH_SCALE

    fun maxRadiusPx(blur: Double, longEdge: Int, maxBlurFraction: Double = FocusConstants.MAX_BLUR_FRACTION_OF_LONG_EDGE) =
        blur.coerceIn(0.0, 100.0) / 100.0 * maxBlurFraction * longEdge

    // ------------------------------------------------------------------ colour (§R1)

    fun srgbToLinear(e: Float): Float = if (e <= 0.04045f) e / 12.92f else ((e + 0.055f) / 1.055f).toDouble().pow(2.4).toFloat()

    fun linearToSrgb(l: Float): Float {
        val c = l.coerceIn(0f, 1f)
        return if (c <= 0.0031308f) c * 12.92f else (1.055 * c.toDouble().pow(1 / 2.4) - 0.055).toFloat()
    }

    fun expandHighlights(rgb: FloatImage) {
        val t = FocusConstants.HIGHLIGHT_THRESHOLD
        val k = FocusConstants.HIGHLIGHT_GAIN
        for (p in 0 until rgb.width * rgb.height) {
            val i = p * rgb.channels
            val peak = max(rgb.data[i], max(rgb.data[i + 1], rgb.data[i + 2]))
            if (peak > t) {
                val u = ((peak - t) / (1 - t)).coerceIn(0.0, 1.0)
                val expanded = t + (1 - t) * u / (1 - k * u)
                val gain = (expanded / max(peak.toDouble(), 1e-6)).toFloat()
                for (c in 0 until 3) rgb.data[i + c] *= gain
            }
        }
    }

    fun compressHighlights(rgb: FloatImage) {
        val t = FocusConstants.HIGHLIGHT_THRESHOLD
        val k = FocusConstants.HIGHLIGHT_GAIN
        for (p in 0 until rgb.width * rgb.height) {
            val i = p * rgb.channels
            val peak = max(rgb.data[i], max(rgb.data[i + 1], rgb.data[i + 2]))
            if (peak > t) {
                val v = max(peak - t, 0.0) / (1 - t)
                val compressed = t + (1 - t) * v / (1 + k * v)
                val gain = (compressed / max(peak.toDouble(), 1e-6)).toFloat()
                for (c in 0 until 3) rgb.data[i + c] *= gain
            }
        }
    }

    // ------------------------------------------------------------------ scene (§R2)

    /**
     * The photo as one background plane (no subject matte: depth-only refocus), or background +
     * subject planes when a matte exists, optionally with the background replaced (§R2.4, "plane"
     * placement at the original background's median nearness, capped behind the subject).
     */
    fun buildScene(photoLinear: FloatImage, nearness: FloatPlane, matte: FloatPlane?, replacementLinear: FloatImage? = null): FocusScene {
        if (matte == null) {
            require(replacementLinear == null) { "a replacement needs a subject matte" }
            return FocusScene(ScenePlane(photoLinear, FloatPlane.filled(photoLinear.width, photoLinear.height, 1f), nearness), null)
        }
        return buildScene(photoLinear, sceneGeometry(nearness, matte, withReplacement = replacementLinear != null), replacementLinear)
    }

    /**
     * The part of [buildScene] that depends only on the depth and the matte, not on the photo's colours (completion plan
     * A1 step 3, 2026-10-07): a ruler drag changes only the Look, so its frames reuse one geometry
     * ([BackgroundStage.renderWorking]). [withReplacement]: the original background's nearness is not filled, because
     * the replacement plane takes its place (it was computed and discarded before).
     */
    class SceneGeometry internal constructor(
        val width: Int,
        val height: Int,
        /** The matte clamped to [0, 1]. */
        val alpha: FloatPlane,
        /** 1 outside the subject's colour band, 0 inside: the pixels the background colour is filled from. */
        val colourWeight: FloatPlane,
        /** 1 where the matte is above 0.95: the pixels the subject's interior colour is filled from. */
        val solidWeight: FloatPlane,
        val subjectNearness: FloatPlane,
        /** Null with a replacement. */
        val backgroundNearness: FloatPlane?,
        /** The replacement plane's nearness (§R2.4 "plane"); meaningful only with a replacement. */
        val replacementNearness: Float,
        val withReplacement: Boolean,
    )

    fun sceneGeometry(nearness: FloatPlane, matte: FloatPlane, withReplacement: Boolean): SceneGeometry {
        val w = matte.width
        val h = matte.height
        val longSide = max(w, h)
        val m = matte.map { it.coerceIn(0f, 1f) }
        val colourBand = PlaneOps.dilateDisc(m, 0.02f, (0.004 * longSide).roundToInt())
        val colourWeight = FloatPlane(w, h, FloatArray(w * h) { if (colourBand[it]) 0f else 1f })
        val depthBand = PlaneOps.dilateDisc(m, 0.02f, (0.015 * longSide).roundToInt())
        val backgroundNearness = if (withReplacement) null else fillMaskedPlane(nearness, FloatPlane(w, h, FloatArray(w * h) { if (depthBand[it]) 0f else 1f }))

        var interior = PlaneOps.erodeDisc(m, 0.5f, (0.01 * longSide).roundToInt())
        if (interior.count { it } < 50) interior = BooleanArray(w * h) { m.values[it] > 0.5f }
        val interiorWeight = FloatPlane(w, h, FloatArray(w * h) { if (interior[it]) 1f else 0f })
        val subjectRaw = fillMaskedPlane(nearness, interiorWeight)
        val subjectValues = nearness.values.selectWhere { interior[it] }
        val subjectMedian = if (subjectValues.isNotEmpty()) PlaneOps.median(subjectValues) else 0.5
        val subjectNearness = subjectRaw.map { (subjectMedian + FocusConstants.SUBJECT_DEPTH_COMPRESSION * (it - subjectMedian)).toFloat() }

        val solid = FloatPlane(w, h, FloatArray(w * h) { if (m.values[it] > 0.95f) 1f else 0f })
        val replacementNearness = if (!withReplacement) 0f else {
            val nearestAllowed = max(0.0, subjectMedian - FocusConstants.REPLACEMENT_MIN_GAP)
            val outside = nearness.values.selectWhere { !depthBand[it] }
            val originalMedian = if (outside.isNotEmpty()) PlaneOps.median(outside) else 0.0
            min(originalMedian, nearestAllowed).toFloat()
        }
        return SceneGeometry(w, h, m, colourWeight, solid, subjectNearness, backgroundNearness, replacementNearness, withReplacement)
    }

    /** [buildScene] from a [geometry] made for the same depth and matte (and the same use of a replacement). */
    fun buildScene(photoLinear: FloatImage, geometry: SceneGeometry, replacementLinear: FloatImage?): FocusScene {
        val w = photoLinear.width
        val h = photoLinear.height
        require(geometry.width == w && geometry.height == h) { "geometry is ${geometry.width}x${geometry.height}, photo ${w}x$h" }
        require(geometry.withReplacement == (replacementLinear != null)) { "geometry made for another replacement setting" }
        val m = geometry.alpha
        val backgroundColour = fillMasked(photoLinear, geometry.colourWeight)
        val interiorFill = fillMasked(photoLinear, geometry.solidWeight)
        val subjectColour = FloatImage(w, h, 3)
        for (p in 0 until w * h) {
            val alpha = m.values[p]
            // rendering-v2 revision 3: the solved colour wherever the matte is above 0.02 (was: interior fill
            // below 0.3, which painted the subject's colour into a soft matte tail: a glow at the shoulder).
            val reliability = if (alpha > 0.02f) 1f else 0f
            for (c in 0 until 3) {
                val i = p * 3 + c
                val solved = (photoLinear.data[i] - (1 - alpha) * backgroundColour.data[i]) / max(alpha, 1e-3f)
                subjectColour.data[i] = max(0f, reliability * solved.coerceIn(0f, 1f) + (1 - reliability) * interiorFill.data[i])
            }
        }
        val background = if (replacementLinear != null) {
            ScenePlane(replacementLinear, FloatPlane.filled(w, h, 1f), FloatPlane.filled(w, h, geometry.replacementNearness))
        } else {
            ScenePlane(backgroundColour, FloatPlane.filled(w, h, 1f), geometry.backgroundNearness!!)
        }
        return FocusScene(background, ScenePlane(subjectColour, m, geometry.subjectNearness))
    }

    /** §R3: median nearness of the topmost plane at the tap, over a window of half-size 0.01·longSide. */
    fun focalNearness(scene: FocusScene, targetX: Double, targetY: Double): Double {
        val w = scene.width
        val h = scene.height
        val cx = (targetX.coerceIn(0.0, 1.0) * (w - 1)).toInt()
        val cy = (targetY.coerceIn(0.0, 1.0) * (h - 1)).toInt()
        val onSubject = scene.subject != null && scene.subject.alpha[cx, cy] >= 0.5f
        val plane = if (onSubject) scene.subject!!.nearness else scene.background.nearness
        val radius = max(2, (0.01 * max(w, h)).roundToInt())
        val window = ArrayList<Float>()
        for (y in max(0, cy - radius)..min(h - 1, cy + radius)) for (x in max(0, cx - radius)..min(w - 1, cx + radius)) window += plane[x, y]
        return PlaneOps.median(window.toFloatArray())
    }

    /** Defocus range S = max(d_f, 1 − d_f): the disparity distance to the farther end of [0, 1] (revision 1). */
    fun defocusRange(focal: Double) = max(focal, 1 - focal)

    /** True when the tap lands on the subject plane (M(tap) ≥ 0.5), the topmost plane there (§R3). */
    fun focusIsOnSubject(scene: FocusScene, targetX: Double, targetY: Double): Boolean {
        val subject = scene.subject ?: return false
        val cx = (targetX.coerceIn(0.0, 1.0) * (scene.width - 1)).toInt()
        val cy = (targetY.coerceIn(0.0, 1.0) * (scene.height - 1)).toInt()
        return subject.alpha[cx, cy] >= 0.5f
    }

    /**
     * §R4 (revision 1): signed CoC in px, positive in front of the sharp band, negative behind it. The
     * distance beyond the band is scaled by S − h, so the farthest depth gets [radiusMax] whatever the
     * focal plane; one scale for both sides keeps the thin-lens ratio between depths.
     */
    fun signedCoc(nearness: Float, focal: Double, halfWidth: Double, radiusMax: Double): Double {
        val delta = nearness - focal
        val magnitude = max(abs(delta) - halfWidth, 0.0) / max(defocusRange(focal) - halfWidth, 1e-6)
        return sign(delta) * magnitude.coerceIn(0.0, 1.0) * radiusMax
    }

    // ------------------------------------------------------------------ render (§R4–R6)

    /**
     * The refocused frame, linear RGB. [layersPerSide] is 8 for export and may be 4 for previews (§R7).
     * [subjectInFocus]: revision 1's subject-in-focus rule — when the focus is on the subject (the tap on
     * the matte, or a null target with a subject), the subject plane's CoC is 0, also for Soft's glow.
     */
    fun render(
        scene: FocusScene,
        params: FocusParams,
        focal: Double,
        layersPerSide: Int = FocusConstants.LAYERS_PER_SIDE_EXPORT,
        subjectInFocus: Boolean = false,
        /** True when the caller discards [scene] afterwards: its colours are expanded in place, not copied. */
        consumeScene: Boolean = false,
        /**
         * Called before each layer (2026-10-06): a preview passes a check that throws when the render has been
         * superseded, so a long settled render stops for the frame of a moving control. Save copy passes nothing.
         */
        checkpoint: () -> Unit = {},
    ): FloatImage {
        val w = scene.width
        val h = scene.height
        val radiusMax = maxRadiusPx(params.blur, max(w, h), params.maxBlurFraction)
        val half = halfWidth(params.depthOfField)
        val highlights = params.style == "lens" || params.style == "swirl" || params.style == "motion"
        val planes = listOfNotNull(scene.background, scene.subject)
        val step = if (radiusMax > 0) radiusMax / layersPerSide else 1.0
        val colours = planes.map { plane ->
            when {
                !highlights -> plane.colour
                consumeScene -> plane.colour.also { expandHighlights(it) }
                else -> plane.colour.copy().also { expandHighlights(it) }
            }
        }
        val cocMaps = planes.mapIndexed { planeIndex, plane ->
            if (planeIndex == 1 && subjectInFocus && scene.subject != null) FloatPlane(w, h)
            else FloatPlane(w, h, FloatArray(w * h) { signedCoc(plane.nearness.values[it], focal, half, radiusMax).toFloat() })
        }
        // Memory (Android heap): every layer is blurred and used at once, never kept. Behind layers are
        // composited as they are made, in the contract's order (far to near, background before subject
        // within a layer), so the arithmetic is unchanged; a plane's in-front layers are summed in a
        // buffer that lives only while that plane is composited. Before, all 2·K behind layers per plane
        // were held at the working size (64 floats per pixel at K = 8), which exhausted a 192 MB heap.
        // §R6.1–2: far to near "over", background before subject within a layer, then pull-push normalise.
        val behindColour = FloatImage(w, h, 3)
        val behindAlpha = FloatPlane(w, h)
        // Memory (2026-10-06): one premultiplied layer and one blurred layer, reused for every layer of every plane.
        // A fresh 4-channel working-size image per layer (~11 MB at 683×1024, about 20 per preview) fragmented the
        // large-object heap until 11 MB allocations failed with ~22 MB free (13.5 MP stress, Pixel 9 Pro emulator).
        // Each layer is consumed before the next is made, so reuse changes no arithmetic.
        val scratch = LayerScratch(FloatImage(w, h, 4), FloatImage(w, h, 4))
        for (layer in -layersPerSide..-1) {
            for (planeIndex in planes.indices) {
                checkpoint()
                val blurred = layerBlurred(planes[planeIndex], colours[planeIndex], cocMaps[planeIndex], layer, step, params, radiusMax, scratch) ?: continue
                forEachRow(h) { y ->
                    for (p in y * w until (y + 1) * w) {
                        val a = blurred.data[p * 4 + 3]
                        for (c in 0 until 3) behindColour.data[p * 3 + c] = blurred.data[p * 4 + c] + (1 - a) * behindColour.data[p * 3 + c]
                        behindAlpha.values[p] = a + (1 - a) * behindAlpha.values[p]
                    }
                }
            }
        }
        val result = if (behindAlpha.values.any { it > 0f }) pullPushFill(behindColour, behindAlpha.map { it.coerceIn(0f, 1f) }) else FloatImage(w, h, 3)
        // §R6.3: focal + in-front layers of a plane are summed, then planes layered subject over background.
        for (planeIndex in planes.indices) {
            val front = FloatImage(w, h, 4)
            for (layer in 0..layersPerSide) {
                checkpoint()
                val blurred = layerBlurred(planes[planeIndex], colours[planeIndex], cocMaps[planeIndex], layer, step, params, radiusMax, scratch) ?: continue
                for (i in front.data.indices) front.data[i] += blurred.data[i]
            }
            forEachRow(h) { y ->
                for (p in y * w until (y + 1) * w) {
                    val coverage = front.data[p * 4 + 3]
                    val overflow = max(coverage, 1f)
                    val alpha = coverage / overflow
                    for (c in 0 until 3) result.data[p * 3 + c] = front.data[p * 4 + c] / overflow + (1 - alpha) * result.data[p * 3 + c]
                }
            }
        }
        if (highlights) compressHighlights(result)
        if (params.style == "soft") addGlow(result, cocMaps, scene, params, radiusMax)
        return result
    }

    /** Reused working-size buffers of one [render]: the premultiplied layer and its blurred result. */
    private class LayerScratch(val premultiplied: FloatImage, val blurred: FloatImage)

    /**
     * One tent layer of a plane (§R4), premultiplied and blurred; null when the layer is empty. The result lives in
     * [scratch] and is valid until the next call.
     */
    private fun layerBlurred(plane: ScenePlane, colour: FloatImage, coc: FloatPlane, layer: Int, step: Double, params: FocusParams, radiusMax: Double, scratch: LayerScratch): FloatImage? {
        val w = colour.width
        val h = colour.height
        val premultiplied = scratch.premultiplied
        java.util.Arrays.fill(premultiplied.data, 0f)
        // Rows in parallel (preview speed: this loop alone was ~0.55 s of a 2.7 s settled preview at
        // 682×1024 on the Pixel 9 Pro emulator); each pixel's arithmetic is unchanged.
        val any = java.util.concurrent.atomic.AtomicBoolean(false)
        forEachRow(h) { y ->
            var rowAny = false
            for (p in y * w until (y + 1) * w) {
                val position = coc.values[p] / step
                val weight = (max(0.0, 1 - abs(position - layer)) * plane.alpha.values[p]).toFloat()
                if (weight < 1e-6f) continue
                rowAny = rowAny || weight > 1e-4f
                premultiplied.data[p * 4] = colour.data[p * 3] * weight
                premultiplied.data[p * 4 + 1] = colour.data[p * 3 + 1] * weight
                premultiplied.data[p * 4 + 2] = colour.data[p * 3 + 2] * weight
                premultiplied.data[p * 4 + 3] = weight
            }
            if (rowAny) any.set(true)
        }
        if (!any.get()) return null
        return blurLayer(premultiplied, abs(layer) * step, params, radiusMax, scratch.blurred)
    }

    /** [into]: where a full-size result is written (must not be [layer]); smaller intermediates are allocated. */
    private fun blurLayer(layer: FloatImage, radius: Double, params: FocusParams, radiusMax: Double, into: FloatImage? = null): FloatImage {
        if (radius < 0.5) return layer
        // §R7: blur at 1/2ⁿ resolution with n the largest integer such that r/2ⁿ ≥ 6 px.
        val n = if (radius >= 12) floor(ln(radius / 6) / ln(2.0)).toInt() else 0
        val factor = 1 shl n
        val small = if (factor > 1) downsample(layer, factor) else layer
        val r = radius / factor
        // At full size (factor 1) the convolution writes straight into [into]; at 1/2ⁿ the upsample does.
        val direct = if (factor == 1) into else null
        val blurred = when (params.style) {
            "lens" -> convolve(small, Kernels.bokeh(params.bokeh, r), direct)
            "soft" -> convolve(small, Kernels.gaussian(r), direct)
            "motion" -> convolve(small, Kernels.motion(r, params.styleAmount * 3.6 - 180), direct)
            "swirl" -> {
                val amount = params.styleAmount / 100.0
                val disc = convolve(small, Kernels.bokeh("round", r * (1 - 0.5 * amount)))
                val halfAngle = 1.5 * r * amount / (0.5 * hypot(small.width.toDouble(), small.height.toDouble())) * 4
                rotationalBlur(disc, halfAngle)
            }
            else -> throw IllegalArgumentException("unknown focus style ${params.style}")
        }
        return if (factor > 1) upsample(blurred, layer.width, layer.height, into) else blurred
    }

    /** "same" 2-D convolution with reflected borders. */
    /** [into]: an image of the same size and channels to write the result to (every pixel is written). */
    fun convolve(image: FloatImage, kernel: Kernels.Kernel, into: FloatImage? = null): FloatImage {
        if (kernel.size == 1) return image
        val w = image.width
        val h = image.height
        val ch = image.channels
        val half = kernel.size / 2
        val out = into?.takeIf { it !== image && it.width == w && it.height == h && it.channels == ch } ?: FloatImage(w, h, ch)
        // Only non-zero taps are visited (bokeh shapes are sparse squares).
        val taps = ArrayList<IntArray>()
        val weights = ArrayList<Float>()
        for (ky in 0 until kernel.size) for (kx in 0 until kernel.size) {
            val v = kernel.values[ky * kernel.size + kx]
            if (v > 0f) { taps += intArrayOf(kx - half, ky - half); weights += v }
        }
        val tapX = IntArray(taps.size) { taps[it][0] }
        val tapY = IntArray(taps.size) { taps[it][1] }
        val tapW = FloatArray(taps.size) { weights[it] }
        // Same taps, same order, same arithmetic per pixel as before, so the output is identical; two
        // speed-ups only (measured: this loop was ~4.4 s of a 5–6 s settled Background preview at 682×1024
        // on the Pixel 9 Pro emulator): rows run in parallel, and pixels whose whole kernel lies inside
        // the image skip the per-tap border reflection.
        val data = image.data
        val dst = out.data
        // Border pixels (2026-10-06, speed): the reflected column and row of every offset the taps reach, looked up
        // instead of computed per tap (PlaneOps.reflect's indices exactly; at a drag frame's 213×320 most pixels lie
        // within a kernel radius of the border).
        val reflectX = IntArray(w + 2 * half) { PlaneOps.reflect(it - half, w) }
        val reflectY = IntArray(h + 2 * half) { PlaneOps.reflect(it - half, h) }
        // Speed (2026-10-07, drag frames): interior taps as one precomputed element offset each, and 3- and 4-channel
        // images accumulated in local floats instead of a per-pixel array. Each channel still sums the same products
        // in the same tap order from 0f, so every output float is unchanged (BackgroundExactnessTest).
        val tapOffset = IntArray(tapX.size) { (-tapY[it] * w - tapX[it]) * ch }
        java.util.stream.IntStream.range(0, h).parallel().forEach { y ->
            when (ch) {
                4 -> convolveRow4(data, dst, w, y, half, h, tapX, tapY, tapW, tapOffset, reflectX, reflectY)
                3 -> convolveRow3(data, dst, w, y, half, h, tapX, tapY, tapW, tapOffset, reflectX, reflectY)
                else -> convolveRowAny(data, dst, w, ch, y, half, h, tapX, tapY, tapW, reflectX, reflectY)
            }
        }
        return out
    }

    /** The element index of tap [t] for the pixel (x, y): direct inside the image, reflected near its border. */
    @Suppress("NOTHING_TO_INLINE")
    private inline fun tapBase(inside: Boolean, centre: Int, t: Int, x: Int, y: Int, w: Int, ch: Int, half: Int, tapX: IntArray, tapY: IntArray, tapOffset: IntArray, reflectX: IntArray, reflectY: IntArray): Int =
        // Kernel is applied as correlation of the flipped kernel = convolution.
        if (inside) centre + tapOffset[t] else (reflectY[y - tapY[t] + half] * w + reflectX[x - tapX[t] + half]) * ch

    private fun convolveRow4(data: FloatArray, dst: FloatArray, w: Int, y: Int, half: Int, h: Int, tapX: IntArray, tapY: IntArray, tapW: FloatArray, tapOffset: IntArray, reflectX: IntArray, reflectY: IntArray) {
        val rowInside = y - half >= 0 && y + half < h
        for (x in 0 until w) {
            val inside = rowInside && x - half >= 0 && x + half < w
            val centre = (y * w + x) * 4
            var a0 = 0f; var a1 = 0f; var a2 = 0f; var a3 = 0f
            for (t in tapW.indices) {
                val base = tapBase(inside, centre, t, x, y, w, 4, half, tapX, tapY, tapOffset, reflectX, reflectY)
                val wt = tapW[t]
                a0 += data[base] * wt; a1 += data[base + 1] * wt; a2 += data[base + 2] * wt; a3 += data[base + 3] * wt
            }
            dst[centre] = a0; dst[centre + 1] = a1; dst[centre + 2] = a2; dst[centre + 3] = a3
        }
    }

    private fun convolveRow3(data: FloatArray, dst: FloatArray, w: Int, y: Int, half: Int, h: Int, tapX: IntArray, tapY: IntArray, tapW: FloatArray, tapOffset: IntArray, reflectX: IntArray, reflectY: IntArray) {
        val rowInside = y - half >= 0 && y + half < h
        for (x in 0 until w) {
            val inside = rowInside && x - half >= 0 && x + half < w
            val centre = (y * w + x) * 3
            var a0 = 0f; var a1 = 0f; var a2 = 0f
            for (t in tapW.indices) {
                val base = tapBase(inside, centre, t, x, y, w, 3, half, tapX, tapY, tapOffset, reflectX, reflectY)
                val wt = tapW[t]
                a0 += data[base] * wt; a1 += data[base + 1] * wt; a2 += data[base + 2] * wt
            }
            dst[centre] = a0; dst[centre + 1] = a1; dst[centre + 2] = a2
        }
    }

    private fun convolveRowAny(data: FloatArray, dst: FloatArray, w: Int, ch: Int, y: Int, half: Int, h: Int, tapX: IntArray, tapY: IntArray, tapW: FloatArray, reflectX: IntArray, reflectY: IntArray) {
        val acc = FloatArray(ch)
        val rowInside = y - half >= 0 && y + half < h
        for (x in 0 until w) {
            java.util.Arrays.fill(acc, 0f)
            val inside = rowInside && x - half >= 0 && x + half < w
            for (t in tapW.indices) {
                val base = if (inside) ((y - tapY[t]) * w + (x - tapX[t])) * ch else (reflectY[y - tapY[t] + half] * w + reflectX[x - tapX[t] + half]) * ch
                val wt = tapW[t]
                for (c in 0 until ch) acc[c] += data[base + c] * wt
            }
            System.arraycopy(acc, 0, dst, (y * w + x) * ch, ch)
        }
    }

    private fun rotationalBlur(image: FloatImage, halfAngle: Double): FloatImage {
        val w = image.width
        val h = image.height
        val arcPx = halfAngle * hypot(w.toDouble(), h.toDouble()) / 2
        val samples = (ceil(arcPx / 1.5).toInt() * 2 + 1).coerceIn(3, 49)
        val cx = (w - 1) / 2.0
        val cy = (h - 1) / 2.0
        val out = FloatImage(w, h, image.channels)
        for (s in 0 until samples) {
            val angle = -halfAngle + 2 * halfAngle * s / (samples - 1)
            val cosA = cos(angle)
            val sinA = sin(angle)
            for (y in 0 until h) for (x in 0 until w) {
                val dx = x - cx
                val dy = y - cy
                val sx = cx + dx * cosA - dy * sinA
                val sy = cy + dx * sinA + dy * cosA
                bilinearAdd(image, sx, sy, out, (y * w + x) * image.channels, 1f / samples)
            }
        }
        return out
    }

    private fun bilinearAdd(image: FloatImage, x: Double, y: Double, out: FloatImage, offset: Int, scale: Float) {
        val w = image.width
        val h = image.height
        val x0f = floor(x)
        val y0f = floor(y)
        val fx = (x - x0f).toFloat()
        val fy = (y - y0f).toFloat()
        val x0 = PlaneOps.reflect(x0f.toInt(), w)
        val x1 = PlaneOps.reflect(x0f.toInt() + 1, w)
        val y0 = PlaneOps.reflect(y0f.toInt(), h)
        val y1 = PlaneOps.reflect(y0f.toInt() + 1, h)
        val ch = image.channels
        for (c in 0 until ch) {
            val v = (image.data[(y0 * w + x0) * ch + c] * (1 - fx) + image.data[(y0 * w + x1) * ch + c] * fx) * (1 - fy) +
                (image.data[(y1 * w + x0) * ch + c] * (1 - fx) + image.data[(y1 * w + x1) * ch + c] * fx) * fy
            out.data[offset + c] += v * scale
        }
    }

    fun downsample(image: FloatImage, factor: Int): FloatImage {
        val w = (image.width + factor - 1) / factor
        val h = (image.height + factor - 1) / factor
        val out = FloatImage(w, h, image.channels)
        forEachRow(h) { y -> for (x in 0 until w) {
            var n = 0
            for (yy in y * factor until min(image.height, (y + 1) * factor)) for (xx in x * factor until min(image.width, (x + 1) * factor)) {
                for (c in 0 until image.channels) out.data[(y * w + x) * image.channels + c] += image.data[(yy * image.width + xx) * image.channels + c]
                n++
            }
            for (c in 0 until image.channels) out.data[(y * w + x) * image.channels + c] /= n
        } }
        return out
    }

    /** [into]: an image of the target size and channels to write to (cleared first: the samples are added). */
    fun upsample(image: FloatImage, width: Int, height: Int, into: FloatImage? = null): FloatImage {
        val out = into?.takeIf { it !== image && it.width == width && it.height == height && it.channels == image.channels }
            ?.also { java.util.Arrays.fill(it.data, 0f) } ?: FloatImage(width, height, image.channels)
        val sx = image.width.toDouble() / width
        val sy = image.height.toDouble() / height
        forEachRow(height) { y -> for (x in 0 until width) {
            val srcX = ((x + 0.5) * sx - 0.5).coerceIn(0.0, (image.width - 1).toDouble())
            val srcY = ((y + 0.5) * sy - 0.5).coerceIn(0.0, (image.height - 1).toDouble())
            bilinearAdd(image, srcX, srcY, out, (y * width + x) * image.channels, 1f)
        } }
        return out
    }

    // ------------------------------------------------------------------ pull-push fill (§R6 contract algorithm)

    /**
     * Normalised fill of a partially covered image: [premultipliedColour] (C channels, colour × coverage)
     * and [coverage] in [0, 1]. Returns un-premultiplied colour defined everywhere.
     */
    fun pullPushFill(premultipliedColour: FloatImage, coverage: FloatPlane): FloatImage {
        // Revision 1 (contract fixes 1, G7): pulled all the way to 1 × 1 with an exact 2 × 2 box mean
        // (an odd last row or column repeated), so a hole is filled from covered pixels anywhere instead
        // of from an uncovered coarse cell at 0.
        val levels = ArrayList<Pair<FloatImage, FloatPlane>>()
        levels += premultipliedColour to coverage
        while (max(levels.last().second.width, levels.last().second.height) > 1) {
            val (colour, alpha) = levels.last()
            val downColour = halve(colour)
            val downAlpha = halve(FloatImage(alpha.width, alpha.height, 1, alpha.values)).let { FloatPlane(it.width, it.height, it.data) }
            val newAlpha = downAlpha.map { min(it * 4f, 1f) }
            forEachRow(newAlpha.height) { y ->
                for (p in y * newAlpha.width until (y + 1) * newAlpha.width) {
                    val gain = newAlpha.values[p] / max(downAlpha.values[p], 1e-6f)
                    for (c in 0 until downColour.channels) downColour.data[p * downColour.channels + c] *= gain
                }
            }
            levels += downColour to newAlpha
        }
        val (topColour, topAlpha) = levels.last()
        var filled = FloatImage(topColour.width, topColour.height, topColour.channels, FloatArray(topColour.data.size) { i ->
            topColour.data[i] / max(topAlpha.values[i / topColour.channels], 1e-6f)
        })
        for (index in levels.size - 2 downTo 0) {
            val (colour, alpha) = levels[index]
            // The upsampled level is combined in place (same values as a separate output buffer, one image less).
            val up = upsample(filled, alpha.width, alpha.height)
            forEachRow(alpha.height) { y ->
                for (p in y * alpha.width until (y + 1) * alpha.width) {
                    val a = alpha.values[p].coerceIn(0f, 1f)
                    for (c in 0 until colour.channels) up.data[p * colour.channels + c] = colour.data[p * colour.channels + c] + (1 - a) * up.data[p * colour.channels + c]
                }
            }
            filled = up
            // Finer levels no longer need the coarser ones.
            if (index + 1 < levels.size) levels[index + 1] = levels[index + 1].first.let { FloatImage(1, 1, it.channels) } to FloatPlane(1, 1)
        }
        return filled
    }

    /** Exact 2 × 2 box mean; an odd last row or column is repeated first (revision 1 pull-push step). */
    private fun halve(image: FloatImage): FloatImage {
        val w = (image.width + 1) / 2
        val h = (image.height + 1) / 2
        val out = FloatImage(w, h, image.channels)
        forEachRow(h) { y -> for (x in 0 until w) {
            val y0 = 2 * y
            val y1 = min(2 * y + 1, image.height - 1)
            val x0 = 2 * x
            val x1 = min(2 * x + 1, image.width - 1)
            for (c in 0 until image.channels) {
                fun at(xx: Int, yy: Int) = image.data[(yy * image.width + xx) * image.channels + c]
                out.data[(y * w + x) * image.channels + c] = 0.25f * (at(x0, y0) + at(x0, y1) + at(x1, y0) + at(x1, y1))
            }
        } }
        return out
    }

    /** `fill_masked`: low-weight pixels replaced by a smooth pull-push fill from valid ones. */
    fun fillMasked(values: FloatImage, weight: FloatPlane): FloatImage {
        val premultiplied = FloatImage(values.width, values.height, values.channels,
            parallelFloatArray(values.width, values.height, values.channels) { values.data[it] * weight.values[it / values.channels] })
        val filled = pullPushFill(premultiplied, weight)
        // Written into the fill's own buffer (same values; one image less at the peak).
        val rowLength = values.width * values.channels
        forEachRow(values.height) { y ->
            for (i in y * rowLength until (y + 1) * rowLength) {
                val wgt = weight.values[i / values.channels]
                filled.data[i] = values.data[i] * wgt + filled.data[i] * (1 - wgt)
            }
        }
        return filled
    }

    fun fillMaskedPlane(values: FloatPlane, weight: FloatPlane): FloatPlane {
        val filled = fillMasked(FloatImage(values.width, values.height, 1, values.values.copyOf()), weight)
        return FloatPlane(values.width, values.height, filled.data)
    }

    // ------------------------------------------------------------------ soft glow (§R5.2)

    private fun addGlow(result: FloatImage, cocMaps: List<FloatPlane>, scene: FocusScene, params: FocusParams, radiusMax: Double) {
        val amount = params.styleAmount / 100.0
        if (amount <= 0 || radiusMax <= 0) return
        val w = result.width
        val h = result.height
        val defocus = FloatPlane(w, h, FloatArray(w * h) { p ->
            val background = abs(cocMaps[0].values[p]) / radiusMax.toFloat()
            val subject = scene.subject
            if (subject == null) background else background * (1 - subject.alpha.values[p]) + abs(cocMaps[1].values[p]) / radiusMax.toFloat() * subject.alpha.values[p]
        })
        val sigma = max(1.0, 0.6 * radiusMax)
        val glowPlanes = (0 until 3).map { c ->
            PlaneOps.gaussianBlur(FloatPlane(w, h, FloatArray(w * h) { p ->
                val y = 0.2126f * result.data[p * 3] + 0.7152f * result.data[p * 3 + 1] + 0.0722f * result.data[p * 3 + 2]
                result.data[p * 3 + c] * ((y - 0.35f) / 0.65f).coerceIn(0f, 1f)
            }), sigma)
        }
        val defocusSoft = PlaneOps.gaussianBlur(defocus, max(1.0, 0.25 * radiusMax))
        for (p in 0 until w * h) for (c in 0 until 3) {
            val glow = (glowPlanes[c].values[p] * (0.9 * amount).toFloat() * defocusSoft.values[p]).coerceIn(0f, 1f)
            result.data[p * 3 + c] = 1 - (1 - result.data[p * 3 + c]) * (1 - glow)
        }
    }
}

/** Aperture kernels of §R5, normalised, anti-aliased with 4× supersampling (refocus.py `bokeh_kernel`…). */
object Kernels {
    class Kernel(val size: Int, val values: FloatArray)

    private fun grid(radius: Double, extent: Double, supersample: Int = 4, inside: (Double, Double) -> Boolean): Kernel {
        val size = ceil(radius * extent).toInt() * 2 + 1
        val n = size * supersample
        val values = FloatArray(size * size)
        for (iy in 0 until n) for (ix in 0 until n) {
            val sx = ((ix + 0.5) / supersample - size / 2.0) / radius
            val sy = -((iy + 0.5) / supersample - size / 2.0) / radius // y up
            if (inside(sx, sy)) values[(iy / supersample) * size + ix / supersample] += 1f
        }
        val sum = values.sum()
        for (i in values.indices) values[i] /= sum
        return Kernel(size, values)
    }

    fun bokeh(shape: String, radius: Double): Kernel {
        if (radius < 0.5) return Kernel(1, floatArrayOf(1f))
        return when (shape) {
            "round" -> grid(radius, 1.0) { x, y -> x * x + y * y <= 1 }
            "hex" -> {
                val vertices = (0 until 6).map { val a = Math.toRadians(it * 60.0); cos(a) to sin(a) }
                grid(radius, 1.0) { x, y -> vertices.indices.all { i -> val (x0, y0) = vertices[i]; val (x1, y1) = vertices[(i + 1) % 6]; (x1 - x0) * (y - y0) - (y1 - y0) * (x - x0) >= 0 } }
            }
            "heart" -> grid(radius, 1.0) { x, y ->
                val hx = x * 1.25
                val hy = y * 1.25 + 0.15
                val t = hx * hx + hy * hy - 1
                t * t * t - hx * hx * hy * hy * hy <= 0
            }
            "star" -> grid(radius, 1.0) { x, y -> starInside(x, y) }
            else -> throw IllegalArgumentException("unknown bokeh $shape")
        }
    }

    private fun starInside(x: Double, y: Double, points: Int = 5, inner: Double = 0.45): Boolean {
        val angle = atan2(y, x) - PI / 2
        val sector = 2 * PI / points
        val local = ((angle + sector / 2) % sector + sector) % sector - sector / 2
        val r = hypot(x, y)
        val px = r * cos(abs(local))
        val py = r * sin(abs(local))
        val vx = inner * cos(sector / 2)
        val vy = inner * sin(sector / 2)
        val cross = (vx - 1.0) * (py - 0.0) - (vy - 0.0) * (px - 1.0)
        return cross <= 0
    }

    fun gaussian(radius: Double): Kernel {
        if (radius < 0.5) return Kernel(1, floatArrayOf(1f))
        val half = ceil(radius * 1.5).toInt()
        val size = 2 * half + 1
        val g = DoubleArray(size) { val t = (it - half) / (radius / 2); kotlin.math.exp(-0.5 * t * t) }
        val values = FloatArray(size * size) { (g[it / size] * g[it % size]).toFloat() }
        val sum = values.sum()
        for (i in values.indices) values[i] /= sum
        return Kernel(size, values)
    }

    fun motion(radius: Double, directionDegrees: Double): Kernel {
        if (radius < 0.5) return Kernel(1, floatArrayOf(1f))
        val halfLength = 1.5 * radius
        val theta = Math.toRadians(directionDegrees)
        return grid(radius, 1.5) { x, y ->
            val px = x * radius
            val py = y * radius
            val along = px * cos(theta) + py * sin(theta)
            val across = -px * sin(theta) + py * cos(theta)
            abs(along) <= halfLength && abs(across) <= 0.5
        }
    }
}
