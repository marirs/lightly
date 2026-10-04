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
import java.security.MessageDigest

/**
 * Depth and the subject matte for one photo, and the conversion of the recipe's background section
 * into a [BackgroundPlan] (rendering-v2 stages background.replace and background.focus).
 * Analysis runs once per photo, at the display proxy's resolution.
 */
class BackgroundSession(private val env: EditorEnvironment) {
    @Volatile var analysis: BackgroundAnalysis? = null
        private set
    var noClearSubject = false
        private set

    /** Which model made the depth map, for the recipe's derivedRef. */
    private var depthModel: ModelRef? = null
    private var matteModel: ModelRef? = null

    /** Replacement photos decoded at the analysis size, by AssetRef. */
    private val replacementPhotos = mutableMapOf<AssetRef, Rgba8Image>()

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
        replacementPhotos.clear()
    }

    fun rememberReplacementPhoto(asset: AssetRef, image: Rgba8Image) { replacementPhotos[asset] = image }

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
        val matte = a.matte
        val scene = com.lightlylabs.lightly.background.Refocus.buildScene(
            FloatImage(a.width, a.height, 3), nearness, matte,
        )
        return com.lightlylabs.lightly.background.Refocus.focalNearness(scene, x, y)
    }

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
    fun planFor(tool: BackgroundTool, developPlan: DevelopRenderPlan, renderer: DevelopRenderer, maxBlurFraction: Double = com.lightlylabs.lightly.background.Refocus.FocusConstants.MAX_BLUR_FRACTION_OF_LONG_EDGE): BackgroundPlan? {
        val a = refined(tool) ?: return null
        val focus = tool.focus
        val blur = if (a.depth == null) 0.0 else focus.blur
        val replacement = tool.replacement?.takeIf { a.matte != null }?.let { r -> replacementImage(r, a.width, a.height, developPlan, renderer) }
        if (replacement == null && blur <= 0.0) return null
        val focal = focus.depth.focusDepth?.let { 1.0 - it }
            ?: focus.target?.let { focalNearnessAt(it.x, it.y) }
            ?: defaultTarget().let { (x, y) -> focalNearnessAt(x, y) } ?: 0.5
        // Revision 1 (G4): a stored focusDepth is used as d_f = 1 − focusDepth and never re-resolved.
        // replacementDepth is not read (G6): placement is §R2.4 "plane".
        return BackgroundPlan(replacement, FocusParams(blur, focus.depthOfField, focus.style.name.lowercase(), focus.bokeh.name.lowercase(), focus.styleAmount, maxBlurFraction), focal,
            focusTarget = focus.target?.let { it.x to it.y })
    }

    private fun replacementImage(r: Replacement, w: Int, h: Int, developPlan: DevelopRenderPlan, renderer: DevelopRenderer): FloatImage? {
        val srgb = when (r) {
            is Replacement.Colour -> ReplacementImage.colour(w, h, r.colour)
            is Replacement.Gradient -> ReplacementImage.gradient(w, h, r.angle, r.stops.map { it.colour to it.position })
            is Replacement.Image -> {
                val photo = replacementPhotos[r.image] ?: (r.image as? AssetRef.Bundled)?.let { env.bundledBackground(it.id) }?.also { replacementPhotos[r.image] = it } ?: return null
                ReplacementImage.photo(FloatImage(photo.width, photo.height, 3, FloatArray(photo.pixelCount * 3) { (photo.pixels[(it / 3) * 4 + it % 3].toInt() and 0xff) / 255f }), w, h, r.scale, r.x, r.y)
            }
        }
        // The replacement receives the photo's global colour (Auto, develop.global at Amount); no spatial operator.
        val bytes = ByteArray(w * h * 4) { i -> if (i % 4 == 3) -1 else (srgb.data[(i / 4) * 3 + i % 4] * 255f + 0.5f).toInt().coerceIn(0, 255).toByte() }
        val graded = renderer.render(Rgba8Image(w, h, bytes), developPlan.globalOnly())
        return FloatImage(w, h, 3, FloatArray(w * h * 3) { (graded.pixels[(it / 3) * 4 + it % 3].toInt() and 0xff) / 255f })
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

    /** Background stage on a developed frame at the analysis size. */
    fun render(developed: Rgba8Image, plan: BackgroundPlan, layersPerSide: Int, tool: BackgroundTool): Pair<Rgba8Image, FloatPlane> {
        val a = refined(tool)!!
        val frame = if (developed.width == a.width && developed.height == a.height) developed else resize(developed, a.width, a.height)
        val (bytes, defocus) = BackgroundStage.render(frame.pixels, a, plan, layersPerSide)
        return Rgba8Image(a.width, a.height, bytes) to defocus
    }

    private fun digest(plane: FloatPlane): String {
        val buffer = ByteBuffer.allocate(plane.values.size * 4)
        plane.values.forEach { buffer.putFloat(it) }
        return MessageDigest.getInstance("SHA-256").digest(buffer.array()).joinToString("") { "%02x".format(it) }
    }

    companion object {
        /** Area-average resize of RGBA8 (used to bring a full frame to the analysis size for Save copy). */
        fun resize(image: Rgba8Image, width: Int, height: Int): Rgba8Image {
            val planes = (0 until 4).map { c ->
                DepthModelInput.resizeArea(FloatPlane(image.width, image.height, FloatArray(image.pixelCount) { (image.pixels[it * 4 + c].toInt() and 0xff).toFloat() }), width, height)
            }
            return Rgba8Image(width, height, ByteArray(width * height * 4) { i -> planes[i % 4].values[i / 4].toInt().coerceIn(0, 255).toByte() })
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
