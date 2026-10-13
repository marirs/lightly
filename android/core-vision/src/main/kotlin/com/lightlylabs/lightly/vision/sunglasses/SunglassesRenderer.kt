package com.lightlylabs.lightly.vision.sunglasses

import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.background.PlaneOps
import com.lightlylabs.lightly.session.FaceEdit
import com.lightlylabs.lightly.session.Sunglasses
import com.lightlylabs.lightly.session.SunglassesLens
import com.lightlylabs.lightly.vision.FaceMeshTriangles
import com.lightlylabs.lightly.vision.RgbaImage
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * `portrait.sunglasses` (rendering-v2 revision 9 §7.5): puts a 3D pair from the sunglasses pack on a face. A port of iOS
 * `SunglassesRenderer.swift`; the passes come from [SunglassesRaster] instead of SceneKit. Works on RGBA8 sRGB pixels,
 * which is where §7.5 composites (sRGB-encoded values).
 */
object SunglassesRenderer {

    /** The head's frame in scene units (x right, y up, z towards the viewer, origin at the image centre, pixels). */
    class Pose(val ex: DoubleArray, val ey: DoubleArray, val ez: DoubleArray, val pixelsPerMetre: Double, val origin: DoubleArray, val isProfile: Boolean)

    /** §7.5 pose from render-pixel landmarks ([p]: 478 × xyz) and the background probability at render pixels. */
    fun pose(p: FloatArray, width: Int, height: Int, background: (Float, Float) -> Float): Pose {
        fun w(i: Int) = doubleArrayOf(p[i * 3].toDouble(), -p[i * 3 + 1].toDouble(), -p[i * 3 + 2].toDouble())
        var ex = normalise(sub(w(263), w(33)))
        var ez = normalise(cross(ex, sub(w(10), w(152))))
        val ey = cross(ez, ex)
        val s = length(sub(w(263), w(33))) / SunglassesConstants.INTER_IRIS_REFERENCE_METRES
        // Profile correction: walk outward from the far iris (continuing near → far) until the background; within 7 mm,
        // raise the turn towards 85 degrees.
        var isProfile = false
        val yaw = atan2(ez[0], ez[2])
        val near = if (yaw < 0) 473 else 468; val far = if (yaw < 0) 468 else 473
        val sx = p[far * 3].toDouble(); val sy = p[far * 3 + 1].toDouble()
        var dx = sx - p[near * 3]; var dy = sy - p[near * 3 + 1]
        val dl = sqrt(dx * dx + dy * dy).takeIf { it > 1e-9 } ?: 1.0
        dx /= dl; dy /= dl
        var margin: Double? = null
        val steps = (SunglassesConstants.PROFILE_MARGIN_METRES * s).toInt()
        for (t in 0..max(steps, 0)) {
            val qx = sx + dx * t; val qy = sy + dy * t
            val xi = qx.toInt(); val yi = qy.toInt()
            if (qx < 0 || qy < 0 || xi >= width || yi >= height || background(xi + 0.5f, yi + 0.5f) > 0.5f) { margin = t / s; break }
        }
        val target = SunglassesConstants.PROFILE_TARGET_YAW_DEGREES * PI / 180
        if (margin != null && abs(yaw) < target) {
            val raised = abs(yaw) + (target - abs(yaw)) * (1 - margin / SunglassesConstants.PROFILE_MARGIN_METRES)
            val angle = (raised - abs(yaw)) * (if (yaw < 0) -1 else 1)
            ex = rotate(ex, ey, angle); ez = rotate(ez, ey, angle)
            isProfile = true
        }
        fun sc(i: Int) = doubleArrayOf(p[i * 3] - width / 2.0, height / 2.0 - p[i * 3 + 1], -p[i * 3 + 2].toDouble())
        val iris = DoubleArray(3) { (sc(468)[it] + sc(473)[it]) / 2 }
        val origin = DoubleArray(3) { iris[it] + s * SunglassesConstants.EYE_DEPTH_METRES * ez[it] }
        return Pose(ex, ey, ez, s, origin, isProfile)
    }

    // MARK: Lens (§7.5 composite 3)

    fun transmission(darkness: Double): Double = 1 - 0.95 * (darkness / 100).pow(0.75)

    fun tint(lens: SunglassesLens): DoubleArray = when (lens) {
        SunglassesLens.BROWN -> doubleArrayOf(1.00, 0.76, 0.52)
        SunglassesLens.GREEN -> doubleArrayOf(0.80, 1.00, 0.82)
        else -> doubleArrayOf(0.92, 1.00, 0.95)
    }

    /** The glass over one pixel (sRGB-encoded values); [t] runs from 0 at the lenses' top row to 1 at their bottom. */
    fun glass(input: DoubleArray, g: Sunglasses, t: Double): DoubleArray {
        val reflection = (0.16 * (1 - t) * (1 - t) + 0.03).let { doubleArrayOf(it * 0.85, it * 0.90, it * 1.00) }
        return when (g.lens) {
            SunglassesLens.GRADIENT -> {
                val tr = transmission(g.darkness * (1 - 0.7 * t)); val tn = tint(SunglassesLens.DARK)
                DoubleArray(3) { input[it] * tr * tn[it] + reflection[it] }
            }
            SunglassesLens.MIRROR -> {
                val tr = transmission(g.darkness); val tn = tint(SunglassesLens.DARK)
                val top = doubleArrayOf(0.55, 0.65, 0.80); val bottom = doubleArrayOf(0.25, 0.30, 0.38)
                DoubleArray(3) { input[it] * tr * tn[it] + reflection[it] * 3 + 0.35 * (top[it] * (1 - t) + bottom[it] * t) }
            }
            else -> {
                val tr = transmission(g.darkness); val tn = tint(g.lens)
                DoubleArray(3) { input[it] * tr * tn[it] + reflection[it] }
            }
        }
    }

    // MARK: Stage

    /** The person's analysis maps at render pixels, over every face (hair: max, background: min). */
    class Maps(private val analyses: List<FaceSunglassesAnalysis>, private val scale: Float) {
        fun hair(x: Float, y: Float): Float {
            var best = 0f
            for (a in analyses) a.hair.sample(x * scale, y * scale)?.let { if (it > best) best = it }
            return best
        }
        fun background(x: Float, y: Float): Float {
            var best = 1f
            for (a in analyses) a.background.sample(x * scale, y * scale)?.let { if (it < best) best = it }
            return best
        }
    }

    class Face(val edit: FaceEdit, val analysis: FaceSunglassesAnalysis)

    /** A painted-out patch composited into a region buffer: (pixels, regionX, regionY, regionW, regionH, frameW, frameH, sha256). */
    fun interface RemovedPatch { fun composite(pixels: ByteArray, regionX: Int, regionY: Int, regionWidth: Int, regionHeight: Int, frameWidth: Int, frameHeight: Int, sha256: String) }

    /** Applies every face's pair to a copy of [image] (RGBA8 sRGB, the whole frame at render size). */
    fun render(image: RgbaImage, faces: List<Face>, allAnalyses: List<FaceSunglassesAnalysis>, pack: SunglassesPack,
               textures: (String) -> SunglassesRaster.Texture?, removed: RemovedPatch = RemovedPatch { _, _, _, _, _, _, _, _ -> }): RgbaImage =
        renderRegion(image, 0, 0, image.width, image.height, faces, allAnalyses, pack, textures, removed)

    /**
     * Applies every face's pair to a copy of [region]: the pixels of the rectangle at ([regionX], [regionY]) of a
     * [frameWidth] × [frameHeight] frame (Save copy renders full-resolution regions). Pose, passes and maps are in frame
     * coordinates, so every pixel gets what a whole-frame render gives it.
     */
    fun renderRegion(region: RgbaImage, regionX: Int, regionY: Int, frameWidth: Int, frameHeight: Int, faces: List<Face>,
                     allAnalyses: List<FaceSunglassesAnalysis>, pack: SunglassesPack, textures: (String) -> SunglassesRaster.Texture?,
                     removed: RemovedPatch = RemovedPatch { _, _, _, _, _, _, _, _ -> }): RgbaImage {
        val wearing = faces.filter { it.edit.sunglasses?.pair != null && it.analysis.isReadable }
        if (wearing.isEmpty() || allAnalyses.isEmpty()) return region
        val out = region.pixels.copyOf()
        val maps = Maps(allAnalyses, allAnalyses.first().analysisWidth.toFloat() / frameWidth)
        for (face in wearing) {
            val g = face.edit.sunglasses!!
            val pair = pack.pair(g.pair!!) ?: continue
            // 1. The face's own glasses, painted out (only while a pair is chosen).
            g.removed?.let { removed.composite(out, regionX, regionY, region.width, region.height, frameWidth, frameHeight, it.patch.sha256) }
            val r = frameWidth.toFloat() / face.analysis.analysisWidth
            val p = FloatArray(face.analysis.landmarks.size) { face.analysis.landmarks[it] * r }
            val pose = pose(p, frameWidth, frameHeight) { x, y -> maps.background(x, y) }
            val passes = passes(pack, pair, textures, pose, g.size, p, frameWidth, frameHeight) ?: continue
            composite(passes, out, regionX, regionY, region.width, region.height, g, pose, face.analysis.irisSpan * r, maps)
        }
        return RgbaImage(region.width, region.height, out)
    }

    /** The frame rectangle [renderRegion] changes for one face (the pair's ±0.2 m square), or null when it wears none. */
    fun regionFor(face: Face, allAnalyses: List<FaceSunglassesAnalysis>, frameWidth: Int, frameHeight: Int): IntArray? {
        val g = face.edit.sunglasses ?: return null
        if (g.pair == null || !face.analysis.isReadable || allAnalyses.isEmpty()) return null
        val maps = Maps(allAnalyses, allAnalyses.first().analysisWidth.toFloat() / frameWidth)
        val r = frameWidth.toFloat() / face.analysis.analysisWidth
        val p = FloatArray(face.analysis.landmarks.size) { face.analysis.landmarks[it] * r }
        val pose = pose(p, frameWidth, frameHeight) { x, y -> maps.background(x, y) }
        val s = pose.pixelsPerMetre
        val cx = pose.origin[0] + frameWidth / 2.0; val cy = frameHeight / 2.0 - pose.origin[1]; val half = 0.2 * s
        val x0 = max(0, (cx - half).toInt()); val y0 = max(0, (cy - half).toInt())
        val x1 = min(frameWidth, ceil(cx + half).toInt()); val y1 = min(frameHeight, ceil(cy + half).toInt())
        // The painted-out patch can reach beyond the pair's square: include it.
        val rem = g.removed?.rect
        val rx0 = rem?.let { min(x0, (it.x * frameWidth).toInt()) } ?: x0
        val ry0 = rem?.let { min(y0, (it.y * frameHeight).toInt()) } ?: y0
        val rx1 = rem?.let { max(x1, ceil((it.x + it.width) * frameWidth).toInt()) } ?: x1
        val ry1 = rem?.let { max(y1, ceil((it.y + it.height) * frameHeight).toInt()) } ?: y1
        return if (rx1 > rx0 && ry1 > ry0) intArrayOf(max(0, rx0), max(0, ry0), min(frameWidth, rx1) - max(0, rx0), min(frameHeight, ry1) - max(0, ry0)) else null
    }

    class Passes(val frame: SunglassesRaster.Result, val front: SunglassesRaster.Result, val lens: SunglassesRaster.Result)

    /** The three passes over a square of ±0.2 m around the pair's origin (the pair reaches ~0.16 m behind its lenses). */
    fun passes(pack: SunglassesPack, pair: SunglassesPack.Pair, textures: (String) -> SunglassesRaster.Texture?, pose: Pose, size: Double,
               p: FloatArray, width: Int, height: Int): Passes? {
        val s = pose.pixelsPerMetre
        val cx = pose.origin[0] + width / 2.0; val cy = height / 2.0 - pose.origin[1]; val half = 0.2 * s
        val x0 = max(0, (cx - half).toInt()); val y0 = max(0, (cy - half).toInt())
        val x1 = min(width, ceil(cx + half).toInt()); val y1 = min(height, ceil(cy + half).toInt())
        if (x1 - x0 <= 2 || y1 - y0 <= 2) return null
        val placement = SunglassesRaster.Placement(pose.origin, pose.ex, pose.ey, pose.ez, s * (1 + SunglassesConstants.SIZE_PER_UNIT * size))
        val faceMesh = faceOccluder(p, width, height, -pose.origin[2] - SunglassesConstants.FACE_MESH_PUSH_BACK_METRES * s)
        val mesh = pack.mesh(pair)
        fun pass(which: SunglassesRaster.Pass) =
            SunglassesRaster.render(pack, pair, mesh, textures, placement, width, height, x0, y0, x1 - x0, y1 - y0, faceMesh, which)
        return Passes(pass(SunglassesRaster.Pass.FRAME), pass(SunglassesRaster.Pass.FRONT), pass(SunglassesRaster.Pass.LENS))
    }

    /** The face mesh (468 landmarks, MediaPipe's canonical triangles) as scene-unit triangles, pushed back by [zShift]. */
    fun faceOccluder(p: FloatArray, width: Int, height: Int, zShift: Double): FloatArray {
        val idx = FaceMeshTriangles.INDICES
        val out = FloatArray(idx.size * 3)
        for ((o, i) in idx.withIndex()) {
            out[o * 3] = (p[i * 3] - width / 2.0).toFloat()
            out[o * 3 + 1] = (height / 2.0 - p[i * 3 + 1]).toFloat()
            out[o * 3 + 2] = (-p[i * 3 + 2] + zShift).toFloat()
        }
        return out
    }

    /**
     * §7.5 composite 2–5 over the passes' rectangle, in sRGB-encoded values, into [pixels]: the RGBA8 pixels of the region
     * at ([regionX], [regionY]) of the frame, [regionWidth] × [regionHeight]. Pixels outside the region are skipped.
     */
    fun composite(passes: Passes, pixels: ByteArray, regionX: Int, regionY: Int, regionWidth: Int, regionHeight: Int,
                  g: Sunglasses, pose: Pose, irisSpan: Float, maps: Maps) {
        val frame = passes.frame; val front = passes.front; val lensPass = passes.lens
        val rw = frame.width; val rh = frame.height; val n = rw * rh
        val background = FloatArray(n)
        val hairRaw = FloatPlane(rw, rh)
        for (y in 0 until rh) for (x in 0 until rw) {
            val px = frame.x0 + x + 0.5f; val py = frame.y0 + y + 0.5f
            background[y * rw + x] = maps.background(px, py)
            hairRaw[x, y] = maps.hair(px, py)
        }
        val hair = PlaneOps.gaussianBlur(hairRaw, 2.0)
        val frameAlpha = FloatArray(n) { frame.rgba[it * 4 + 3] }
        val frontAlpha = FloatArray(n) { front.rgba[it * 4 + 3] }
        val lens = FloatArray(n) { lensPass.rgba[it * 4] * lensPass.rgba[it * 4 + 3] }
        // 5. Profile clip: lens and frame within 4 mm of the person, soft edge.
        if (pose.isProfile) {
            val near = nearPerson(background, rw, rh, (SunglassesConstants.PROFILE_OVERHANG_METRES * pose.pixelsPerMetre).toFloat())
            for (i in 0 until n) { lens[i] *= near[i]; frameAlpha[i] *= near[i] }
        }
        // 2. Contact shadow: coverage blurred, shifted down and right, darkens the person.
        val coverage = PlaneOps.gaussianBlur(FloatPlane(rw, rh, FloatArray(n) { max(frameAlpha[it], lens[it]) }),
                                             max(1.0, SunglassesConstants.SHADOW_SIGMA_OF_IRIS_SPAN * irisSpan))
        val dx = (SunglassesConstants.SHADOW_OFFSET_X_OF_IRIS_SPAN * irisSpan).toInt()
        val dy = (SunglassesConstants.SHADOW_OFFSET_Y_OF_IRIS_SPAN * irisSpan).toInt()
        var top = rh; var bottom = -1
        for (y in 0 until rh) for (x in 0 until rw) if (lens[y * rw + x] > 0.5f) { top = min(top, y); bottom = max(bottom, y); break }
        val span = max(1, bottom - top).toDouble()
        val px = DoubleArray(3)
        for (y in 0 until rh) {
            val t = ((y - top) / span).coerceIn(0.0, 1.0)
            val ry = frame.y0 + y - regionY
            if (ry < 0 || ry >= regionHeight) continue
            for (x in 0 until rw) {
                val rx = frame.x0 + x - regionX
                if (rx < 0 || rx >= regionWidth) continue
                val i = y * rw + x
                val o = (ry * regionWidth + rx) * 4
                for (c in 0..2) px[c] = (pixels[o + c].toInt() and 0xff) / 255.0
                val sx = x - dx; val sy = y - dy
                if (background[i] < 0.5f && sx >= 0 && sy >= 0 && sx < rw && sy < rh) {
                    val shade = 1 - coverage.values[sy * rw + sx] * SunglassesConstants.SHADOW_STRENGTH
                    for (c in 0..2) px[c] *= shade
                }
                // 3. Lenses: the photo seen through the tinted glass.
                val l = lens[i].toDouble()
                if (l > 0) { val gl = glass(px, g, t); for (c in 0..2) px[c] = px[c] * (1 - l) + gl[c] * l }
                // 4. Frame: hair covers the arms (beyond the front 12 mm), never the front.
                val fa = frameAlpha[i]
                if (fa > 0) {
                    val cover = ((hair.values[i] - 0.3f) / 0.4f).coerceIn(0f, 1f)
                    val alpha = min(frontAlpha[i] + (fa - frontAlpha[i]) * (1 - cover), fa).toDouble()
                    for (c in 0..2) px[c] = px[c] * (1 - alpha) + frame.rgba[i * 4 + c] * alpha
                }
                for (c in 0..2) pixels[o + c] = (px[c].coerceIn(0.0, 1.0) * 255 + 0.5).toInt().toByte()
            }
        }
    }

    /** About 1 within [radius] px of the person, 0 beyond: dilated at quarter resolution, blurred, up-sampled, soft. */
    fun nearPerson(background: FloatArray, width: Int, height: Int, radius: Float): FloatArray {
        val person = FloatPlane(width, height, FloatArray(width * height) { if (background[it] < 0.5f) 1f else 0f })
        val qw = max(1, width / 4); val qh = max(1, height / 4)
        val quarter = PlaneOps.resizeBilinear(person, qw, qh)
        val spread = PlaneOps.boxFilter(FloatPlane(qw, qh, FloatArray(qw * qh) { if (quarter.values[it] > 0.5f) 1f else 0f }),
                                        max(1, (radius / 4).toInt()))
        val dilated = FloatPlane(qw, qh, FloatArray(qw * qh) { if (spread.values[it] > 1e-6f) 1f else 0f })
        val up = PlaneOps.resizeBilinear(PlaneOps.gaussianBlur(dilated, 0.75), width, height)
        return FloatArray(width * height) { ((up.values[it] - 0.25f) / 0.5f).coerceIn(0f, 1f) }
    }

    // MARK: Vectors

    private fun sub(a: DoubleArray, b: DoubleArray) = DoubleArray(3) { a[it] - b[it] }
    private fun length(a: DoubleArray) = sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])
    private fun normalise(a: DoubleArray): DoubleArray { val l = length(a); return DoubleArray(3) { a[it] / l } }
    private fun cross(a: DoubleArray, b: DoubleArray) = doubleArrayOf(a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
    private fun dot(a: DoubleArray, b: DoubleArray) = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    fun rotate(v: DoubleArray, axis: DoubleArray, angle: Double): DoubleArray {
        val k = normalise(axis); val c = cos(angle); val s = sin(angle); val kv = cross(k, v); val d = dot(k, v)
        return DoubleArray(3) { v[it] * c + kv[it] * s + k[it] * d * (1 - c) }
    }
}
