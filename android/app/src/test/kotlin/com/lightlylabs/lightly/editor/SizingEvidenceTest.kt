package com.lightlylabs.lightly.editor

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.lightlylabs.lightly.background.BackgroundAnalysis
import com.lightlylabs.lightly.background.BackgroundPlan
import com.lightlylabs.lightly.background.BackgroundStage
import com.lightlylabs.lightly.background.DepthMaps
import com.lightlylabs.lightly.background.DepthOrigin
import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.background.FocusParams
import com.lightlylabs.lightly.background.Refocus
import com.lightlylabs.lightly.develop.PixelRect
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.BorderType
import com.lightlylabs.lightly.session.EditTools
import com.lightlylabs.lightly.session.WatermarkFont
import com.lightlylabs.lightly.session.WatermarkText
import com.lightlylabs.lightly.session.WatermarkType
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.test.assertTrue

/**
 * Evidence for the PROVISIONAL on-screen sizing of the watermark (W1) and Focus & Blur, through the real
 * renderers: the same photo (portrait_medium_02), the same stored depth (Depth Anything V2 Small output,
 * experiments/depth/cache/depth/da2_small) and the same recipe (Blur 55, Focus depth 40, Lens round, focus
 * on the face; text "A. Rivera", Inter, size 34, bottom right), at two stage layouts:
 * - Pixel 9 Pro portrait: the photo is displayed 319 × 479 dp (bg-focus capture, 2.625 px/dp);
 * - Pixel Tablet landscape: the side layout's stage is 836 × 696 dp, so the photo is 463 × 696 dp.
 * Each layout renders a preview-size image (533 × 800) and an export-size image (1065 × 1600). The test
 * measures the watermark's ink height and fits the background blur σ on the output images, and writes the
 * images and a summary to LIGHTLY_EVIDENCE_DIR (or a temporary folder).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SizingEvidenceTest {
    private val repo: File = File(checkNotNull(System.getProperty("lightly.renderingContract"))).parentFile.parentFile.parentFile
    private val out: File = (System.getenv("LIGHTLY_EVIDENCE_DIR")?.let(::File) ?: kotlin.io.path.createTempDirectory("sizing").toFile()).apply { mkdirs() }

    private data class Layout(val name: String, val shortDp: Double, val longDp: Double)
    private val layouts = listOf(Layout("pixel9pro-portrait", 319.0, 479.0), Layout("pixeltablet-landscape", 463.0, 696.0))

    private fun decode(file: File, width: Int, height: Int): Rgba8Image {
        val full = BitmapFactory.decodeFile(file.path)
        val scaled = if (full.width == width && full.height == height) full else Bitmap.createScaledBitmap(full, width, height, true)
        val argb = scaled.copy(Bitmap.Config.ARGB_8888, false)
        val buffer = ByteBuffer.allocate(argb.byteCount)
        argb.copyPixelsToBuffer(buffer)
        return Rgba8Image(width, height, buffer.array())
    }

    /** numpy float32 C-order 2-D array. */
    private fun npy(file: File): FloatPlane {
        val bytes = file.readBytes()
        val headerLength = (bytes[8].toInt() and 0xff) or ((bytes[9].toInt() and 0xff) shl 8)
        val header = String(bytes, 10, headerLength)
        val (rows, cols) = Regex("\\((\\d+), (\\d+)\\)").find(header)!!.destructured
        val buffer = ByteBuffer.wrap(bytes, 10 + headerLength, bytes.size - 10 - headerLength).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        return FloatPlane(cols.toInt(), rows.toInt(), FloatArray(buffer.remaining()).also { buffer.get(it) })
    }

    private fun save(image: Rgba8Image, name: String) {
        val bitmap = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888).apply { copyPixelsFromBuffer(ByteBuffer.wrap(image.pixels)) }
        File(out, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private fun luma(image: Rgba8Image, x: Int, y: Int): Double {
        val o = (y * image.width + x) * 4
        return 0.2126 * (image.pixels[o].toInt() and 0xff) + 0.7152 * (image.pixels[o + 1].toInt() and 0xff) + 0.0722 * (image.pixels[o + 2].toInt() and 0xff)
    }

    /** Separable Gaussian of a luma crop (edge-clamped). */
    private fun blur(src: DoubleArray, w: Int, h: Int, sigma: Double): DoubleArray {
        if (sigma < 0.3) return src.copyOf()
        val r = (3 * sigma).roundToInt().coerceAtLeast(1)
        val k = DoubleArray(2 * r + 1) { exp(-0.5 * ((it - r) / sigma) * ((it - r) / sigma)) }.let { k -> val s = k.sum(); DoubleArray(k.size) { k[it] / s } }
        val tmp = DoubleArray(src.size)
        for (y in 0 until h) for (x in 0 until w) { var a = 0.0; for (i in k.indices) a += k[i] * src[y * w + (x + i - r).coerceIn(0, w - 1)]; tmp[y * w + x] = a }
        val dst = DoubleArray(src.size)
        for (y in 0 until h) for (x in 0 until w) { var a = 0.0; for (i in k.indices) a += k[i] * tmp[(y + i - r).coerceIn(0, h - 1) * w + x]; dst[y * w + x] = a }
        return dst
    }

    /**
     * The Gaussian σ (px of [rendered]) that best explains the background: least squares of the rendered luma
     * against the original luma blurred by σ, with a per-crop gain and offset, on the wall at the top left
     * (x 2–25 %, y 3–28 % of the photo: background in every layout), with a margin.
     */
    private fun fitSigma(original: Rgba8Image, rendered: Rgba8Image): Double {
        val x0 = (rendered.width * 0.02).toInt(); val x1 = (rendered.width * 0.25).toInt()
        val y0 = (rendered.height * 0.03).toInt(); val y1 = (rendered.height * 0.28).toInt()
        val w = x1 - x0; val h = y1 - y0
        val orig = DoubleArray(w * h) { luma(original, x0 + it % w, y0 + it / w) }
        val rend = DoubleArray(w * h) { luma(rendered, x0 + it % w, y0 + it / w) }
        val margin = (w * 0.2).toInt()
        fun error(sigma: Double): Double {
            val b = blur(orig, w, h, sigma)
            val idx = (0 until w * h).filter { val x = it % w; val y = it / w; x in margin until w - margin && y in margin until h - margin }
            val mb = idx.map { b[it] }.average(); val mr = idx.map { rend[it] }.average()
            var sbr = 0.0; var sbb = 0.0
            for (i in idx) { sbr += (b[i] - mb) * (rend[i] - mr); sbb += (b[i] - mb) * (b[i] - mb) }
            val gain = if (sbb > 0) sbr / sbb else 1.0
            return idx.sumOf { val e = rend[it] - (mr + gain * (b[it] - mb)); e * e } / idx.size
        }
        var best = 0.0; var bestError = Double.MAX_VALUE
        var lo = 0.0; var hi = 40.0
        repeat(3) { round ->
            val step = (hi - lo) / 16
            var s = lo
            while (s <= hi + 1e-9) { val e = error(s); if (e < bestError) { bestError = e; best = s }; s += step }
            lo = max(0.0, best - step); hi = best + step
        }
        return best
    }

    /** Height (px) of the pixels the watermark changed. */
    private fun inkHeight(without: Rgba8Image, with: Rgba8Image): Int {
        var top = Int.MAX_VALUE; var bottom = -1
        for (y in 0 until with.height) for (x in 0 until with.width) if (abs(luma(with, x, y) - luma(without, x, y)) > 40) { top = minOf(top, y); bottom = max(bottom, y) }
        return if (bottom < 0) 0 else bottom - top + 1
    }

    @Test
    fun `watermark and blur sizes at two stage layouts, preview and export`() {
        val photoFile = File(repo, "docs/ui/assets/photos/portrait_medium_02.jpg")
        val raw = npy(File(repo, "experiments/depth/cache/depth/da2_small/portrait_medium_02.npy"))
        val lines = mutableListOf("layout,size,render_long_px,blur_fraction,sigma_px,sigma_over_long,sigma_dp_on_screen,text_font_px,ink_height_px,ink_over_short,ink_dp_on_screen")
        val results = mutableMapOf<String, DoubleArray>()
        for (layout in layouts) for ((sizeName, w, h) in listOf(Triple("preview", 533, 800), Triple("export", 1065, 1600))) {
            val photo = decode(photoFile, w, h)
            val grey = FloatPlane(w, h, FloatArray(w * h) { (luma(photo, it % w, it / w) / 255).toFloat() })
            val depth = DepthMaps.normalised(DepthOrigin.ESTIMATED, com.lightlylabs.lightly.background.PlaneOps.resizeBilinear(raw, w, h), grey)
            val analysis = BackgroundAnalysis(w, h, depth, null)
            val fraction = EditorViewModel.BLUR_MATCH_DP / layout.longDp
            val scene = Refocus.buildScene(com.lightlylabs.lightly.background.FloatImage(w, h, 3, FloatArray(w * h * 3) { Refocus.srgbToLinear((photo.pixels[(it / 3) * 4 + it % 3].toInt() and 0xff) / 255f) }), depth.nearness, null)
            val focal = Refocus.focalNearness(scene, 0.40, 0.48)
            val plan = BackgroundPlan(null, FocusParams(55.0, 40.0, "lens", "round", 50.0, fraction), focal, focusTarget = 0.40 to 0.48)
            val blurred = Rgba8Image(w, h, BackgroundStage.render(photo.pixels, analysis, plan, Refocus.FocusConstants.LAYERS_PER_SIDE_EXPORT).first)
            val sizes = WatermarkSizes(EditorViewModel.PROTOTYPE_TEXT_DP / layout.shortDp, EditorViewModel.PROTOTYPE_SIGNATURE_DP / layout.shortDp, EditorViewModel.PROTOTYPE_LOGO_DP / layout.shortDp)
            val tool = EditTools.neutral(0).watermark.copy(type = WatermarkType.TEXT, text = WatermarkText("A. Rivera", WatermarkFont.INTER))
            val stage = WatermarkStage(sizes, WatermarkFonts(null))
            val layer = stage.layer(tool, WatermarkContent.Text("A. Rivera", WatermarkFont.INTER), w, h, PixelRect(0, 0, w, h), BorderType.NONE)!!
            val final = layer.compositeOnto(blurred)
            save(final, "${layout.name}-$sizeName")
            val sigma = fitSigma(photo, blurred)
            val ink = inkHeight(blurred, final)
            val longPx = max(w, h).toDouble()
            val shortPx = minOf(w, h).toDouble()
            val row = doubleArrayOf(sigma / longPx, ink / shortPx)
            results["${layout.name}-$sizeName"] = row
            lines += listOf(layout.name, sizeName, longPx.toInt(), "%.5f".format(fraction), "%.2f".format(sigma), "%.5f".format(sigma / longPx),
                "%.2f".format(sigma / longPx * layout.longDp), "%.1f".format(sizes.textFontSize * shortPx), ink, "%.5f".format(ink / shortPx), "%.2f".format(ink / shortPx * layout.shortDp)).joinToString(",")
        }
        File(out, "summary.csv").writeText(lines.joinToString("\n") + "\n")
        println("evidence: ${out.absolutePath}\n" + lines.joinToString("\n"))
        // Preview and export of the same layout agree as fractions of the photo (resolution independence).
        for (layout in layouts) {
            val p = results.getValue("${layout.name}-preview"); val e = results.getValue("${layout.name}-export")
            assertTrue(abs(p[0] - e[0]) <= 0.15 * e[0], "${layout.name}: blur σ/long preview ${p[0]} vs export ${e[0]}")
            assertTrue(abs(p[1] - e[1]) <= 0.1 * e[1], "${layout.name}: watermark ink/short preview ${p[1]} vs export ${e[1]}")
        }
    }
}
