package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.background.BackgroundAnalysis
import com.lightlylabs.lightly.background.BackgroundPlan
import com.lightlylabs.lightly.background.BackgroundStage
import com.lightlylabs.lightly.background.DepthMaps
import com.lightlylabs.lightly.background.DepthModelInput
import com.lightlylabs.lightly.background.DepthOrigin
import com.lightlylabs.lightly.background.DepthUnavailableException
import com.lightlylabs.lightly.background.EmbeddedDepthReader
import com.lightlylabs.lightly.background.FloatImage
import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.background.FocusParams
import com.lightlylabs.lightly.background.ReplacementImage
import com.lightlylabs.lightly.background.SegmentationUnavailableException
import com.lightlylabs.lightly.develop.DevelopRenderPlan
import com.lightlylabs.lightly.develop.DevelopRenderer
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.AssetRef
import com.lightlylabs.lightly.session.BackgroundTool
import com.lightlylabs.lightly.session.DepthSource
import com.lightlylabs.lightly.session.DerivedRef
import com.lightlylabs.lightly.session.ModelRef
import com.lightlylabs.lightly.session.Replacement
import java.nio.ByteBuffer
import kotlin.math.roundToInt
import java.security.MessageDigest

/**
 * Depth and the subject matte for one photo, and the conversion of the recipe's background section
 * into a [BackgroundPlan] (rendering-v2 stages background.replace and background.focus).
 * Analysis runs once per photo, at the display proxy's resolution.
 */
/** Replacement assets kept converted: the current one and the previous one (A/B toggling stays cheap). */
private const val REPLACEMENT_CACHE_SIZE = 2

class BackgroundSession(private val env: EditorEnvironment) {
    @Volatile var analysis: BackgroundAnalysis? = null
        private set
    var noClearSubject = false
        private set

    /** Which model made the depth map, for the recipe's derivedRef. */
    private var depthModel: ModelRef? = null
    private var matteModel: ModelRef? = null

    /**
     * Replacement photos as sRGB [0,1] R, G, B planes, by AssetRef, holding at most
     * [REPLACEMENT_CACHE_SIZE] assets (least recently used evicted).
     *
     * Converting a photo on every render (preview, each drag frame, each Save-copy tile) allocated
     * ~22 MB per call and ran the 192 MB heap out of memory with a subject matte (Pixel 9 Pro
     * emulator). An unbounded cache would instead grow with every background tried. An evicted
     * asset is reloaded from its reference, so Undo to an earlier background still renders:
     * bundled backgrounds from the app, picked photos through the photo loader (access retained
     * when picked).
     */
    private val replacementPlanes = object : LinkedHashMap<AssetRef, List<com.lightlylabs.lightly.background.FloatPlane>>(4, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<AssetRef, List<com.lightlylabs.lightly.background.FloatPlane>>?) =
            size > REPLACEMENT_CACHE_SIZE
    }

    /** The planes for [asset], converting or reloading it when not cached; null when it can't be read. */
    internal fun replacementPlanesFor(asset: AssetRef): List<com.lightlylabs.lightly.background.FloatPlane>? {
        synchronized(replacementPlanes) { replacementPlanes[asset]?.let { return it } }
        val photo = when (asset) {
            is AssetRef.Bundled -> env.bundledBackground(asset.id)
            // Renders run off the main thread; the loader decodes at the display proxy size.
            is AssetRef.Photo -> runCatching { kotlinx.coroutines.runBlocking { env.photoLoader.load(asset.assetId).display } }.getOrNull()
            is AssetRef.File -> null
        } ?: return null
        return toPlanes(photo).also { planes -> synchronized(replacementPlanes) { replacementPlanes[asset] = planes } }
    }

    /** How many replacement assets are held (for tests). */
    internal val cachedReplacementCount: Int get() = synchronized(replacementPlanes) { replacementPlanes.size }

    private fun toPlanes(photo: Rgba8Image): List<com.lightlylabs.lightly.background.FloatPlane> = (0 until 3).map { c ->
        com.lightlylabs.lightly.background.FloatPlane(photo.width, photo.height,
            FloatArray(photo.pixelCount) { (photo.pixels[it * 4 + c].toInt() and 0xff) / 255f })
    }

    /**
     * Embedded depth first (Dynamic Depth, GDepth), else the depth estimator; then the segmenter.
     * Never throws for an unavailable capability: that is recorded as a missing result.
     */
    suspend fun analyse(loaded: LoadedPhoto): SeparationState.Finished {
        val display = loaded.display
        val grey = FloatPlane(display.width, display.height, FloatArray(display.pixelCount) { p ->
            val i = p * 4
            (0.299f * (display.pixels[i].toInt() and 0xff) + 0.587f * (display.pixels[i + 1].toInt() and 0xff) + 0.114f * (display.pixels[i + 2].toInt() and 0xff)) / 255f
        })
        var depth: com.lightlylabs.lightly.background.NormalisedDepth? = null
        val embedded = runCatching { loaded.readOriginal() }.getOrNull()?.let { bytes ->
            runCatching { EmbeddedDepthReader.read(bytes, env.depthImageDecoder) }.getOrNull()?.let { map -> map to env.exifOrientation(bytes) }
        }
        if (embedded != null) {
            val (map, orientation) = embedded
            depth = DepthMaps.normalised(DepthOrigin.EMBEDDED, Orientation.apply(map.disparity, orientation), grey)
            depthModel = ModelRef("embedded-depth", map.source.name.lowercase().replace('_', '-'))
        } else {
            try {
                val raw = env.depthEstimator.estimate(DepthModelInput.fromRgba8(display.pixels, display.width, display.height))
                depth = DepthMaps.normalised(DepthOrigin.ESTIMATED, raw, grey)
                logDepthSummary(raw, depth.nearness)
                depthModel = env.depthModelRef
            } catch (unavailable: DepthUnavailableException) {
                depth = null
            } catch (failure: RuntimeException) {
                // A runtime failure of the model is the approved unavailable state too, never a crash.
                diagnostic("depth estimate failed: $failure")
                depth = null
            }
        }
        var matte: FloatPlane? = null
        noClearSubject = false
        try {
            matte = env.segmenter.segment(display.pixels, display.width, display.height)
            if (matte == null) noClearSubject = true else matteModel = env.segmenterModelRef
        } catch (unavailable: SegmentationUnavailableException) {
            matte = null
        }
        analysis = BackgroundAnalysis(display.width, display.height, depth, matte)
        return SeparationState.Finished(depthAvailable = depth != null, matteAvailable = matte != null, noClearSubject = noClearSubject)
    }

    /** Logcat (tag LightlyDepth); a no-op where android.util.Log is not available (JVM unit tests). */
    private fun diagnostic(message: String) { runCatching { android.util.Log.i("LightlyDepth", message) } }

    /** Diagnostics (logcat tag LightlyDepth): raw model output range and nearness at a few points. */
    private fun logDepthSummary(raw: FloatPlane, nearness: FloatPlane) {
        val sorted = raw.values.sortedArray()
        fun at(x: Double, y: Double) = "%.2f".format(nearness[((nearness.width - 1) * x).toInt(), ((nearness.height - 1) * y).toInt()])
        diagnostic(
            "raw min=%.3f p1=%.3f p50=%.3f p99=%.3f max=%.3f; nearness centre=${at(0.5, 0.5)} (0.40,0.48)=${at(0.40, 0.48)} (0.1,0.1)=${at(0.1, 0.1)} (0.9,0.3)=${at(0.9, 0.3)} (0.5,0.95)=${at(0.5, 0.95)}"
                .format(sorted.first(), sorted[sorted.size / 100], sorted[sorted.size / 2], sorted[sorted.size * 99 / 100], sorted.last()),
        )
    }

    fun reset() {
        analysis = null
        faces = emptyList()
        noClearSubject = false
        synchronized(replacementPlanes) { replacementPlanes.clear() }
    }

    /** A photo just picked for Change background: converted now, so the first render needn't reload it. */
    fun rememberReplacementPhoto(asset: AssetRef, image: Rgba8Image) {
        val planes = toPlanes(image)
        synchronized(replacementPlanes) { replacementPlanes[asset] = planes }
    }

    /** The recipe's derived references for what the analysis produced (digest of the map's float bytes). */
    fun withDerivedRefs(tool: BackgroundTool): BackgroundTool {
        val a = analysis ?: return tool
        val depthRef = a.depth?.let { d -> depthModel?.let { DerivedRef(digest(d.nearness), it, d.nearness.width, d.nearness.height) } }
        val matteRef = a.matte?.let { m -> matteModel?.let { DerivedRef(digest(m), it, m.width, m.height) } }
        val depth = if (depthRef != null) {
            val source = if (a.depth!!.origin == DepthOrigin.EMBEDDED) DepthSource.EMBEDDED else DepthSource.ESTIMATED
            tool.focus.depth.copy(source = source, map = depthRef)
        } else tool.focus.depth
        return tool.copy(subject = tool.subject.copy(matte = matteRef ?: tool.subject.matte), focus = tool.focus.copy(depth = depth))
    }

    /** Nearness at the tap (§R3 window median on the topmost plane), stored in the recipe as depth = 1 − nearness. */
    fun focalNearnessAt(x: Double, y: Double): Double? {
        val a = analysis ?: return null
        val nearness = a.depth?.nearness ?: return null
        focalMemo?.let { (key, value) -> if (key.first === a && key.second == x to y) return value }
        return focalNearness(nearness, a.matte, x, y).also { focalMemo = (a to (x to y)) to it }
    }

    /** The last focal nearness and the analysis and target it was resolved for (every preview asks again). */
    @Volatile private var focalMemo: Pair<Pair<BackgroundAnalysis, Pair<Double, Double>>, Double>? = null



    /** The photo's detected faces (Portrait's analysis), for the default focus. */
    @Volatile private var faces: List<com.lightlylabs.lightly.vision.DetectedFace> = emptyList()

    fun setFaces(detected: List<com.lightlylabs.lightly.vision.DetectedFace>) { faces = detected }

    /**
     * Default focus (iOS `RefocusRenderer.defaultTarget(matte:faces:)`): the first usable face's centre
     * when it lies on the subject (matte ≥ 0.5 there), else the centroid of the subject (matte > 0.5),
     * else the image centre.
     */
    fun defaultTarget(): Pair<Double, Double> {
        val matte = analysis?.matte ?: return 0.5 to 0.5
        faces.firstOrNull { it.isUsable }?.let { face ->
            val x = face.box.x + face.box.width / 2
            val y = face.box.y + face.box.height / 2
            val mx = (x.coerceIn(0.0, 1.0) * (matte.width - 1)).toInt()
            val my = (y.coerceIn(0.0, 1.0) * (matte.height - 1)).toInt()
            if (matte[mx, my] >= 0.5f) return x to y
        }
        var sx = 0.0; var sy = 0.0; var sw = 0.0
        for (y in 0 until matte.height) for (x in 0 until matte.width) {
            val m = matte[x, y].toDouble()
            if (m <= 0.5) continue
            sx += m * x; sy += m * y; sw += m
        }
        return if (sw > 0) (sx / sw / maxOf(matte.width - 1, 1)) to (sy / sw / maxOf(matte.height - 1, 1)) else 0.5 to 0.5
    }

    /**
     * The plan for [tool], or null when the stage is the identity or cannot render here (no analysis,
     * or blur without depth: the panel then shows the approved failure state, never a substitute).
     * [developPlan] grades the replacement with the photo's global colour (rendering-v2 §1).
     */
    fun planFor(
        tool: BackgroundTool,
        developPlan: DevelopRenderPlan,
        renderer: DevelopRenderer,
        maxBlurFraction: Double = com.lightlylabs.lightly.background.Refocus.FocusConstants.MAX_BLUR_FRACTION_OF_LONG_EDGE,
        /** The working resolution's long edge (iOS LayeredStages caps: [INTERACTIVE_CAP], [PREVIEW_CAP], [EXPORT_CAP]). */
        cap: Int = PREVIEW_CAP,
    ): BackgroundPlan? {
        val a = refined(tool) ?: return null
        val focus = tool.focus
        val blur = if (a.depth == null) 0.0 else focus.blur
        // The replacement twice: at the analysis size, sampled for the full-resolution composite, and at the
        // working size, where Focus & Blur places it behind the subject.
        val full = tool.replacement?.takeIf { a.matte != null }?.let { r -> replacementPixels(r, a.width, a.height, developPlan, renderer) }
        if (full == null && blur <= 0.0) return null
        val (ww, wh) = BackgroundStage.workingSize(a.width, a.height, cap)
        val replacement = full?.let { r ->
            val small = if (ww == r.width && wh == r.height) Rgba8Image(r.width, r.height, r.rgba) else resize(Rgba8Image(r.width, r.height, r.rgba), ww, wh)
            FloatImage(ww, wh, 3, FloatArray(ww * wh * 3) { (small.pixels[(it / 3) * 4 + it % 3].toInt() and 0xff) / 255f })
        }
        val focal = focus.depth.focusDepth?.let { 1.0 - it }
            ?: focus.target?.let { focalNearnessAt(it.x, it.y) }
            ?: defaultTarget().let { (x, y) -> focalNearnessAt(x, y) } ?: 0.5
        // Revision 1 (G4): a stored focusDepth is used as d_f = 1 − focusDepth and never re-resolved.
        // replacementDepth is not read (G6): placement is §R2.4 "plane".
        return BackgroundPlan(replacement, FocusParams(blur, focus.depthOfField, focus.style.name.lowercase(), focus.bokeh.name.lowercase(), focus.styleAmount, maxBlurFraction), focal,
            focusTarget = focus.target?.let { it.x to it.y }, replacementFull = full)
    }

    /** The replacement drawn at w × h, graded with the photo's global colour, as sRGB RGBA8. */
    private fun replacementPixels(r: Replacement, w: Int, h: Int, developPlan: DevelopRenderPlan, renderer: DevelopRenderer): com.lightlylabs.lightly.background.ReplacementPixels? {
        val srgb = when (r) {
            is Replacement.Colour -> ReplacementImage.colour(w, h, r.colour)
            is Replacement.Gradient -> ReplacementImage.gradient(w, h, r.angle, r.stops.map { it.colour to it.position })
            is Replacement.Image -> {
                val planes = replacementPlanesFor(r.image) ?: return null
                ReplacementImage.photo(planes, w, h, r.scale, r.x, r.y)
            }
        }
        // The replacement receives the photo's global colour (Auto, develop.global at Amount); no spatial operator.
        val bytes = ByteArray(w * h * 4) { i -> if (i % 4 == 3) -1 else (srgb.data[(i / 4) * 3 + i % 4] * 255f + 0.5f).toInt().coerceIn(0, 255).toByte() }
        val graded = renderer.render(Rgba8Image(w, h, bytes), developPlan.globalOnly())
        return com.lightlylabs.lightly.background.ReplacementPixels(w, h, graded.pixels)
    }

    /** The analysis with the recipe's Refine edges strokes applied to the matte. */
    fun refined(tool: BackgroundTool): BackgroundAnalysis? {
        val a = analysis ?: return null
        val matte = a.matte ?: return a
        if (tool.subject.refinements.isEmpty()) return a
        val strokes = tool.subject.refinements.map { stroke ->
            com.lightlylabs.lightly.background.MatteStroke(stroke.mode == com.lightlylabs.lightly.session.RefineMode.ADD, stroke.radius, stroke.points.map { it.x to it.y })
        }
        return BackgroundAnalysis(a.width, a.height, a.depth, com.lightlylabs.lightly.background.MatteRefinement.apply(matte, strokes))
    }

    /**
     * Focus & Blur at the working resolution [cap] (iOS LayeredStages): [developed] at any size is brought
     * to the working size with the refined matte and depth, and rendered there. [plan] must come from
     * [planFor] with the same [cap].
     */
    fun working(developed: Rgba8Image, plan: BackgroundPlan, layersPerSide: Int, tool: BackgroundTool, cap: Int): com.lightlylabs.lightly.background.WorkingBackground {
        val a = refined(tool)!!
        val (ww, wh) = BackgroundStage.workingSize(a.width, a.height, cap)
        val frame = if (developed.width == ww && developed.height == wh) developed else resize(developed, ww, wh)
        val ops = com.lightlylabs.lightly.background.PlaneOps
        val small = if (ww == a.width && wh == a.height) a else BackgroundAnalysis(ww, wh,
            a.depth?.let { d -> com.lightlylabs.lightly.background.NormalisedDepth(d.origin, ops.resizeBilinear(d.nearness, ww, wh)) },
            a.matte?.let { ops.resizeBilinear(it, ww, wh) })
        return BackgroundStage.renderWorking(frame.pixels, small, plan, layersPerSide)
    }

    /** Background stage on a developed frame (the display proxy in previews): rendered at [cap], applied at the frame's size. */
    fun render(developed: Rgba8Image, plan: BackgroundPlan, layersPerSide: Int, tool: BackgroundTool, cap: Int): Rgba8Image {
        val working = working(developed, plan, layersPerSide, tool, cap)
        return Rgba8Image(developed.width, developed.height,
            BackgroundStage.applyRegion(developed.pixels, 0, 0, developed.width, developed.height, developed.width, developed.height, working, plan.replacementFull))
    }

    private fun digest(plane: FloatPlane): String {
        val buffer = ByteBuffer.allocate(plane.values.size * 4)
        plane.values.forEach { buffer.putFloat(it) }
        return MessageDigest.getInstance("SHA-256").digest(buffer.array()).joinToString("") { "%02x".format(it) }
    }

    companion object {
        /**
         * [com.lightlylabs.lightly.background.Refocus.focalNearness] on the planes
         * [com.lightlylabs.lightly.background.Refocus.buildScene] would build, computing only their nearness:
         * the median nearness of the topmost plane in a window of half-size 0.01 · longSide. The full scene
         * also builds three colour images at the analysis size (20 MB each at 1600 × 1067), which with a
         * subject matte exhausted the 192 MB heap on the emulator (OutOfMemoryError in pullPushFill,
         * bg-change-colour, 60c8b22). Same planes, same constants, same result.
         */
        internal fun focalNearness(nearness: FloatPlane, matte: FloatPlane?, x: Double, y: Double): Double {
            val w = nearness.width
            val h = nearness.height
            val longSide = maxOf(w, h)
            val cx = (x.coerceIn(0.0, 1.0) * (w - 1)).toInt()
            val cy = (y.coerceIn(0.0, 1.0) * (h - 1)).toInt()
            val ops = com.lightlylabs.lightly.background.PlaneOps
            val plane = if (matte == null) nearness else {
                val m = matte.map { it.coerceIn(0f, 1f) }
                if (m[cx, cy] >= 0.5f) {
                    var interior = ops.erodeDisc(m, 0.5f, (0.01 * longSide).roundToInt())
                    if (interior.count { it } < 50) interior = BooleanArray(w * h) { m.values[it] > 0.5f }
                    val raw = com.lightlylabs.lightly.background.Refocus.fillMaskedPlane(nearness, FloatPlane(w, h, FloatArray(w * h) { if (interior[it]) 1f else 0f }))
                    val values = nearness.values.filterIndexed { i, _ -> interior[i] }.toFloatArray()
                    val median = if (values.isNotEmpty()) ops.median(values) else 0.5
                    raw.map { (median + com.lightlylabs.lightly.background.Refocus.FocusConstants.SUBJECT_DEPTH_COMPRESSION * (it - median)).toFloat() }
                } else {
                    val band = ops.dilateDisc(m, 0.02f, (0.015 * longSide).roundToInt())
                    com.lightlylabs.lightly.background.Refocus.fillMaskedPlane(nearness, FloatPlane(w, h, FloatArray(w * h) { if (band[it]) 0f else 1f }))
                }
            }
            val radius = maxOf(2, (0.01 * longSide).roundToInt())
            val window = ArrayList<Float>()
            for (yy in maxOf(0, cy - radius)..minOf(h - 1, cy + radius)) for (xx in maxOf(0, cx - radius)..minOf(w - 1, cx + radius)) window += plane[xx, yy]
            return ops.median(window.toFloatArray())
        }

        /** The working caps (BackgroundStage: iOS LayeredStages' 640 and 1024; Save copy 768, see there). */
        const val INTERACTIVE_CAP = BackgroundStage.INTERACTIVE_CAP
        const val PREVIEW_CAP = BackgroundStage.PREVIEW_CAP
        const val EXPORT_CAP = BackgroundStage.EXPORT_CAP

        /**
         * Area-average resize of RGBA8 (cv2 INTER_AREA for downscaling), streamed from the bytes: no
         * float copy of the source (a 12 MP frame as four float planes was 192 MB).
         */
        fun resize(image: Rgba8Image, width: Int, height: Int): Rgba8Image {
            if (width >= image.width || height >= image.height) return resizeBilinear(image, width, height)
            val out = ByteArray(width * height * 4)
            val sx = image.width.toDouble() / width
            val sy = image.height.toDouble() / height
            val acc = DoubleArray(4)
            for (y in 0 until height) {
                val y0 = y * sy
                val y1 = (y + 1) * sy
                for (x in 0 until width) {
                    val x0 = x * sx
                    val x1 = (x + 1) * sx
                    java.util.Arrays.fill(acc, 0.0)
                    var total = 0.0
                    for (yy in y0.toInt() until minOf(kotlin.math.ceil(y1).toInt(), image.height)) {
                        val wy = minOf(yy + 1.0, y1) - maxOf(yy.toDouble(), y0)
                        if (wy <= 0) continue
                        for (xx in x0.toInt() until minOf(kotlin.math.ceil(x1).toInt(), image.width)) {
                            val wx = minOf(xx + 1.0, x1) - maxOf(xx.toDouble(), x0)
                            if (wx <= 0) continue
                            val weight = wx * wy
                            val o = (yy * image.width + xx) * 4
                            for (c in 0 until 4) acc[c] += (image.pixels[o + c].toInt() and 0xff) * weight
                            total += weight
                        }
                    }
                    for (c in 0 until 4) out[(y * width + x) * 4 + c] = (acc[c] / total + 0.5).toInt().coerceIn(0, 255).toByte()
                }
            }
            return Rgba8Image(width, height, out)
        }

        private fun resizeBilinear(image: Rgba8Image, width: Int, height: Int): Rgba8Image {
            val out = ByteArray(width * height * 4)
            val sx = image.width.toDouble() / width
            val sy = image.height.toDouble() / height
            for (y in 0 until height) for (x in 0 until width) {
                val fx = ((x + 0.5) * sx - 0.5).coerceIn(0.0, image.width - 1.0)
                val fy = ((y + 0.5) * sy - 0.5).coerceIn(0.0, image.height - 1.0)
                val x0 = fx.toInt(); val y0 = fy.toInt()
                val x1 = minOf(x0 + 1, image.width - 1); val y1 = minOf(y0 + 1, image.height - 1)
                val ax = fx - x0; val ay = fy - y0
                for (c in 0 until 4) {
                    fun at(xx: Int, yy: Int) = (image.pixels[(yy * image.width + xx) * 4 + c].toInt() and 0xff).toDouble()
                    val v = (at(x0, y0) * (1 - ax) + at(x1, y0) * ax) * (1 - ay) + (at(x0, y1) * (1 - ax) + at(x1, y1) * ax) * ay
                    out[(y * width + x) * 4 + c] = (v + 0.5).toInt().coerceIn(0, 255).toByte()
                }
            }
            return Rgba8Image(width, height, out)
        }
    }
}

/** EXIF orientation (1–8) applied to a plane stored in sensor orientation, so it lines up with the decoded photo. */
object Orientation {
    fun apply(plane: FloatPlane, orientation: Int): FloatPlane {
        val w = plane.width
        val h = plane.height
        return when (orientation) {
            2 -> FloatPlane(w, h, FloatArray(w * h) { val x = it % w; val y = it / w; plane[w - 1 - x, y] })
            3 -> FloatPlane(w, h, FloatArray(w * h) { val x = it % w; val y = it / w; plane[w - 1 - x, h - 1 - y] })
            4 -> FloatPlane(w, h, FloatArray(w * h) { val x = it % w; val y = it / w; plane[x, h - 1 - y] })
            5 -> FloatPlane(h, w, FloatArray(w * h) { val x = it % h; val y = it / h; plane[y, x] })
            6 -> FloatPlane(h, w, FloatArray(w * h) { val x = it % h; val y = it / h; plane[y, h - 1 - x] })
            7 -> FloatPlane(h, w, FloatArray(w * h) { val x = it % h; val y = it / h; plane[w - 1 - y, h - 1 - x] })
            8 -> FloatPlane(h, w, FloatArray(w * h) { val x = it % h; val y = it / h; plane[w - 1 - y, x] })
            else -> plane
        }
    }
}
