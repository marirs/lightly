package com.lightlylabs.lightly.vision.sunglasses

import com.lightlylabs.lightly.session.NormalisedRect
import com.lightlylabs.lightly.vision.RgbaImage
import com.lightlylabs.lightly.vision.TensorModel
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/** rendering-v2.json `portrait.sunglasses` constants (revision 9). Same values as iOS `SunglassesConstants`. */
object SunglassesConstants {
    const val INITIAL_CROP_SCALE = 1.6
    val ROLL_TRIES_DEGREES = doubleArrayOf(0.0, -45.0, -30.0, -15.0, 15.0, 30.0, 45.0)
    /** The same tries are also made around upright (0°) unless within this of one already made: the platform's eye
     *  points can be wrong on a tilted face (a group selfie, 2026-10-14), and the landmarker then returned a mirrored face. */
    const val ROLL_TRY_MIN_SEPARATION_DEGREES = 7.5
    /** The pair's front is never wider than this × the face's width at the cheek points 234/454 (owner report 2026-10-14). */
    const val WIDTH_FIT_CHEEK_FACTOR = 1.07
    /** A pair's front: its vertices within this of the lens plane. */
    const val FRONT_PLANE_METRES = 0.02
    /** Ear occluders (owner report 2026-10-14: on a turned face the arm lay over the ear): depth-only boxes hide the
     *  arms from this far behind the lens plane on, |x| between the inner and outer bounds (iOS SunglassesConstants). */
    const val EAR_CLIP_START_METRES = 0.12
    const val EAR_BOX_INNER_X = 0.04
    const val EAR_BOX_OUTER_X = 0.20
    /** The turn is raised in proportion as the far iris comes within this of the outline (iOS yawRampMetres). */
    const val YAW_RAMP_METRES = 0.025
    /** The eye band reaches this × d beyond the landmarks (was 0.15; a turned face's far rim sticks out past the nose). */
    const val EYE_BAND_PAD_X = 0.45f
    /** The eye band reaches this × d below the nose tip (was 0.1; a tilted face's far rim corner was missed). */
    const val EYE_BAND_BELOW_NOSE_TIP = 0.35f
    /** Only the nose of the face mesh occludes off profile (iOS noseTriangles), head frame from the irises (metres). */
    const val NOSE_HALF_WIDTH_METRES = 0.02
    const val NOSE_TOP_METRES = 0.0
    const val NOSE_BOTTOM_METRES = -0.06
    /** The head's continuation behind its centre: an elliptic cylinder of the head's x and y radii (iOS). */
    const val HEAD_BACK_LENGTH_METRES = 0.2
    /** On a turned face (|ex.z| above FAR_ARM_MIN_TURN) the far arm is hidden from this far behind the lens plane. */
    const val FAR_ARM_CLIP_START_METRES = 0.02
    const val FAR_ARM_MIN_TURN = 0.1
    const val REFINE_CROP_SCALE = 1.5
    const val REFINE_PASSES = 2
    const val KEEP_IF_LOGIT_DROP_AT_MOST = 1.0f
    const val MIN_FACE_LOGIT = 0f
    const val HAIR_OUTLINE_CROP_SCALE = 3.6
    const val ACCESSORY_CROP_SCALE = 1.4
    const val ACCESSORY_CROP_RAISE = 0.1
    const val ACCESSORY_THRESHOLD = 0.35f
    const val GLASSES_MIN_BOX_FRACTION = 0.005
    const val INTER_IRIS_REFERENCE_METRES = 0.093
    const val SIZE_PER_UNIT = 0.004
    const val PROFILE_MARGIN_METRES = 0.007
    const val PROFILE_TARGET_YAW_DEGREES = 85.0
    const val EYE_DEPTH_METRES = 0.015
    const val FACE_MESH_PUSH_BACK_METRES = 0.006
    const val SHADOW_SIGMA_OF_IRIS_SPAN = 0.035
    const val SHADOW_OFFSET_X_OF_IRIS_SPAN = 0.01
    const val SHADOW_OFFSET_Y_OF_IRIS_SPAN = 0.05
    const val SHADOW_STRENGTH = 0.28f
    const val PROFILE_OVERHANG_METRES = 0.004
}

/** A 256 × 256 class probability from one square crop of the photo (rendering-v2 §7.5 segmentation). */
class ProbabilityMap(val values: FloatArray, val originX: Float, val originY: Float, val cropSide: Float) {
    /** Bilinear sample at an analysis pixel position; null outside the crop. Same arithmetic as iOS. */
    fun sample(x: Float, y: Float): Float? {
        val u = (x - originX) / cropSide * SIDE - 0.5f
        val v = (y - originY) / cropSide * SIDE - 0.5f
        if (u < -0.5f || v < -0.5f || u > SIDE - 0.5f || v > SIDE - 0.5f) return null
        val x0 = floor(u).toInt().coerceIn(0, SIDE - 1); val y0 = floor(v).toInt().coerceIn(0, SIDE - 1)
        val x1 = min(x0 + 1, SIDE - 1); val y1 = min(y0 + 1, SIDE - 1)
        val fx = (u - x0).coerceIn(0f, 1f); val fy = (v - y0).coerceIn(0f, 1f)
        val a = values[y0 * SIDE + x0]; val b = values[y0 * SIDE + x1]
        val c = values[y1 * SIDE + x0]; val d = values[y1 * SIDE + x1]
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    companion object { const val SIDE = 256 }
}

/**
 * Everything Portrait › Sunglasses needs about one face (rendering-v2 §7.5 "Analysis"), in the pixel space of the image it
 * was computed on. Cached with the photo; never part of the recipe. A port of iOS `FaceSunglassesAnalysis`.
 */
class FaceSunglassesAnalysis(
    /** The recipe's face identity box (normalised). */
    val faceBox: NormalisedRect,
    val analysisWidth: Int, val analysisHeight: Int,
    /** 478 × (x, y, z): x, y in analysis pixels (origin top-left), z in the same units (negative = nearer). */
    val landmarks: FloatArray,
    val faceLogit: Float,
    val hair: ProbabilityMap, val background: ProbabilityMap, val accessory: ProbabilityMap,
) {
    val isReadable get() = faceLogit >= SunglassesConstants.MIN_FACE_LOGIT

    fun x(i: Int) = landmarks[i * 3]
    fun y(i: Int) = landmarks[i * 3 + 1]
    fun z(i: Int) = landmarks[i * 3 + 2]

    val irisSpan: Float get() = hypot(x(263) - x(33), y(263) - y(33))

    /** The face's own glasses: accessories over the threshold in the §7.5 eye band, or null when they cover ≤ 0.5 % of the box. */
    fun glassesMask(): GlassesMask? {
        val d = irisSpan
        var minX = Float.MAX_VALUE; var maxX = -Float.MAX_VALUE
        for (i in 0 until 468) { minX = min(minX, x(i)); maxX = max(maxX, x(i)) }
        val eyeTop = intArrayOf(33, 263, 468, 473).minOf { y(it) }
        val pad = SunglassesConstants.EYE_BAND_PAD_X
        val x0 = max(0, (minX - pad * d).toInt()); val y0 = max(0, (eyeTop - 0.55f * d).toInt())
        val x1 = min(analysisWidth, ceil(maxX + pad * d).toInt()); val y1 = min(analysisHeight, ceil(y(1) + SunglassesConstants.EYE_BAND_BELOW_NOSE_TIP * d).toInt())
        if (x1 <= x0 || y1 <= y0) return null
        val w = x1 - x0; val h = y1 - y0
        val mask = BooleanArray(w * h)
        var count = 0
        for (yy in y0 until y1) for (xx in x0 until x1) {
            if ((accessory.sample(xx + 0.5f, yy + 0.5f) ?: 0f) > SunglassesConstants.ACCESSORY_THRESHOLD) { mask[(yy - y0) * w + xx - x0] = true; count++ }
        }
        val boxArea = faceBox.width * analysisWidth * faceBox.height * analysisHeight
        return if (count > SunglassesConstants.GLASSES_MIN_BOX_FRACTION * boxArea) GlassesMask(x0, y0, w, h, mask) else null
    }

    class GlassesMask(val x0: Int, val y0: Int, val width: Int, val height: Int, val mask: BooleanArray)
}

/**
 * Runs the two Sunglasses models (rendering-v2 §7.5 "Analysis"): the MediaPipe face landmarker and selfie multiclass,
 * on LiteRT in :app behind [TensorModel]. Crops are sampled here exactly as iOS samples them, so both platforms feed the
 * models the same pixels.
 *
 * [landmarker] takes [1, 256, 256, 3] in 0…1 and returns [1434 landmarks, face-presence logit, …]; [segmenter] takes the
 * same input and returns 256 × 256 × 6 logits.
 */
class SunglassesAnalyzer(private val landmarker: TensorModel, private val segmenter: TensorModel) {

    /** Analysis for one face; [eyes] are the platform's two eye centres in pixels (image-left first). */
    fun analyse(image: RgbaImage, faceBox: NormalisedRect, eyes: Pair<FloatArray, FloatArray>): FaceSunglassesAnalysis {
        val w = image.width.toDouble(); val h = image.height.toDouble()
        val bx = faceBox.x * w; val by = faceBox.y * h; val bw = faceBox.width * w; val bh = faceBox.height * h
        val cx = bx + bw / 2; val cy = by + bh / 2
        val roll = atan2((eyes.second[1] - eyes.first[1]).toDouble(), (eyes.second[0] - eyes.first[0]).toDouble())
        var best: Pair<FloatArray, Float>? = null
        for (candidate in rollCandidates(roll)) {
            val attempt = landmarks(image, cx, cy, max(bw, bh) * SunglassesConstants.INITIAL_CROP_SCALE, candidate)
            if (best == null || attempt.second > best.second) best = attempt
        }
        var (points, logit) = best!!
        for (pass in 0 until SunglassesConstants.REFINE_PASSES) {
            val vx = points[152 * 3] - points[10 * 3]; val vy = points[152 * 3 + 1] - points[10 * 3 + 1]
            val upright = atan2(-vx.toDouble(), vy.toDouble())
            var lx = Float.MAX_VALUE; var ly = Float.MAX_VALUE; var hx = -Float.MAX_VALUE; var hy = -Float.MAX_VALUE
            for (i in 0 until 468) { lx = min(lx, points[i * 3]); hx = max(hx, points[i * 3]); ly = min(ly, points[i * 3 + 1]); hy = max(hy, points[i * 3 + 1]) }
            val next = landmarks(image, (lx + hx) / 2.0, (ly + hy) / 2.0, max(hx - lx, hy - ly) * SunglassesConstants.REFINE_CROP_SCALE, upright)
            if (next.second < logit - SunglassesConstants.KEEP_IF_LOGIT_DROP_AT_MOST) break
            points = next.first; logit = next.second
        }
        val wide = segment(image, cx, cy, max(bw, bh) * SunglassesConstants.HAIR_OUTLINE_CROP_SCALE)
        val tight = segment(image, cx, cy - bh * SunglassesConstants.ACCESSORY_CROP_RAISE, max(bw, bh) * SunglassesConstants.ACCESSORY_CROP_SCALE)
        return FaceSunglassesAnalysis(faceBox, image.width, image.height, points, logit, wide.map(1), wide.map(0), tight.map(5))
    }

    private fun landmarks(image: RgbaImage, cx: Double, cy: Double, side: Double, roll: Double): Pair<FloatArray, Float> {
        val n = ProbabilityMap.SIDE
        val k = side / n
        val ca = cos(roll); val sa = sin(roll)
        // Output (u, v) of the 256 crop → photo: x = a u + b v + c (the reference's PIL affine transform).
        val a = k * ca; val b = -k * sa; val c = cx - k * (ca * 128 - sa * 128)
        val d = k * sa; val e = k * ca; val f = cy - k * (sa * 128 + ca * 128)
        val input = FloatArray(n * n * 3)
        val rgb = FloatArray(3)
        for (v in 0 until n) for (u in 0 until n) {
            val uu = u + 0.5; val vv = v + 0.5
            sample(image, (a * uu + b * vv + c).toFloat(), (d * uu + e * vv + f).toFloat(), rgb)
            val i = (v * n + u) * 3
            input[i] = rgb[0]; input[i + 1] = rgb[1]; input[i + 2] = rgb[2]
        }
        val outputs = landmarker.run(input)
        val raw = outputs[0]
        require(raw.size == 1434) { "expected 478 × 3 landmark values, got ${raw.size}" }
        val points = FloatArray(1434)
        for (i in 0 until 478) {
            val u = raw[i * 3].toDouble(); val v = raw[i * 3 + 1].toDouble()
            points[i * 3] = (a * u + b * v + c).toFloat(); points[i * 3 + 1] = (d * u + e * v + f).toFloat()
            points[i * 3 + 2] = (raw[i * 3 + 2] * k).toFloat()
        }
        return points to outputs[1][0]
    }

    private class Classes(val probabilities: FloatArray, val originX: Float, val originY: Float, val side: Float) {
        fun map(index: Int): ProbabilityMap {
            val n = ProbabilityMap.SIDE
            return ProbabilityMap(FloatArray(n * n) { probabilities[it * 6 + index] }, originX, originY, side)
        }
    }

    /** Axis-aligned square crop resized to 256 with area averaging (as the reference's PIL resize when shrinking). */
    private fun segment(image: RgbaImage, cx: Double, cy: Double, side: Double): Classes {
        val n = ProbabilityMap.SIDE
        val x0 = (cx - side / 2).toInt().toFloat(); val y0 = (cy - side / 2).toInt().toFloat()
        val cropSide = (cx + side / 2).toInt() - x0
        val step = cropSide / n
        val taps = max(1, ceil(step).toInt())
        val input = FloatArray(n * n * 3)
        val rgb = FloatArray(3)
        for (v in 0 until n) for (u in 0 until n) {
            var r = 0f; var g = 0f; var bl = 0f
            for (ty in 0 until taps) for (tx in 0 until taps) {
                sample(image, x0 + (u + (tx + 0.5f) / taps) * step, y0 + (v + (ty + 0.5f) / taps) * step, rgb)
                r += rgb[0]; g += rgb[1]; bl += rgb[2]
            }
            val i = (v * n + u) * 3
            val inv = 1f / (taps * taps)
            input[i] = r * inv; input[i + 1] = g * inv; input[i + 2] = bl * inv
        }
        val logits = segmenter.run(input)[0]
        require(logits.size == n * n * 6) { "expected 256 × 256 × 6 logits, got ${logits.size}" }
        val probabilities = FloatArray(n * n * 6)
        for (i in 0 until n * n) {
            var m = Float.NEGATIVE_INFINITY
            for (c in 0 until 6) m = max(m, logits[i * 6 + c])
            var s = 0f
            for (c in 0 until 6) { val e = exp(logits[i * 6 + c] - m); probabilities[i * 6 + c] = e; s += e }
            for (c in 0 until 6) probabilities[i * 6 + c] /= s
        }
        return Classes(probabilities, x0, y0, cropSide)
    }

    companion object {
        /** The first crop's rolls (radians): the tries around the platform's eye line, then the same tries around
         *  upright that are not within ROLL_TRY_MIN_SEPARATION_DEGREES of one already listed (iOS rollCandidates). */
        fun rollCandidates(platformRoll: Double): List<Double> {
            val tries = SunglassesConstants.ROLL_TRIES_DEGREES.map { Math.toRadians(it) }
            val rolls = tries.map { platformRoll + it }.toMutableList()
            val separation = Math.toRadians(SunglassesConstants.ROLL_TRY_MIN_SEPARATION_DEGREES)
            for (roll in tries) if (rolls.none { kotlin.math.abs(Math.IEEEremainder(it - roll, 2 * Math.PI)) < separation }) rolls.add(roll)
            return rolls
        }

        /** Bilinear sRGB sample (0…1) at a pixel position; outside the image is black (as PIL's transform fills). */
        fun sample(image: RgbaImage, x: Float, y: Float, out: FloatArray) {
            val u = x - 0.5f; val v = y - 0.5f
            val x0 = floor(u).toInt(); val y0 = floor(v).toInt()
            val fx = u - x0; val fy = v - y0
            for (c in 0..2) out[c] = 0f
            for (dy in 0..1) for (dx in 0..1) {
                val px = x0 + dx; val py = y0 + dy
                if (px < 0 || py < 0 || px >= image.width || py >= image.height) continue
                val w = (if (dx == 0) 1 - fx else fx) * (if (dy == 0) 1 - fy else fy)
                for (c in 0..2) out[c] += image.channel(px, py, c) * w
            }
        }
    }
}
