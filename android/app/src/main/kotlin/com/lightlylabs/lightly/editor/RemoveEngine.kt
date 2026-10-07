package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.DerivedRef
import com.lightlylabs.lightly.session.ModelRef
import java.security.MessageDigest
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * The inpainting model behind Edit › Remove: a 512 × 512 RGB crop (CHW, 0…1) and its hole mask (1 =
 * remove) in, the filled crop out. One engine for every stroke (docs/v1/remove-evaluation.md §7):
 * LaMa big-lama. There is no classical fill and nothing is ever swapped in silently.
 */
interface Inpainter {
    val model: ModelRef

    /** @throws RemoveUnavailableException when the model cannot run; any other failure is a failed stroke. */
    fun inpaint(image: FloatArray, mask: FloatArray): FloatArray
}

class RemoveUnavailableException(message: String) : Exception(message)

/**
 * The inpainted area of one stroke at the full-resolution source: a rect, RGB plus feathered alpha
 * (1 inside the brush, ramping to 0 within [RemoveEngine.FEATHER_PX] outside it), and the source size
 * it was computed at. Preview composites it scaled, export composites it 1:1, so both show the same
 * fill (remove-evaluation §7, "same result for preview and export").
 */
class RemovePatch(val x: Int, val y: Int, val width: Int, val height: Int, val rgba: ByteArray, val sourceWidth: Int, val sourceHeight: Int) {
    val sha256: String by lazy {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update("$x,$y,$width,$height,$sourceWidth,$sourceHeight;".toByteArray())
        digest.update(rgba)
        digest.digest().joinToString("") { "%02x".format(it) }
    }

    fun derivedRef(model: ModelRef) = DerivedRef(sha256, model, width, height)
}

/**
 * The session's patches by digest (recipe `remove.strokes[].result.patch`, a `derivedRef`: "a cached result
 * of an on-device model, stored beside the edit by digest"). Undo and redo replay a stored patch and never
 * re-run the model.
 *
 * With a [directory], every patch is also written there (`<sha256>.patch`, atomically), so a session
 * restored after the process was killed renders the same fills: a patch missing from memory is read from
 * disk and its digest checked. A patch that is missing or fails the check is skipped, and the stroke
 * renders without it; it is never recomputed silently (edit-recipe-v1 `derivedRef`).
 */
// v3 differs from iOS (RemovePatchStore in memory only, bc71828): iOS loses a stroke's fill when the app
// is killed and recovered; this store keeps it, as the recipe's derivedRef semantics require.
class RemovePatchStore(private val directory: java.io.File? = null) {
    private val patches = java.util.concurrent.ConcurrentHashMap<String, RemovePatch>()

    fun put(patch: RemovePatch) {
        patches[patch.sha256] = patch
        directory?.let { dir -> runCatching { write(dir, patch) } }
    }

    operator fun get(sha256: String): RemovePatch? = patches[sha256] ?: directory?.let { dir ->
        runCatching { read(java.io.File(dir, "$sha256$SUFFIX")) }.getOrNull()?.takeIf { it.sha256 == sha256 }?.also { patches[sha256] = it }
    }

    /** Forgets the patches in memory (another photo is loading); the files stay for a restore. */
    fun clearMemory() = patches.clear()

    /** Deletes every stored patch: a new photo was chosen, so no recovery can name them again. */
    fun clearAll() {
        patches.clear()
        directory?.listFiles { file -> file.name.endsWith(SUFFIX) }?.forEach { it.delete() }
    }

    private fun write(dir: java.io.File, patch: RemovePatch) {
        dir.mkdirs()
        val target = java.io.File(dir, "${patch.sha256}$SUFFIX")
        if (target.isFile) return
        val temporary = java.io.File(dir, "${patch.sha256}.tmp")
        java.io.DataOutputStream(java.io.BufferedOutputStream(java.io.FileOutputStream(temporary))).use { out ->
            out.writeInt(MAGIC)
            listOf(patch.x, patch.y, patch.width, patch.height, patch.sourceWidth, patch.sourceHeight).forEach(out::writeInt)
            out.write(patch.rgba)
        }
        if (!temporary.renameTo(target)) temporary.delete()
    }

    private fun read(file: java.io.File): RemovePatch? {
        if (!file.isFile) return null
        java.io.DataInputStream(java.io.BufferedInputStream(java.io.FileInputStream(file))).use { input ->
            if (input.readInt() != MAGIC) return null
            val values = IntArray(6) { input.readInt() }
            val (x, y, w, h) = values
            require(w in 1..MAX_SIDE && h in 1..MAX_SIDE && values[4] > 0 && values[5] > 0) { "bad patch header" }
            val rgba = ByteArray(w * h * 4)
            input.readFully(rgba)
            return RemovePatch(x, y, w, h, rgba, values[4], values[5])
        }
    }

    companion object {
        private const val SUFFIX = ".patch"
        private const val MAGIC = 0x4C525031 // "LRP1"
        private const val MAX_SIDE = 1 shl 15
    }
}

/**
 * Remove's pipeline (remove-evaluation §4, `inpaint_lib.remove_with_paste_back`), on the full-resolution
 * source with the earlier strokes' patches already composited:
 * 1. rasterise the stroke (a capsule chain of the brush radius) and its 3 px feather band;
 * 2. a square context window of 2.2 × the stroke's extent, at least 512, clamped to the photo;
 * 3. a window of 512 is fed natively; a larger one is resized to 512 and the fill resized back
 *    (the mask is grown by half a model pixel so no edge survives the resample);
 * 4. only the brush and its feather are kept: the patch.
 */
// DEFERRED(remove-tiled-route): remove-evaluation's tiled-native route for long thin strokes is not
// ported; such strokes take the downscaled route through the same engine (as on iOS).
object RemoveEngine {
    const val MODEL_SIDE = 512
    const val CONTEXT_FACTOR = 2.2
    const val FEATHER_PX = 3.0

    /** [points] are normalised source coordinates; [radius] a fraction of the source long edge. */
    fun patch(source: Rgba8Image, points: List<Pair<Double, Double>>, radius: Double, inpainter: Inpainter, cancelled: () -> Boolean = { false }): RemovePatch {
        require(points.isNotEmpty()) { "a stroke needs a point" }
        val w = source.width
        val h = source.height
        val brush = max(1.0, radius * max(w, h))
        val pixelPoints = points.map { (x, y) -> x * w to y * h }
        // Stroke bounds (brush) and patch bounds (brush + feather).
        val minX = pixelPoints.minOf { it.first } - brush
        val maxX = pixelPoints.maxOf { it.first } + brush
        val minY = pixelPoints.minOf { it.second } - brush
        val maxY = pixelPoints.maxOf { it.second } + brush
        val px0 = floor(minX - FEATHER_PX).toInt().coerceIn(0, w - 1)
        val py0 = floor(minY - FEATHER_PX).toInt().coerceIn(0, h - 1)
        val px1 = ceil(maxX + FEATHER_PX).toInt().coerceIn(px0 + 1, w)
        val py1 = ceil(maxY + FEATHER_PX).toInt().coerceIn(py0 + 1, h)

        // Context window, as inpaint_lib.context_window.
        val extent = max(maxX - minX, maxY - minY)
        val side = min(max(ceil(extent * CONTEXT_FACTOR).toInt(), MODEL_SIDE), min(w, h))
        val centreX = (minX + maxX) / 2
        val centreY = (minY + maxY) / 2
        val left = (centreX - side / 2.0).coerceIn(0.0, (w - side).toDouble()).roundToInt()
        val top = (centreY - side / 2.0).coerceIn(0.0, (h - side).toDouble()).roundToInt()
        val scale = side.toDouble() / MODEL_SIDE // source pixels per model pixel

        // Model input: the window resampled to 512 (identity when side == 512), and the grown hole.
        val n = MODEL_SIDE * MODEL_SIDE
        val image = FloatArray(3 * n)
        val mask = FloatArray(n)
        val grow = if (side == MODEL_SIDE) 0.0 else scale / 2
        for (my in 0 until MODEL_SIDE) for (mx in 0 until MODEL_SIDE) {
            val sx = left + (mx + 0.5) * scale
            val sy = top + (my + 0.5) * scale
            val i = my * MODEL_SIDE + mx
            sampleRgb(source, sx - 0.5, sy - 0.5) { c, v -> image[c * n + i] = v / 255f }
            mask[i] = if (distanceToStroke(sx, sy, pixelPoints) <= brush + grow) 1f else 0f
        }
        if (cancelled()) throw kotlinx.coroutines.CancellationException("Remove cancelled")
        val filled = inpainter.inpaint(image, mask)
        require(filled.size == 3 * n) { "inpainter returned ${filled.size} values" }
        if (cancelled()) throw kotlinx.coroutines.CancellationException("Remove cancelled")

        // Paste back only the brush and its feather.
        val pw = px1 - px0
        val ph = py1 - py0
        val rgba = ByteArray(pw * ph * 4)
        for (row in 0 until ph) for (column in 0 until pw) {
            val x = px0 + column + 0.5
            val y = py0 + row + 0.5
            val d = distanceToStroke(x, y, pixelPoints)
            val alpha = if (d <= brush) 1.0 else (1 - (d - brush) / FEATHER_PX).coerceIn(0.0, 1.0)
            val o = (row * pw + column) * 4
            if (alpha > 0) {
                // The fill at this source pixel: model coordinates of its centre, bilinear.
                val mx = ((x - left) / scale - 0.5).coerceIn(0.0, MODEL_SIDE - 1.0)
                val my = ((y - top) / scale - 0.5).coerceIn(0.0, MODEL_SIDE - 1.0)
                for (c in 0 until 3) rgba[o + c] = (bilinear(filled, c * n, mx, my) * 255).roundToInt().coerceIn(0, 255).toByte()
            }
            rgba[o + 3] = (alpha * 255).roundToInt().toByte()
        }
        return RemovePatch(px0, py0, pw, ph, rgba, w, h)
    }

    /**
     * Composites [patches] (computed at their own source size) onto [image] of the same photo at any
     * resolution. Returns a new image; the input is not changed unless [inPlace].
     */
    fun composite(patches: List<RemovePatch>, image: Rgba8Image, inPlace: Boolean = false): Rgba8Image {
        if (patches.isEmpty()) return image
        val out = if (inPlace) image else Rgba8Image(image.width, image.height, image.pixels.copyOf())
        compositeRegion(patches, out, 0, 0, image.width, image.height)
        return out
    }

    /**
     * [composite] for [region], the pixels of the rectangle at ([regionX], [regionY]) of a frameWidth × frameHeight
     * frame, in place (Save copy reads its frame by region, 2026-10-07). Each pixel gets exactly what [composite] gives
     * it in the whole frame: the patch mapping uses the frame's size and absolute coordinates.
     */
    fun compositeRegion(patches: List<RemovePatch>, region: Rgba8Image, regionX: Int, regionY: Int, frameWidth: Int, frameHeight: Int) {
        val out = region.pixels
        for (patch in patches) {
            val sx = frameWidth.toDouble() / patch.sourceWidth
            val sy = frameHeight.toDouble() / patch.sourceHeight
            val x0 = maxOf(floor(patch.x * sx).toInt().coerceIn(0, frameWidth), regionX)
            val y0 = maxOf(floor(patch.y * sy).toInt().coerceIn(0, frameHeight), regionY)
            val x1 = minOf(ceil((patch.x + patch.width) * sx).toInt().coerceIn(0, frameWidth), regionX + region.width)
            val y1 = minOf(ceil((patch.y + patch.height) * sy).toInt().coerceIn(0, frameHeight), regionY + region.height)
            val oneToOne = sx == 1.0 && sy == 1.0
            for (y in y0 until y1) for (x in x0 until x1) {
                val o = ((y - regionY) * region.width + (x - regionX)) * 4
                if (oneToOne) {
                    val p = ((y - patch.y) * patch.width + (x - patch.x)) * 4
                    val a = (patch.rgba[p + 3].toInt() and 0xff) / 255.0
                    if (a == 0.0) continue
                    for (c in 0 until 3) out[o + c] = blend(out[o + c], patch.rgba[p + c], a)
                } else {
                    // Patch pixel coordinates of this pixel's centre, bilinear in premultiplied form.
                    val px = ((x + 0.5) / sx - patch.x - 0.5).coerceIn(0.0, patch.width - 1.0)
                    val py = ((y + 0.5) / sy - patch.y - 0.5).coerceIn(0.0, patch.height - 1.0)
                    val a = samplePatch(patch, px, py, 3) / 255.0
                    if (a <= 0.0) continue
                    for (c in 0 until 3) {
                        val premultiplied = samplePatchPremultiplied(patch, px, py, c) / 255.0
                        val base = (out[o + c].toInt() and 0xff) / 255.0
                        out[o + c] = ((base * (1 - a) + premultiplied) * 255).roundToInt().coerceIn(0, 255).toByte()
                    }
                }
            }
        }
    }

    /** [frame] with [patches] composited into every region read (the export's source with Remove's fills). */
    class PatchedFrameSource(private val frame: com.lightlylabs.lightly.render.image.FrameSource, private val patches: List<RemovePatch>) :
        com.lightlylabs.lightly.render.image.FrameSource by frame {
        override fun region(x: Int, y: Int, width: Int, height: Int): Rgba8Image =
            frame.region(x, y, width, height).also { RemoveEngine.compositeRegion(patches, it, x, y, frame.width, frame.height) }
    }

    private fun blend(base: Byte, fill: Byte, a: Double): Byte {
        val b = (base.toInt() and 0xff).toDouble()
        val f = (fill.toInt() and 0xff).toDouble()
        return (b * (1 - a) + f * a).roundToInt().coerceIn(0, 255).toByte()
    }

    private fun samplePatch(patch: RemovePatch, x: Double, y: Double, channel: Int): Double = bilinearBytes(patch, x, y) { o -> (patch.rgba[o + channel].toInt() and 0xff).toDouble() }

    private fun samplePatchPremultiplied(patch: RemovePatch, x: Double, y: Double, channel: Int): Double =
        bilinearBytes(patch, x, y) { o -> (patch.rgba[o + channel].toInt() and 0xff) * ((patch.rgba[o + 3].toInt() and 0xff) / 255.0) }

    private fun bilinearBytes(patch: RemovePatch, x: Double, y: Double, value: (Int) -> Double): Double {
        val x0 = x.toInt(); val y0 = y.toInt()
        val x1 = min(x0 + 1, patch.width - 1); val y1 = min(y0 + 1, patch.height - 1)
        val fx = x - x0; val fy = y - y0
        fun at(px: Int, py: Int) = value((py * patch.width + px) * 4)
        val top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx
        val bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }

    private fun bilinear(plane: FloatArray, offset: Int, x: Double, y: Double): Double {
        val x0 = x.toInt(); val y0 = y.toInt()
        val x1 = min(x0 + 1, MODEL_SIDE - 1); val y1 = min(y0 + 1, MODEL_SIDE - 1)
        val fx = x - x0; val fy = y - y0
        fun at(px: Int, py: Int) = plane[offset + py * MODEL_SIDE + px].toDouble().coerceIn(0.0, 1.0)
        val top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx
        val bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }

    /** Bilinear RGB at continuous pixel coordinates (centres at integers), edge-clamped. */
    private fun sampleRgb(image: Rgba8Image, x: Double, y: Double, write: (Int, Float) -> Unit) {
        val cx = x.coerceIn(0.0, image.width - 1.0)
        val cy = y.coerceIn(0.0, image.height - 1.0)
        val x0 = cx.toInt(); val y0 = cy.toInt()
        val x1 = min(x0 + 1, image.width - 1); val y1 = min(y0 + 1, image.height - 1)
        val fx = cx - x0; val fy = cy - y0
        val p = image.pixels
        for (c in 0 until 3) {
            fun at(px: Int, py: Int) = (p[(py * image.width + px) * 4 + c].toInt() and 0xff).toDouble()
            val top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx
            val bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx
            write(c, (top * (1 - fy) + bottom * fy).toFloat())
        }
    }

    /** Distance from (x, y) to the polyline through [points] (a single point is a dab). */
    fun distanceToStroke(x: Double, y: Double, points: List<Pair<Double, Double>>): Double {
        if (points.size == 1) return hypot(x - points[0].first, y - points[0].second)
        var best = Double.MAX_VALUE
        for (i in 0 until points.size - 1) {
            val (ax, ay) = points[i]
            val (bx, by) = points[i + 1]
            val dx = bx - ax
            val dy = by - ay
            val length = dx * dx + dy * dy
            val t = if (length == 0.0) 0.0 else (((x - ax) * dx + (y - ay) * dy) / length).coerceIn(0.0, 1.0)
            best = min(best, hypot(x - (ax + t * dx), y - (ay + t * dy)))
        }
        return best
    }

    private fun hypot(a: Double, b: Double) = sqrt(a * a + b * b)
}
