package com.lightlylabs.lightly.editor.enhance

import android.content.Context
import android.graphics.Bitmap
import com.lightlylabs.lightly.editor.ModelResources
import com.lightlylabs.lightly.editor.enhance.EnhanceMaths.Detection
import com.lightlylabs.lightly.editor.enhance.EnhanceMaths.Image
import com.lightlylabs.lightly.editor.enhance.EnhanceMaths.floatBuffer
import com.lightlylabs.lightly.editor.enhance.EnhanceMaths.floats
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.GpuDelegate
import org.tensorflow.lite.gpu.GpuDelegateFactory
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.round
import kotlin.math.sin

/**
 * Enhance (1.3, docs/roadmap.md): a photo at twice its size, with small and soft faces restored. The pipeline measured
 * in experiments/enhance-2026-11-12 (README steps 2a-2g; phone_pipeline.py's docstring lists the steps), moved from the
 * harness that ran it on the review phones (phone/EnhancePipeline.kt):
 *
 *  1. painting check (art classifier): paintings keep their faces as painted, only the background upscale runs;
 *  2. faces: RetinaFace MobileNet-0.25 at short side 640 and 960, eye gap >= 5 px;
 *  3. faces with a detector eye gap under 8 px are left to the background upscale (step 2g, owner 2026-11-16);
 *  4. face points from Face Mesh (the app's vision model), else the detector's five;
 *  5. background: realesr-general-x4v3 on 384 px tiles with >= 16 px context on the GPU delegate, 4x averaged to 2x;
 *  6. faces: CodeFormer w 0.8 split in three (step 1d: encoder and decoder on the GPU delegate, the transformer on the
 *     CPU), the original colour put back, a face-skin paste mask (the app's selfie multiclass model).
 *
 * Edit › Enhance (owner-approved design 2026-11-18) runs it from EditorViewModel.enhancePhoto. Photos longer than 2000 px are shrunk to that long side first (owner, 2026-11-17), which
 * bounds memory: the 2x float image alone is 48 bytes per working pixel (2000 x 1500: 144 MB).
 * Models: assets/enhance in every build. Debug and benchmark builds carry them in the app module; release bundles in the
 * :enhance-models Play install-time asset pack, whose assets join the app's (enabled with the screen: Enhance gate in
 * app/build.gradle.kts).
 *
 * Not thread-safe: one photo at a time per engine ([enhance] is synchronized). [close] frees the interpreters and
 * GPU delegates.
 */
class EnhanceEngine private constructor(
    private val art: Interpreter,
    private val detectors: Map<Int, Interpreter>,
    private val mesh: Interpreter,
    private val multiclass: Interpreter,
    private val upscaler: Interpreter,
    private val encoder: Interpreter,
    private val middle: Interpreter,
    private val decoder: Interpreter,
    private val delegates: List<GpuDelegate>,
) : AutoCloseable {

    sealed class Failure(message: String) : Exception(message) {
        /** A model is not in this build. */
        class ModelUnavailable(name: String) : Failure("Enhance model $name is not in this build")
        class ModelFailed(detail: String) : Failure(detail)
        class Cancelled : Failure("Enhance cancelled")
    }

    enum class PointSource { FACE_MESH, DETECTOR }

    class Face(
        /** Detector box in input pixels: x0, y0, x1, y1. */
        val box: DoubleArray,
        val eyeGap: Double,
        /** False for a face under [RESTORE_EYE_GAP_MIN], left to the background upscale. */
        val restored: Boolean,
        /** Where the alignment points came from; null for a face that is not restored. */
        val pointSource: PointSource?,
        /** The five alignment points (eyes, nose tip, mouth corners) in input pixels; empty when not restored. */
        val points: List<DoubleArray>,
    )

    class Result(
        /** 2x the input (2x the 2000 px cap for larger photos), ARGB_8888, opaque. */
        val image: Bitmap,
        val isPainting: Boolean,
        val faces: List<Face>,
    )

    /**
     * Enhances [photo] (already upright). [isCancelled] is polled between model runs; a cancelled run throws.
     * [progress] gets the share of the work done, 0..1, for the panel's bar (approved `ed-enhancing`); it never changes
     * the maths.
     */
    @Synchronized
    fun enhance(photo: Bitmap, isCancelled: () -> Boolean = { false }, progress: (Double) -> Unit = {}): Result {
        val (image, isPainting, faces) = enhance(floatRgb(photo), isCancelled, progress)
        return Result(bitmap(image), isPainting, faces)
    }

    internal fun enhance(photo: Image, isCancelled: () -> Boolean, progress: (Double) -> Unit = {}): Triple<Image, Boolean, List<Face>> {
        fun checkpoint() { if (isCancelled()) throw Failure.Cancelled() }
        val (width, height) = EnhanceMaths.inputSize(photo.w, photo.h, INPUT_LONG_SIDE_MAX)
        // Same antialiased resize as every other step (phone_pipeline.resize), kept in floats.
        val rgb = if (width == photo.w && height == photo.h) photo else EnhanceMaths.resize(photo, width, height)
        val isPainting = artProbability(rgb) >= ART_THRESHOLD
        checkpoint()
        val faces = mutableListOf<Face>()
        val restoreFives = mutableListOf<Array<DoubleArray>>()
        if (!isPainting) {
            for (detection in detectFaces(rgb)) {
                checkpoint()
                val gap = hypot(detection.five[0][0] - detection.five[1][0], detection.five[0][1] - detection.five[1][1])
                if (gap < RESTORE_EYE_GAP_MIN) {
                    faces += Face(detection.box, gap, false, null, emptyList())
                    continue
                }
                val (five, source) = meshFive(rgb, detection)
                if (!canAlign(five)) {
                    faces += Face(detection.box, gap, false, null, emptyList())
                    continue
                }
                faces += Face(detection.box, gap, true, source, five.toList())
                restoreFives += five
            }
        }
        checkpoint()
        progress(PROGRESS_BEFORE_UPSCALE)
        val tiles = EnhanceMaths.tileWindows(rgb.h, TILE, TILE_PAD).size * EnhanceMaths.tileWindows(rgb.w, TILE, TILE_PAD).size
        val steps = maxOf(tiles + restoreFives.size, 1).toDouble()
        var done = 0
        val stepDone = {
            done += 1
            progress(PROGRESS_BEFORE_UPSCALE + (1 - PROGRESS_BEFORE_UPSCALE) * done / steps)
        }
        val image = upscaleBackground(rgb, ::checkpoint, stepDone)
        val grey = EnhanceMaths.isGrey(rgb)
        for (five in restoreFives) {
            checkpoint()
            restoreFace(five, rgb, grey, image)
            stepDone()
        }
        return Triple(image, isPainting, faces)
    }

    override fun close() {
        (listOf(art, mesh, multiclass, upscaler, encoder, middle, decoder) + detectors.values).forEach { it.close() }
        delegates.forEach { it.close() }
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Steps

    private fun detectFaces(rgb: Image): List<Detection> {
        val found = detect(rgb, 640)
        val extra = detect(rgb, 960).filter { d -> found.all { EnhanceMaths.iou(d.box, it.box) < EXTRA_IOU } }
        // v3 differs: detections with a non-finite box or point are dropped (the harness had no such check).
        return (found + extra).filter { d -> d.box.all { it.isFinite() } && d.five.all { p -> p.all { it.isFinite() } } }
    }

    private fun restoreFace(five: Array<DoubleArray>, rgb: Image, grey: Boolean, image: Image) {
        val toFace = EnhanceMaths.similarity(five, FACE_TEMPLATE)
        val crop = EnhanceMaths.warpBilinear(rgb, EnhanceMaths.invertAffine(toFace), 512, 512, CROP_BORDER_RGB)
        var restored = EnhanceMaths.originalColour(restore(crop), crop)
        if (grey) restored = EnhanceMaths.greyLike(restored, crop)
        val mask = faceMask(restored)
        EnhanceMaths.pasteFace(image, restored, mask, toFace)
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Models

    private fun run(model: Interpreter, input: ByteBuffer, output: ByteBuffer) {
        try { model.run(input.rewind(), output) } catch (failure: RuntimeException) { throw Failure.ModelFailed(failure.toString()) }
    }

    private fun artProbability(rgb: Image): Double {
        val views = EnhanceMaths.fiveViews(rgb)
        val input = floatBuffer(5 * 3 * 224 * 224)
        for (view in views) for (c in 0 until 3) for (i in 0 until 224 * 224) input.putFloat(view.d[i * 3 + c] / 255f)
        val output = floatBuffer(1)
        run(art, input, output)
        return output.getFloat(0).toDouble()
    }

    private fun detect(rgb: Image, short: Int): List<Detection> {
        val canvas = DETECTION_SIZES.getValue(short)
        val model = detectors.getValue(short)
        val scale = EnhanceMaths.detectionScale(rgb.w, rgb.h, short, canvas)
        val nw = (rgb.w * scale).toInt()
        val nh = (rgb.h * scale).toInt()
        val small = EnhanceMaths.resize(rgb, nw, nh)
        val input = floatBuffer(3 * canvas * canvas)
        for (c in 0 until 3) for (y in 0 until canvas) for (x in 0 until canvas) {
            val value = if (x < nw && y < nh) small.d[(y * nw + x) * 3 + c] else DETECTOR_MEAN_RGB[c]
            input.putFloat(value / 255f)
        }
        // Outputs picked by shape: loc [1, N, 4], score [1, N], landmarks [1, N, 10].
        val outputs = (0 until model.outputTensorCount).associateWith { floatBuffer(model.getOutputTensor(it).numElements()) }
        try {
            model.runForMultipleInputsOutputs(arrayOf(input.rewind()), outputs.mapValues { it.value as Any })
        } catch (failure: RuntimeException) { throw Failure.ModelFailed(failure.toString()) }
        fun byShape(test: (IntArray) -> Boolean) =
            outputs.getValue((0 until model.outputTensorCount).first { test(model.getOutputTensor(it).shape()) }).floats()
        val loc = byShape { it.size == 3 && it[2] == 4 }
        val landmarks = byShape { it.size == 3 && it[2] == 10 }
        val score = byShape { it.size == 2 }
        return EnhanceMaths.decodeDetections(loc, score, landmarks, EnhanceMaths.priors(canvas), scale)
    }

    private fun meshRun(rgb: Image, cx: Double, cy: Double, side: Double, roll: Double): Pair<Array<DoubleArray>, Double> {
        val k = side / 256
        val c = cos(roll)
        val s = sin(roll)
        val toPhoto = doubleArrayOf(k * c, -k * s, cx - k * (c * 128 - s * 128), k * s, k * c, cy - k * (s * 128 + c * 128))
        val crop = EnhanceMaths.warpBilinear(rgb, toPhoto, 256, 256, floatArrayOf(0f, 0f, 0f))
        val input = floatBuffer(256 * 256 * 3)
        for (v in crop.d) input.putFloat(v / 255f)
        val outputs = (0 until mesh.outputTensorCount).associateWith { floatBuffer(mesh.getOutputTensor(it).numElements()) }
        try {
            mesh.runForMultipleInputsOutputs(arrayOf(input.rewind()), outputs.mapValues { it.value as Any })
        } catch (failure: RuntimeException) { throw Failure.ModelFailed(failure.toString()) }
        val raw = outputs.values.first { it.capacity() == 1434 * 4 }.floats()
        val presence = outputs.values.first { it.capacity() == 4 }.floats()[0].toDouble()
        val points = Array(478) { i ->
            val u = raw[i * 3].toDouble()
            val v = raw[i * 3 + 1].toDouble()
            doubleArrayOf(toPhoto[0] * u + toPhoto[1] * v + toPhoto[2], toPhoto[3] * u + toPhoto[4] * v + toPhoto[5])
        }
        return points to 1 / (1 + exp(-presence))
    }

    /**
     * Face Mesh on a crop rolled to the detector's eye line, refined once on its own points; its iris centres, nose tip
     * and mouth corners when its face presence is >= 0.5, else the detector's five points (steps 2c, 2f).
     */
    private fun meshFive(rgb: Image, detection: Detection): Pair<Array<DoubleArray>, PointSource> {
        val b = detection.box
        val five = detection.five
        var (points, presence) = meshRun(rgb, (b[0] + b[2]) / 2, (b[1] + b[3]) / 2,
            max(b[2] - b[0], b[3] - b[1]) * 1.5, atan2(five[1][1] - five[0][1], five[1][0] - five[0][0]))
        // v3 differs: the harness had no finite checks. A non-finite mesh output would make the refining crop and the
        // alignment NaN; the detector's points are the pipeline's own fallback (the iOS simulator gave such output).
        if (!presence.isFinite() || points.any { p -> !p[0].isFinite() || !p[1].isFinite() }) return five to PointSource.DETECTOR
        val lineX = points[263][0] - points[33][0]
        val lineY = points[263][1] - points[33][1]
        var loX = Double.MAX_VALUE; var loY = Double.MAX_VALUE; var hiX = -Double.MAX_VALUE; var hiY = -Double.MAX_VALUE
        for (i in 0 until 468) {
            loX = min(loX, points[i][0]); hiX = max(hiX, points[i][0]); loY = min(loY, points[i][1]); hiY = max(hiY, points[i][1])
        }
        val (refined, refinedPresence) = meshRun(rgb, (loX + hiX) / 2, (loY + hiY) / 2,
            max(hiX - loX, hiY - loY) * 1.5, atan2(lineY, lineX))
        if (refinedPresence >= presence - 0.1) { points = refined; presence = refinedPresence }
        val meshPoints = Array(5) { points[MESH_FIVE[it]] }
        val usable = presence.isFinite() && presence >= MESH_PRESENCE_MIN && canAlign(meshPoints)
        return if (usable) meshPoints to PointSource.FACE_MESH else five to PointSource.DETECTOR
    }

    private fun signatureOutputs(model: Interpreter): Map<String, ByteBuffer> =
        model.getSignatureOutputs("serving_default").associateWith { name ->
            ByteBuffer.allocateDirect(model.getOutputTensorFromSignature(name, "serving_default").numBytes()).order(ByteOrder.nativeOrder())
        }

    private val encoded by lazy { signatureOutputs(encoder) }
    private val quantised by lazy { signatureOutputs(middle) }
    private val decoded by lazy { signatureOutputs(decoder) }

    /** 512 x 512 RGB face in 0-255 -> restored face in 0-255 (CodeFormer's [-1, 1] range, clamped). */
    private fun restore(face: Image): Image {
        val input = floatBuffer(3 * 512 * 512)
        for (c in 0 until 3) for (i in 0 until 512 * 512) input.putFloat(face.d[i * 3 + c] / 127.5f - 1f)
        (encoded.values + quantised.values + decoded.values).forEach { it.clear() }
        try {
            encoder.runSignature(mapOf("args_0" to input.rewind()), encoded)
            middle.runSignature(mapOf("args_0" to encoded.getValue("output_0").rewind()), quantised)
            val decoderInputs = mutableMapOf<String, Any>("args_0" to quantised.getValue("output_0").rewind())
            for (skip in 1..4) decoderInputs["args_$skip"] = encoded.getValue("output_$skip").rewind()
            decoder.runSignature(decoderInputs, decoded)
        } catch (failure: RuntimeException) { throw Failure.ModelFailed(failure.toString()) }
        val values = decoded.getValue("output_0").floats()
        // A non-finite face would paste NaN into the photo; fail the run instead (the caller shows its failure state).
        if (values.any { !it.isFinite() }) throw Failure.ModelFailed("CodeFormer gave non-finite values")
        val out = Image(512, 512, 3)
        for (c in 0 until 3) for (i in 0 until 512 * 512) {
            out.d[i * 3 + c] = (values[c * 512 * 512 + i].coerceIn(-1f, 1f) + 1f) * 127.5f
        }
        return out
    }

    /** general-x4v3 on 384 px windows laid out by tileWindows; the 4x result is averaged 2 x 2 to 2x. */
    private fun upscaleBackground(rgb: Image, checkpoint: () -> Unit, tileDone: () -> Unit = {}): Image {
        val out = Image(rgb.w * SCALE, rgb.h * SCALE, 3)
        val input = floatBuffer(3 * TILE * TILE)
        val output = floatBuffer(3 * TILE * 4 * TILE * 4)
        val up = 4 * TILE
        for ((y, ch, wy) in EnhanceMaths.tileWindows(rgb.h, TILE, TILE_PAD)) for ((x, cw, wx) in EnhanceMaths.tileWindows(rgb.w, TILE, TILE_PAD)) {
            checkpoint()
            input.clear()
            // Mirrored reads only matter for a photo side under a tile; otherwise mirrorIndex is the identity.
            val rows = IntArray(TILE) { EnhanceMaths.mirrorIndex(wy + it, rgb.h) }
            val columns = IntArray(TILE) { EnhanceMaths.mirrorIndex(wx + it, rgb.w) }
            for (c in 0 until 3) for (ty in 0 until TILE) for (tx in 0 until TILE) {
                input.putFloat(rgb.d[(rows[ty] * rgb.w + columns[tx]) * 3 + c] / 255f)
            }
            output.clear()
            run(upscaler, input, output)
            val values = output.floats()
            val ox = (x - wx) * 4
            val oy = (y - wy) * 4
            for (c in 0 until 3) for (yy in 0 until ch * 2) for (xx in 0 until cw * 2) {
                var sum = 0f
                for (dy in 0 until 2) for (dx in 0 until 2) {
                    sum += values[(c * up + oy + yy * 2 + dy) * up + ox + xx * 2 + dx].coerceIn(0f, 1f)
                }
                out.d[((y * 2 + yy) * out.w + x * 2 + xx) * 3 + c] = sum / 4f * 255f
            }
            tileDone()
        }
        return out
    }

    private fun faceMask(restored: Image): FloatArray {
        val clipped = Image(512, 512, 3).also { for (i in it.d.indices) it.d[i] = restored.d[i].coerceIn(0f, 255f) }
        val small = EnhanceMaths.resize(clipped, 256, 256)
        val input = floatBuffer(256 * 256 * 3)
        for (v in small.d) input.putFloat(v / 255f)
        val output = floatBuffer(256 * 256 * 6)
        run(multiclass, input, output)
        val logits = output.floats()
        val face = BooleanArray(256 * 256) { i ->
            var best = 0
            for (c in 1 until 6) if (logits[i * 6 + c] > logits[i * 6 + best]) best = c
            best == FACE_SKIN
        }
        val filled = EnhanceMaths.fillHoles(face, 256, 256)
        val plane = Image(256, 256, 1).also { for (i in filled.indices) it.d[i] = if (filled[i]) 255f else 0f }
        var mask = EnhanceMaths.resize(plane, 512, 512).d
        mask = EnhanceMaths.gaussianBlur(EnhanceMaths.gaussianBlur(mask, 512, 512, 101, 11.0), 512, 512, 101, 11.0)
        for (y in 0 until 512) for (x in 0 until 512) {
            if (y < 10 || y >= 502 || x < 10 || x >= 502) mask[y * 512 + x] = 0f else mask[y * 512 + x] /= 255f
        }
        return mask
    }

    companion object {
        /** The bar's share for the painting check and face finding; the rest split evenly over tiles and restored faces. */
        const val PROGRESS_BEFORE_UPSCALE = 0.06

        const val SCALE = 2
        const val ART_THRESHOLD = 0.8
        /** Step 2g: below an 8 px eye gap CodeFormer invents the face rather than restoring it (owner, 2026-11-16). */
        const val RESTORE_EYE_GAP_MIN = 8.0
        /** Owner, 2026-11-17: photos longer than 2000 px are shrunk to that long side before enhancing (output 4000). */
        const val INPUT_LONG_SIDE_MAX = 2000
        const val TILE = 384
        const val TILE_PAD = 16
        val DETECTION_SIZES = mapOf(640 to 1024, 960 to 1536)   // short side -> square canvas
        private const val EXTRA_IOU = 0.3
        private val DETECTOR_MEAN_RGB = floatArrayOf(123f, 117f, 104f)
        private val MESH_FIVE = intArrayOf(468, 473, 1, 61, 291)
        private const val MESH_PRESENCE_MIN = 0.5
        private const val FACE_SKIN = 3
        private val FACE_TEMPLATE = arrayOf(
            doubleArrayOf(192.98138, 239.94708), doubleArrayOf(318.90277, 240.1936), doubleArrayOf(256.63416, 314.01935),
            doubleArrayOf(201.26117, 371.41043), doubleArrayOf(313.08905, 371.15118),
        )
        private val CROP_BORDER_RGB = floatArrayOf(132f, 133f, 135f)   // CodeFormer's (135, 133, 132) in BGR

        /** Assets the engine needs: its own under assets/enhance, Face Mesh and the multiclass model under assets/vision. */
        val ENHANCE_ASSETS = listOf(
            "art-classifier.tflite", "face-detector-640.tflite", "face-detector-960.tflite", "general-x4v3-384.tflite",
            "codeformer-encoder.tflite", "codeformer-middle.tflite", "codeformer-decoder.tflite",
        )
        private const val MESH_ASSET = "vision/face_landmarks_detector.tflite"
        private const val MULTICLASS_ASSET = "vision/selfie_multiclass_256x256.tflite"

        /** True when every model is in this build, without loading them. */
        fun isAvailable(context: Context): Boolean = missingAsset(context) == null

        private fun missingAsset(context: Context): String? {
            val enhance = context.assets.list("enhance").orEmpty().toSet()
            val vision = context.assets.list("vision").orEmpty().toSet()
            return ENHANCE_ASSETS.firstOrNull { it !in enhance }
                ?: listOf(MESH_ASSET, MULTICLASS_ASSET).firstOrNull { it.removePrefix("vision/") !in vision }
        }

        /**
         * Loads every model. Small models on XNNPACK (4 threads); general-x4v3 and CodeFormer's encoder and decoder on
         * the GPU delegate (fp16, kernel cache in filesDir/enhance-gpu-cache, keyed by model and version), as measured
         * in steps 1c-1f. The emulator has no usable GPU delegate and dies in XNNPACK's initialisation on Apple-silicon
         * hosts (LiteRtVisionModels), so there everything runs on LiteRT's built-in CPU kernels.
         */
        fun load(context: Context): EnhanceEngine {
            missingAsset(context)?.let { throw Failure.ModelUnavailable(it) }
            val emulator = android.os.Build.HARDWARE in setOf("ranchu", "goldfish")
            val cacheFolder = File(context.filesDir, "enhance-gpu-cache").apply { mkdirs() }
            val delegates = mutableListOf<GpuDelegate>()
            fun map(path: String) = ModelResources.mapAsset(context, path)
            fun cpu(path: String) = Interpreter(map(path), Interpreter.Options().setNumThreads(4).setUseXNNPACK(!emulator))
            fun gpu(path: String, token: String): Interpreter {
                if (emulator) return cpu(path)
                val delegate = GpuDelegate(
                    GpuDelegateFactory.Options().setPrecisionLossAllowed(true)
                        // Token names the model, its version and precision: never reuse kernels across them.
                        .setSerializationParams(cacheFolder.absolutePath, token),
                )
                delegates += delegate
                return Interpreter(map(path), Interpreter.Options().addDelegate(delegate))
            }
            val opened = mutableListOf<Interpreter>()
            fun <T : Interpreter> keep(interpreter: T) = interpreter.also { opened += it }
            try {
                return EnhanceEngine(
                    art = keep(cpu("enhance/art-classifier.tflite")),
                    detectors = DETECTION_SIZES.keys.associateWith { keep(cpu("enhance/face-detector-$it.tflite")) },
                    mesh = keep(cpu(MESH_ASSET)),
                    multiclass = keep(cpu(MULTICLASS_ASSET)),
                    upscaler = keep(gpu("enhance/general-x4v3-$TILE.tflite", "general-x4v3-$TILE-v1-fp16")),
                    encoder = keep(gpu("enhance/codeformer-encoder.tflite", "codeformer-encoder-v1-fp16")),
                    middle = keep(cpu("enhance/codeformer-middle.tflite")),
                    decoder = keep(gpu("enhance/codeformer-decoder.tflite", "codeformer-decoder-v1-fp16")),
                    delegates = delegates,
                )
            } catch (failure: Exception) {
                opened.forEach { it.close() }
                delegates.forEach { it.close() }
                throw if (failure is Failure) failure else Failure.ModelFailed(failure.toString())
            }
        }

        /** True when the five points give a usable similarity onto the template (finite, eyes apart, not mirrored). */
        internal fun canAlign(five: Array<DoubleArray>): Boolean {
            if (five.any { p -> !p[0].isFinite() || !p[1].isFinite() }) return false
            // Collapsed points (all at one spot) still solve to finite garbage; the eyes must be apart.
            if (hypot(five[1][0] - five[0][0], five[1][1] - five[0][1]) < 1.0) return false
            val m = EnhanceMaths.similarity(five, FACE_TEMPLATE)
            return m.all { it.isFinite() } && m[0] * m[4] - m[1] * m[3] > 0
        }

        /** 8-bit sRGB pixels as floats 0-255 (the bitmap converted to ARGB_8888 first when it is not). */
        internal fun floatRgb(photo: Bitmap): Image {
            val source = if (photo.config == Bitmap.Config.ARGB_8888) photo else photo.copy(Bitmap.Config.ARGB_8888, false)
            val w = source.width
            val h = source.height
            val pixels = IntArray(w * h)
            source.getPixels(pixels, 0, w, 0, 0, w, h)
            if (source !== photo) source.recycle()
            val image = Image(w, h, 3)
            for (i in pixels.indices) {
                image.d[i * 3] = ((pixels[i] shr 16) and 0xFF).toFloat()
                image.d[i * 3 + 1] = ((pixels[i] shr 8) and 0xFF).toFloat()
                image.d[i * 3 + 2] = (pixels[i] and 0xFF).toFloat()
            }
            return image
        }

        /** Rounded and clipped to 8 bits, opaque ARGB_8888. */
        internal fun bitmap(image: Image): Bitmap {
            val pixels = IntArray(image.w * image.h) { i ->
                fun byte(c: Int) = round(image.d[i * 3 + c].coerceIn(0f, 255f)).toInt()
                (0xFF shl 24) or (byte(0) shl 16) or (byte(1) shl 8) or byte(2)
            }
            return Bitmap.createBitmap(pixels, image.w, image.h, Bitmap.Config.ARGB_8888)
        }
    }
}
