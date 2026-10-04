package com.lightlylabs.lightly.vision

import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.background.PlaneOps
import com.lightlylabs.lightly.develop.ColourMath
import com.lightlylabs.lightly.session.FaceEdit
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Stage `portrait` (rendering-v2 stage 9): per-face retouching inside landmark-derived regions. A port
 * of iOS `PortraitRenderer.swift` (same operators, constants and regions), on RGBA8 sRGB pixels.
 *
 * CONTRACT GAP (as iOS, docs/v1/slice3-ios.md): rendering-v2 gives this stage's parameters, ranges and
 * the rule "eye colour/shape and skin tone colour are never changed", but no equations. These are
 * the provisional operators, written to that rule: lightness and chroma in OKLab, chroma only ever
 * pulled toward its own local mean, nothing moves geometry.
 *
 * v3 differs: iOS takes the eye, brow and lip polygons from Vision's landmark regions; here they are
 * the Face Mesh V2 contours ([FaceMeshRegions]), which outline the same features.
 */
object PortraitRenderer {
    class Face(val detected: DetectedFace, val edit: FaceEdit)

    fun hasChanges(e: FaceEdit): Boolean =
        e.skin.smoothing > 0 || e.skin.blemishes > 0 || e.skin.evenTone > 0 || e.underEye.brighten > 0 || e.underEye.softenLines > 0 ||
            e.eyes.brighten > 0 || e.eyes.clarity > 0 || e.teeth.brighten > 0 || e.hair.definition > 0 || e.hair.flyaways > 0 || e.hair.shine > 0

    /**
     * Applies every face's edits to a copy of [image]. [personMatte] (optional, the image's size)
     * limits the hair operators to the person.
     */
    fun render(image: RgbaImage, faces: List<Face>, personMatte: FloatPlane?): RgbaImage {
        val active = faces.filter { hasChanges(it.edit) && it.detected.landmarks.isNotEmpty() }
        if (active.isEmpty()) return image
        val out = image.pixels.copyOf()
        for (face in active) apply(face, image.width, image.height, out, personMatte)
        return RgbaImage(image.width, image.height, out)
    }

    /** The photo region one face's operators read and write: the face box grown for hair and shoulders. */
    fun cropFor(face: DetectedFace, width: Int, height: Int): IntArray {
        val box = face.box
        val x0 = max(0, ((box.x - box.width * 0.9) * width).toInt())
        val x1 = min(width, ((box.x + box.width + box.width * 0.9) * width).toInt())
        val y0 = max(0, ((box.y - box.height * 0.9) * height).toInt())
        val y1 = min(height, ((box.y + box.height + box.height * 0.4) * height).toInt())
        return intArrayOf(x0, y0, x1, y1)
    }

    private fun apply(face: Face, width: Int, height: Int, pixels: ByteArray, personMatte: FloatPlane?) {
        val W = width.toFloat()
        val H = height.toFloat()
        val d = face.detected
        val box = d.box
        val (cx0, cy0, cx1, cy1) = cropFor(d, width, height).let { listOf(it[0], it[1], it[2], it[3]) }
        if (cx1 - cx0 <= 8 || cy1 - cy0 <= 8) return
        val cw = cx1 - cx0
        val ch = cy1 - cy0
        // OKLab planes of the crop.
        val L = FloatPlane(cw, ch)
        val A = FloatPlane(cw, ch)
        val B = FloatPlane(cw, ch)
        val lab = DoubleArray(3)
        for (y in 0 until ch) for (x in 0 until cw) {
            val o = ((y + cy0) * width + x + cx0) * 4
            ColourMath.linearToOklab(SRGB_TO_LINEAR[pixels[o].toInt() and 0xff], SRGB_TO_LINEAR[pixels[o + 1].toInt() and 0xff], SRGB_TO_LINEAR[pixels[o + 2].toInt() and 0xff], lab)
            val i = y * cw + x
            L.values[i] = lab[0].toFloat(); A.values[i] = lab[1].toFloat(); B.values[i] = lab[2].toFloat()
        }
        // Only pixels an operator changed are written back, so the round trip never alters the rest.
        val originalL = L.values.copyOf()
        val originalA = A.values.copyOf()
        val originalB = B.values.copyOf()
        fun local(p: Point) = Point(p.x * W - cx0, p.y * H - cy0)
        val faceWidthPx = (box.width * W).toFloat()
        val feather = max(1.5f, faceWidthPx * 0.02f)

        val faceEllipse = ellipseMask(cw, ch, local(Point(box.x + box.width / 2, box.y + box.height * 0.48)), faceWidthPx * 0.5f, (box.height * H * 0.6).toFloat(), feather * 2)
        val eyes = union(polygonMask(cw, ch, d.imageLeftEye.map(::local), faceWidthPx * 0.02f, feather), polygonMask(cw, ch, d.imageRightEye.map(::local), faceWidthPx * 0.02f, feather))
        val brows = union(polygonMask(cw, ch, d.imageLeftEyebrow.map(::local), faceWidthPx * 0.03f, feather), polygonMask(cw, ch, d.imageRightEyebrow.map(::local), faceWidthPx * 0.03f, feather))
        val lips = polygonMask(cw, ch, d.outerLips.map(::local), faceWidthPx * 0.02f, feather)
        // Skin is judged on broad chroma, so a red mark inside the skin is still skin (what Blemishes
        // must reach) while hair, eyes and background are not.
        val sigmaLow = max(4f, faceWidthPx * 0.12f)
        val aLow = blurLarge(A, sigmaLow)
        val bLow = blurLarge(B, sigmaLow)
        val skin = skinMask(faceEllipse, listOf(eyes, brows, lips), aLow, bLow)
        val e = face.edit

        if (e.skin.smoothing > 0 || e.skin.blemishes > 0 || e.skin.evenTone > 0) {
            val fineBlur = PlaneOps.gaussianBlur(L, max(0.6f, faceWidthPx * 0.004f).toDouble())
            val midBlur = blur(L, max(2f, faceWidthPx * 0.03f))
            val lowBlur = blurLarge(L, sigmaLow)
            val s = (e.skin.smoothing / 100).toFloat()
            val keep = (e.skin.keepTexture / 100).toFloat()
            val tone = (e.skin.evenTone / 100).toFloat()
            val blemish = (e.skin.blemishes / 100).toFloat()
            for (i in L.values.indices) {
                val m = skin.values[i]
                if (m <= 0.001f) continue
                val fine = L.values[i] - fineBlur.values[i]
                val mid = fineBlur.values[i] - midBlur.values[i]
                var low = midBlur.values[i]
                // Even tone: flatten low-frequency lightness blotches toward the broad skin level.
                low += tone * 0.6f * (lowBlur.values[i] - low)
                var lightness = low + mid * (1 - s) + fine * (1 - s * (1 - keep))
                var a = A.values[i]
                var b = B.values[i]
                // Blemishes: temporary marks are redder than the skin around them; brown moles and
                // freckles are not, so they stay.
                val redness = a - aLow.values[i]
                if (blemish > 0 && redness > 0.006f) {
                    val w = blemish * min((redness - 0.006f) / 0.02f, 1f)
                    a += (aLow.values[i] - a) * w
                    b += (bLow.values[i] - b) * w * 0.5f
                    lightness += max(midBlur.values[i] - lightness, 0f) * w
                }
                if (tone > 0) {
                    a += (aLow.values[i] - a) * tone * 0.3f
                    b += (bLow.values[i] - b) * tone * 0.3f
                }
                L.values[i] += (lightness - L.values[i]) * m
                A.values[i] += (a - A.values[i]) * m
                B.values[i] += (b - B.values[i]) * m
            }
        }

        if (e.underEye.brighten > 0 || e.underEye.softenLines > 0) {
            val under = union(underEyeMask(cw, ch, d.imageLeftEye.map(::local), faceWidthPx, feather), underEyeMask(cw, ch, d.imageRightEye.map(::local), faceWidthPx, feather))
            val soft = blur(L, max(1f, faceWidthPx * 0.008f))
            val reference = blurLarge(L, max(3f, faceWidthPx * 0.08f))
            for (i in L.values.indices) {
                val m = under.values[i] * (1 - eyes.values[i])
                if (m <= 0.001f) continue
                var l = L.values[i]
                l += (soft.values[i] - l) * (e.underEye.softenLines / 100).toFloat() * 0.8f
                l += max(reference.values[i] - l, 0f) * (e.underEye.brighten / 100).toFloat() * 0.7f
                L.values[i] += (l - L.values[i]) * m
            }
        }

        if (e.eyes.brighten > 0 || e.eyes.clarity > 0) {
            val eyeMean = blur(L, max(1f, faceWidthPx * 0.01f))
            for (i in L.values.indices) {
                val m = eyes.values[i]
                if (m <= 0.001f) continue
                var l = L.values[i]
                l += (l - eyeMean.values[i]) * (e.eyes.clarity / 100).toFloat() * 0.8f
                l += (1 - l) * (e.eyes.brighten / 100).toFloat() * 0.12f
                L.values[i] += (l.coerceIn(0f, 1f) - L.values[i]) * m
            }
        }

        val innerLips = d.innerLips
        if (e.teeth.brighten > 0 && innerLips.size >= 3) {
            val mouth = polygonMask(cw, ch, innerLips.map(::local), 0f, feather * 0.5f)
            for (i in L.values.indices) {
                val chroma = sqrt(A.values[i] * A.values[i] + B.values[i] * B.values[i])
                val toothLike = ((L.values[i] - 0.45f) / 0.15f).coerceIn(0f, 1f) * ((0.09f - chroma) / 0.04f).coerceIn(0f, 1f)
                val m = mouth.values[i] * toothLike
                if (m <= 0.001f) continue
                // Natural range: at most 40 % of the way to L 0.92, never past it.
                val target = min(L.values[i] + (0.92f - L.values[i]) * 0.4f * (e.teeth.brighten / 100).toFloat(), 0.92f)
                L.values[i] += (max(target, L.values[i]) - L.values[i]) * m
            }
        }

        if (e.hair.definition > 0 || e.hair.flyaways > 0 || e.hair.shine > 0) {
            val head = ellipseMask(cw, ch, local(Point(box.x + box.width / 2, box.y + box.height * 0.45)), faceWidthPx * 1.05f, (box.height * H * 1.05).toFloat(), feather * 3)
            val hair = FloatPlane(cw, ch)
            for (y in 0 until ch) for (x in 0 until cw) {
                val i = y * cw + x
                val person = personMatte?.let { it[min(it.width - 1, x + cx0), min(it.height - 1, y + cy0)] } ?: 1f
                hair.values[i] = head.values[i] * person * (1 - skin.values[i]) * (1 - eyes.values[i]) * (1 - lips.values[i])
            }
            val hairMean = blur(L, max(1f, faceWidthPx * 0.015f))
            val fine = blur(L, max(0.8f, faceWidthPx * 0.004f))
            val edge = if (personMatte != null) edgeBand(hair) else hair
            for (i in L.values.indices) {
                val m = hair.values[i]
                if (m <= 0.001f) continue
                var l = L.values[i]
                l += (l - hairMean.values[i]) * (e.hair.definition / 100).toFloat() * 0.9f
                if (l > hairMean.values[i]) l += (l - hairMean.values[i]) * (e.hair.shine / 100).toFloat() * 1.2f
                l += (fine.values[i] - l) * (e.hair.flyaways / 100).toFloat() * edge.values[i]
                L.values[i] += (l.coerceIn(0f, 1f) - L.values[i]) * m
            }
        }

        val linear = DoubleArray(3)
        for (i in L.values.indices) {
            if (L.values[i] == originalL[i] && A.values[i] == originalA[i] && B.values[i] == originalB[i]) continue
            ColourMath.oklabToLinear(L.values[i].toDouble(), A.values[i].toDouble(), B.values[i].toDouble(), linear)
            val o = ((i / cw + cy0) * width + i % cw + cx0) * 4
            for (c in 0 until 3) pixels[o + c] = (ColourMath.linearToSrgb(linear[c]).coerceIn(0.0, 1.0) * 255 + 0.5).toInt().toByte()
        }
    }

    // --- masks (same geometry as iOS) ----------------------------------------------------------

    fun ellipseMask(width: Int, height: Int, centre: Point, radiusX: Float, radiusY: Float, feather: Float): FloatPlane {
        val out = FloatPlane(width, height)
        val edge = max(feather / max(radiusX, radiusY), 1e-3f)
        for (y in 0 until height) for (x in 0 until width) {
            val dx = (x - centre.x.toFloat()) / radiusX
            val dy = (y - centre.y.toFloat()) / radiusY
            val r = sqrt(dx * dx + dy * dy)
            out[x, y] = ((1 - r) / edge + 0.5f).coerceIn(0f, 1f)
        }
        return out
    }

    /** A filled polygon (even-odd, pixel centres), grown by [grow] px and feathered by [feather] px. */
    fun polygonMask(width: Int, height: Int, points: List<Point>, grow: Float, feather: Float): FloatPlane {
        var out = FloatPlane(width, height)
        if (points.size < 3) return out
        val margin = grow + feather * 2
        val x0 = max(0, (points.minOf { it.x } - margin).toInt())
        val x1 = min(width - 1, (points.maxOf { it.x } + margin).toInt())
        val y0 = max(0, (points.minOf { it.y } - margin).toInt())
        val y1 = min(height - 1, (points.maxOf { it.y } + margin).toInt())
        if (x0 > x1 || y0 > y1) return out
        for (y in y0..y1) for (x in x0..x1) if (contains(points, x + 0.5, y + 0.5)) out[x, y] = 1f
        if (grow >= 1) {
            val dilated = PlaneOps.dilateDisc(out, 0.5f, grow.roundToInt())
            out = FloatPlane(width, height, FloatArray(dilated.size) { if (dilated[it]) 1f else 0f })
        }
        return PlaneOps.gaussianBlur(out, max(feather / 2, 0.5f).toDouble())
    }

    private fun contains(polygon: List<Point>, x: Double, y: Double): Boolean {
        var inside = false
        var j = polygon.size - 1
        for (i in polygon.indices) {
            val a = polygon[i]
            val b = polygon[j]
            if ((a.y > y) != (b.y > y) && x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x) inside = !inside
            j = i
        }
        return inside
    }

    fun underEyeMask(width: Int, height: Int, eye: List<Point>, faceWidth: Float, feather: Float): FloatPlane {
        if (eye.size < 3) return FloatPlane(width, height)
        val minX = eye.minOf { it.x }.toFloat()
        val maxX = eye.maxOf { it.x }.toFloat()
        val maxY = eye.maxOf { it.y }.toFloat()
        val eyeHeight = max(maxY - eye.minOf { it.y }.toFloat(), faceWidth * 0.04f)
        return ellipseMask(width, height, Point(((minX + maxX) / 2).toDouble(), (maxY + eyeHeight * 0.9f).toDouble()), (maxX - minX) * 0.55f, eyeHeight * 0.75f, feather * 2)
    }

    fun skinMask(face: FloatPlane, exclusions: List<FloatPlane>, a: FloatPlane, b: FloatPlane): FloatPlane {
        val coreA = ArrayList<Float>()
        val coreB = ArrayList<Float>()
        for (i in face.values.indices) if (face.values[i] > 0.9f && exclusions.all { it.values[i] < 0.1f }) { coreA += a.values[i]; coreB += b.values[i] }
        val medianA = if (coreA.isEmpty()) 0f else PlaneOps.median(coreA.toFloatArray()).toFloat()
        val medianB = if (coreB.isEmpty()) 0f else PlaneOps.median(coreB.toFloatArray()).toFloat()
        val out = FloatPlane(face.width, face.height)
        for (i in out.values.indices) {
            val distance = sqrt((a.values[i] - medianA) * (a.values[i] - medianA) + (b.values[i] - medianB) * (b.values[i] - medianB))
            val similarity = (1 - (distance - 0.02f) / 0.04f).coerceIn(0f, 1f)
            var m = face.values[i] * similarity
            for (exclusion in exclusions) m *= 1 - exclusion.values[i]
            out.values[i] = m
        }
        return out
    }

    fun union(a: FloatPlane, b: FloatPlane) = FloatPlane(a.width, a.height, FloatArray(a.values.size) { max(a.values[it], b.values[it]) })

    /** Where a mask is partial: its outer band (flyaways live at the hair's silhouette). */
    fun edgeBand(mask: FloatPlane): FloatPlane {
        val blurred = PlaneOps.boxFilter(mask, 3)
        return FloatPlane(mask.width, mask.height, FloatArray(mask.values.size) { min(1f, 4 * blurred.values[it] * (1 - blurred.values[it])) })
    }

    // --- filters ------------------------------------------------------------------------------------

    private fun blur(plane: FloatPlane, sigma: Float): FloatPlane = if (sigma > LARGE_SIGMA) blurLarge(plane, sigma) else PlaneOps.gaussianBlur(plane, sigma.toDouble())

    /**
     * A Gaussian of large σ computed at reduced resolution (area downsample so σ ≤ [LARGE_SIGMA] there,
     * blur, bilinear upsample), as iOS `RefocusRenderer.blurLarge`. The planes it feeds are broad local
     * means, where the resampling error is far below the operators' effect.
     */
    fun blurLarge(plane: FloatPlane, sigma: Float): FloatPlane {
        if (sigma <= LARGE_SIGMA) return PlaneOps.gaussianBlur(plane, sigma.toDouble())
        val factor = max(1, ceil(sigma / LARGE_SIGMA).toInt())
        val small = PlaneOps.downsampleArea(plane, factor)
        val blurred = PlaneOps.gaussianBlur(small, (sigma / factor).toDouble())
        return PlaneOps.resizeBilinear(blurred, plane.width, plane.height)
    }

    private const val LARGE_SIGMA = 6f

    private val SRGB_TO_LINEAR = DoubleArray(256) { ColourMath.srgbToLinear(it / 255.0) }
}
