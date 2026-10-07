package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.develop.ColourMath.LUMA_B
import com.lightlylabs.lightly.develop.ColourMath.LUMA_G
import com.lightlylabs.lightly.develop.ColourMath.LUMA_R
import com.lightlylabs.lightly.develop.ColourMath.linearToSrgb
import com.lightlylabs.lightly.develop.ColourMath.smoothstep
import com.lightlylabs.lightly.develop.ColourMath.srgbToLinear
import com.lightlylabs.lightly.render.image.FrameSource
import com.lightlylabs.lightly.render.image.Rgba8Image
import java.util.concurrent.Callable
import java.util.concurrent.ExecutorService
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

/** A rectangle of the full frame, in pixels. */
data class PixelRect(val x: Int, val y: Int, val width: Int, val height: Int)

/** [image] holds the pixels of a frameWidth × frameHeight frame starting at ([originX], [originY]). */
class FrameView(val image: Rgba8Image, val originX: Int, val originY: Int, val frameWidth: Int, val frameHeight: Int) {
    fun alpha(x: Int, y: Int): Byte = image.pixels[((y - originY) * image.width + (x - originX)) * 4 + 3]
}

/**
 * CPU renderer of a [DevelopRenderPlan] (rendering-v2 stages auto → develop.global → develop.spatial
 * → effects/finishing), whole-frame for previews or tile by tile for Save copy.
 *
 * Tiles: develop.spatial reads neighbours, so each tile is rendered from the tile plus an [apron]
 * wide enough for the chained Gaussians; clarity's very large blur (≈5 % of the long edge) is taken
 * from a [clarityBase] computed once per frame at low resolution, so it needs no apron at all. The
 * finishing operators are functions of absolute frame coordinates. A frame therefore renders the
 * same whether it is cut into tiles or not (tested in DevelopRendererTest).
 *
 * Approximations against reference_model (listed in docs/v1/slice2-android.md › Rendering):
 * - clarity's Gaussian is evaluated at low resolution ([Planes.lowResGaussian]) and from the
 *   develop.global output (before noise reduction), not from the noise-reduced lightness;
 * - the spatial operators run in one OKLab pass; the reference returns to clipped sRGB between
 *   operators, which differs only for colours that leave the sRGB gamut in between.
 */
class DevelopRenderer(
    private val executor: ExecutorService? = null,
    private val parallelism: Int = 1,
    /** Checked before each chunk of rows; true stops the render with a CancellationException (see [cancellable]). */
    private val isCancelled: () -> Boolean = { false },
) {
    /**
     * This renderer, stopping between chunks of rows once [isCancelled] is true (2026-10-06): a superseded preview's
     * develop at the display size (3-5 s on the emulator) otherwise ran to the end beside the frame that replaced it.
     * Rendered pixels are unchanged; only whether the render finishes.
     */
    fun cancellable(isCancelled: () -> Boolean) = DevelopRenderer(executor, parallelism, isCancelled)

    /** Pixels of context a tile needs around it for [plan]'s spatial operators on a frame of this size. */
    fun apron(plan: DevelopRenderPlan, frameWidth: Int, frameHeight: Int): Int {
        if (!plan.hasSpatial) return 0
        val longEdge = max(frameWidth, frameHeight)
        val scale = longEdge / plan.model.provisional.referenceLongEdgePx
        var apron = 0
        plan.spatial.noiseReduction?.let { nr ->
            var nrRadius = 0
            if (nr.luminance != 0.0) nrRadius = Planes.radius(max(plan.model.provisional.nrLumaRadiusPx * scale, 0.3), longEdge)
            if (nr.color != 0.0) nrRadius = max(nrRadius, Planes.radius(max(colourRadius(plan, nr, scale), 0.3), longEdge))
            apron += nrRadius
        }
        if (plan.spatial.texture != 0.0) apron += Planes.radius(max(plan.model.spatial.rTexture * longEdge, 0.3), longEdge)
        plan.spatial.sharpening?.takeIf { it.amount != 0.0 }?.let { s ->
            apron += Planes.radius(max(s.radius * longEdge / plan.model.provisional.referenceLongEdgePx, 0.3), longEdge) + 1
        }
        return apron + 2
    }

    /**
     * clarity's blurred lightness for the whole frame, at low resolution: one streaming pass over the
     * source (LUT passes → OKLab L, box-binned), so no full-resolution float plane is ever held.
     * Null when the plan has no clarity.
     */
    fun clarityBase(source: Rgba8Image, plan: DevelopRenderPlan): LowResPlane? {
        if (plan.spatial.clarity == 0.0) return null
        val longEdge = max(source.width, source.height)
        val sigma = plan.model.spatial.rClarity * longEdge
        val factor = Planes.lowResFactor(sigma)
        val lowW = (source.width + factor - 1) / factor
        val lowH = (source.height + factor - 1) / factor
        val view = FrameView(source, 0, 0, source.width, source.height)
        val sums = DoubleArray(lowW * lowH)
        val counts = IntArray(lowW * lowH)
        // Row bands are binned independently (one low-res row per band), so threads never share a bin.
        parallel(lowH) { firstLow, endLow ->
            val rgb = FloatArray(3)
            val lab = DoubleArray(3)
            for (y in firstLow * factor until min(source.height, endLow * factor)) {
                val lowRow = (y / factor) * lowW
                for (x in 0 until source.width) {
                    globalColour(view, x, y, plan, rgb)
                    ColourMath.linearToOklab(srgbToLinear(rgb[0].toDouble()), srgbToLinear(rgb[1].toDouble()), srgbToLinear(rgb[2].toDouble()), lab)
                    val bin = lowRow + x / factor
                    sums[bin] += lab[0]
                    counts[bin]++
                }
            }
        }
        val low = FloatArray(sums.size) { (sums[it] / max(counts[it], 1)).toFloat() }
        val blurred = Planes.gaussianBlur(low, lowW, lowH, Planes.lowResSigma(sigma, factor), max(lowW, lowH))
        return LowResPlane(blurred, lowW, lowH, factor.toDouble())
    }

    /**
     * [clarityBase] of a frame read by region (Save copy, 2026-10-07): each low-resolution row's band of `factor` source
     * rows is read on its own, and its pixels are binned in the same order with the same arithmetic as the whole-image
     * version, so the base is identical (DevelopRendererTest) while no more than one band per thread is held.
     */
    fun clarityBase(frame: FrameSource, plan: DevelopRenderPlan): LowResPlane? {
        if (plan.spatial.clarity == 0.0) return null
        val longEdge = max(frame.width, frame.height)
        val sigma = plan.model.spatial.rClarity * longEdge
        val factor = Planes.lowResFactor(sigma)
        val lowW = (frame.width + factor - 1) / factor
        val lowH = (frame.height + factor - 1) / factor
        val sums = DoubleArray(lowW * lowH)
        val counts = IntArray(lowW * lowH)
        parallel(lowH) { firstLow, endLow ->
            val rgb = FloatArray(3)
            val lab = DoubleArray(3)
            for (lowY in firstLow until endLow) {
                val y0 = lowY * factor
                val y1 = min(frame.height, y0 + factor)
                if (y0 >= y1) continue
                val band = FrameView(frame.region(0, y0, frame.width, y1 - y0), 0, y0, frame.width, frame.height)
                val lowRow = lowY * lowW
                for (y in y0 until y1) for (x in 0 until frame.width) {
                    globalColour(band, x, y, plan, rgb)
                    ColourMath.linearToOklab(srgbToLinear(rgb[0].toDouble()), srgbToLinear(rgb[1].toDouble()), srgbToLinear(rgb[2].toDouble()), lab)
                    val bin = lowRow + x / factor
                    sums[bin] += lab[0]
                    counts[bin]++
                }
            }
        }
        val low = FloatArray(sums.size) { (sums[it] / max(counts[it], 1)).toFloat() }
        val blurred = Planes.gaussianBlur(low, lowW, lowH, Planes.lowResSigma(sigma, factor), max(lowW, lowH))
        return LowResPlane(blurred, lowW, lowH, factor.toDouble())
    }

    /**
     * One tile of a frame read by region: the tile plus [apron] (clamped to the frame) is read, and rendered as
     * [renderView] renders it from the whole image, which reads nothing outside that region.
     */
    fun renderTile(frame: FrameSource, tile: PixelRect, plan: DevelopRenderPlan, base: LowResPlane?): Rgba8Image {
        val apron = apron(plan, frame.width, frame.height)
        val x0 = max(0, tile.x - apron)
        val y0 = max(0, tile.y - apron)
        val x1 = min(frame.width, tile.x + tile.width + apron)
        val y1 = min(frame.height, tile.y + tile.height + apron)
        return renderView(FrameView(frame.region(x0, y0, x1 - x0, y1 - y0), x0, y0, frame.width, frame.height), tile, plan, base)
    }

    /** The whole frame (previews). */
    fun render(source: Rgba8Image, plan: DevelopRenderPlan): Rgba8Image =
        renderTile(source, PixelRect(0, 0, source.width, source.height), plan, clarityBase(source, plan))

    /** One tile of the frame; [base] must come from [clarityBase] on the same source and plan. */
    fun renderTile(source: Rgba8Image, tile: PixelRect, plan: DevelopRenderPlan, base: LowResPlane?): Rgba8Image =
        renderView(FrameView(source, 0, 0, source.width, source.height), tile, plan, base)

    /**
     * One tile of a frame from a [view] that holds only part of it (a second pass over pixels a first
     * pass rendered for a region: the Adjust pass in a tiled Save copy). Radii and finishing use the
     * whole frame's size, and [base] is the whole frame's clarity base; the view must hold the tile and
     * its [apron] (clamped to the frame), so reflect padding happens only at the frame's own edges.
     */
    fun renderView(view: FrameView, tile: PixelRect, plan: DevelopRenderPlan, base: LowResPlane?): Rgba8Image {
        require(tile.x >= view.originX && tile.y >= view.originY && tile.x + tile.width <= view.originX + view.image.width && tile.y + tile.height <= view.originY + view.image.height) {
            "Tile $tile outside the view"
        }
        val out = ByteArray(tile.width * tile.height * Rgba8Image.CHANNELS)
        val finishing = if (plan.hasFinishing) FinishingPass(plan, view.frameWidth, view.frameHeight) else null
        if (!plan.hasSpatial) {
            parallel(tile.height) { first, end ->
                val rgb = FloatArray(3)
                val work = DoubleArray(6)
                for (row in first until end) for (column in 0 until tile.width) {
                    val x = tile.x + column
                    val y = tile.y + row
                    globalColour(view, x, y, plan, rgb)
                    write(out, (row * tile.width + column) * 4, rgb, finishing, x, y, work, view.alpha(x, y))
                }
            }
            return Rgba8Image(tile.width, tile.height, out)
        }
        renderSpatialTile(view, tile, plan, base, finishing, out)
        return Rgba8Image(tile.width, tile.height, out)
    }

    private fun renderSpatialTile(view: FrameView, tile: PixelRect, plan: DevelopRenderPlan, base: LowResPlane?, finishing: FinishingPass?, out: ByteArray) {
        val apron = apron(plan, view.frameWidth, view.frameHeight)
        val rx = max(view.originX, tile.x - apron)
        val ry = max(view.originY, tile.y - apron)
        val rw = min(view.originX + view.image.width, tile.x + tile.width + apron) - rx
        val rh = min(view.originY + view.image.height, tile.y + tile.height + apron) - ry
        val n = rw * rh
        val lightness = FloatArray(n)
        val chromaA = FloatArray(n)
        val chromaB = FloatArray(n)
        parallel(rh) { first, end ->
            val rgb = FloatArray(3)
            val lab = DoubleArray(3)
            for (row in first until end) for (column in 0 until rw) {
                globalColour(view, rx + column, ry + row, plan, rgb)
                ColourMath.linearToOklab(srgbToLinear(rgb[0].toDouble()), srgbToLinear(rgb[1].toDouble()), srgbToLinear(rgb[2].toDouble()), lab)
                val i = row * rw + column
                lightness[i] = lab[0].toFloat(); chromaA[i] = lab[1].toFloat(); chromaB[i] = lab[2].toFloat()
            }
        }
        val longEdge = max(view.frameWidth, view.frameHeight)
        val scale = longEdge / plan.model.provisional.referenceLongEdgePx
        plan.spatial.noiseReduction?.let { noiseReduction(lightness, chromaA, chromaB, rw, rh, it, plan, scale, longEdge) }
        if (plan.spatial.clarity != 0.0 || plan.spatial.texture != 0.0) clarityTexture(lightness, rw, rh, rx, ry, plan, base, longEdge)
        plan.spatial.sharpening?.takeIf { it.amount != 0.0 }?.let { sharpen(lightness, rw, rh, it, plan, longEdge) }

        parallel(tile.height) { first, end ->
            val linear = DoubleArray(3)
            val rgb = FloatArray(3)
            val work = DoubleArray(6)
            for (row in first until end) for (column in 0 until tile.width) {
                val x = tile.x + column
                val y = tile.y + row
                val i = (y - ry) * rw + (x - rx)
                ColourMath.oklabToLinear(lightness[i].toDouble(), chromaA[i].toDouble(), chromaB[i].toDouble(), linear)
                for (c in 0 until 3) rgb[c] = linearToSrgb(linear[c]).coerceIn(0.0, 1.0).toFloat()
                write(out, (row * tile.width + column) * 4, rgb, finishing, x, y, work, view.alpha(x, y))
            }
        }
    }

    /** S1 (provisional): luminance blends toward a blurred L where the image is flat; colour blurs a and b. */
    private fun noiseReduction(l: FloatArray, a: FloatArray, b: FloatArray, w: Int, h: Int, nr: NoiseReduction, plan: DevelopRenderPlan, scale: Double, longEdge: Int) {
        val p = plan.model.provisional
        if (nr.luminance != 0.0) {
            val smooth = blur(l, w, h, p.nrLumaRadiusPx * scale, longEdge)
            val detailScale = p.nrDetailScale * (1.01 - nr.luminanceDetail / 100)
            val weightScale = nr.luminance / 100 * (1 - 0.5 * nr.luminanceContrast / 100)
            for (i in l.indices) {
                val keep = smoothstep(0.0, detailScale, abs(l[i] - smooth[i]).toDouble())
                l[i] = (l[i] + (smooth[i] - l[i]) * weightScale * (1 - keep)).toFloat()
            }
        }
        if (nr.color != 0.0) {
            val radius = colourRadius(plan, nr, scale)
            val weight = nr.color / 100
            val blurA = blur(a, w, h, radius, longEdge)
            val blurB = blur(b, w, h, radius, longEdge)
            for (i in a.indices) {
                a[i] = (a[i] + (blurA[i] - a[i]) * weight).toFloat()
                b[i] = (b[i] + (blurB[i] - b[i]) * weight).toFloat()
            }
        }
        for (i in l.indices) l[i] = l[i].coerceIn(0f, 1f)
    }

    /** S2 (calibrated): both terms read the same incoming L, as in the reference. */
    private fun clarityTexture(l: FloatArray, w: Int, h: Int, rx: Int, ry: Int, plan: DevelopRenderPlan, base: LowResPlane?, longEdge: Int) {
        val sc = plan.model.spatial
        val clarity = plan.spatial.clarity
        val texture = plan.spatial.texture
        val textureBlur = if (texture != 0.0) blur(l, w, h, sc.rTexture * longEdge, longEdge) else null
        check(clarity == 0.0 || base != null) { "clarity needs the frame's clarity base" }
        for (row in 0 until h) for (column in 0 until w) {
            val i = row * w + column
            val value = l[i].toDouble()
            var outValue = value
            if (clarity != 0.0) outValue += sc.kClarity * clarity / 100 * 4 * value * (1 - value) * (value - base!!.sample(rx + column, ry + row))
            if (textureBlur != null) outValue += sc.kTexture * texture / 100 * (value - textureBlur[i])
            l[i] = outValue.coerceIn(0.0, 1.0).toFloat()
        }
    }

    /** S3 (provisional): unsharp mask on L with a detail threshold and optional edge mask. */
    private fun sharpen(l: FloatArray, w: Int, h: Int, s: Sharpening, plan: DevelopRenderPlan, longEdge: Int) {
        val p = plan.model.provisional
        val sigma = s.radius * longEdge / p.referenceLongEdgePx
        val blurred = blur(l, w, h, sigma, longEdge)
        val threshold = (1 - s.detail / 100) * p.sharpenDetailThreshold
        val edgeScale = longEdge / p.referenceLongEdgePx
        val result = FloatArray(l.size)
        for (row in 0 until h) for (column in 0 until w) {
            val i = row * w + column
            var detail = (l[i] - blurred[i]).toDouble()
            detail = detail * abs(detail) / (abs(detail) + threshold + 1e-12)
            if (s.edgeMasking != 0.0) {
                // np.gradient: central differences inside, one-sided at the plane's edges.
                val gx = when {
                    w == 1 -> 0.0
                    column == 0 -> (blurred[i + 1] - blurred[i]).toDouble()
                    column == w - 1 -> (blurred[i] - blurred[i - 1]).toDouble()
                    else -> (blurred[i + 1] - blurred[i - 1]) / 2.0
                }
                val gy = when {
                    h == 1 -> 0.0
                    row == 0 -> (blurred[i + w] - blurred[i]).toDouble()
                    row == h - 1 -> (blurred[i] - blurred[i - w]).toDouble()
                    else -> (blurred[i + w] - blurred[i - w]) / 2.0
                }
                val edge = sqrt(gx * gx + gy * gy) * edgeScale
                detail *= smoothstep(0.0, s.edgeMasking / 100 * p.sharpenEdgeScale, edge)
            }
            result[i] = (l[i] + p.kSharpen * s.amount / 100 * detail).coerceIn(0.0, 1.0).toFloat()
        }
        result.copyInto(l)
    }

    private fun colourRadius(plan: DevelopRenderPlan, nr: NoiseReduction, scale: Double) =
        plan.model.provisional.nrColourRadiusPx * scale * (0.5 + nr.colorSmoothness / 100)

    /** Separable Gaussian with the passes split across the executor. */
    private fun blur(src: FloatArray, w: Int, h: Int, sigmaPx: Double, longEdge: Int): FloatArray {
        val kernel = Planes.kernel(sigmaPx, longEdge)
        val radius = kernel.size / 2
        val rows = FloatArray(src.size)
        parallel(h) { first, end ->
            for (y in first until end) {
                val row = y * w
                for (x in 0 until w) {
                    var sum = 0.0
                    for (k in kernel.indices) sum += kernel[k] * src[row + Planes.reflect(x + k - radius, w)]
                    rows[row + x] = sum.toFloat()
                }
            }
        }
        val dst = FloatArray(src.size)
        parallel(h) { first, end ->
            for (y in first until end) for (x in 0 until w) {
                var sum = 0.0
                for (k in kernel.indices) sum += kernel[k] * rows[Planes.reflect(y + k - radius, h) * w + x]
                dst[y * w + x] = sum.toFloat()
            }
        }
        return dst
    }

    /** Auto then Look, each clamping its input (the Lut3D boundary rule); no 8-bit step between them. */
    private fun globalColour(view: FrameView, x: Int, y: Int, plan: DevelopRenderPlan, rgb: FloatArray) {
        val source = view.image
        val base = ((y - view.originY) * source.width + (x - view.originX)) * 4
        rgb[0] = (source.pixels[base].toInt() and 0xff) / 255f
        rgb[1] = (source.pixels[base + 1].toInt() and 0xff) / 255f
        rgb[2] = (source.pixels[base + 2].toInt() and 0xff) / 255f
        plan.autoLut?.let { trilinear(it, rgb) }
        plan.lookLut?.let { trilinear(it, rgb) }
    }

    /**
     * Trilinear lookup in float, with the Lut3D boundary rule (input clamped to [0, 1], last cell
     * kept valid). Same result as Lut3D.sample to float rounding; written out because it runs per pixel.
     */
    private fun trilinear(lut: com.lightlylabs.lightly.render.lut.Lut3D, rgb: FloatArray) {
        val n = lut.dimension
        val scale = (n - 1).toFloat()
        val r = rgb[0].coerceIn(0f, 1f) * scale
        val g = rgb[1].coerceIn(0f, 1f) * scale
        val b = rgb[2].coerceIn(0f, 1f) * scale
        val r0 = minOf(r.toInt(), n - 2)
        val g0 = minOf(g.toInt(), n - 2)
        val b0 = minOf(b.toInt(), n - 2)
        val fr = r - r0
        val fg = g - g0
        val fb = b - b0
        val t = lut.rgba
        val stepG = n * 4
        val stepB = n * n * 4
        val base = (r0 + n * (g0 + n * b0)) * 4
        for (c in 0 until 3) {
            val i = base + c
            val c00 = t[i] + (t[i + 4] - t[i]) * fr
            val c10 = t[i + stepG] + (t[i + stepG + 4] - t[i + stepG]) * fr
            val c01 = t[i + stepB] + (t[i + stepB + 4] - t[i + stepB]) * fr
            val c11 = t[i + stepB + stepG] + (t[i + stepB + stepG + 4] - t[i + stepB + stepG]) * fr
            val c0 = c00 + (c10 - c00) * fg
            val c1 = c01 + (c11 - c01) * fg
            rgb[c] = c0 + (c1 - c0) * fb
        }
    }

    private fun write(out: ByteArray, offset: Int, rgb: FloatArray, finishing: FinishingPass?, x: Int, y: Int, work: DoubleArray, alpha: Byte) {
        finishing?.apply(rgb, x, y, work)
        out[offset] = encode(rgb[0])
        out[offset + 1] = encode(rgb[1])
        out[offset + 2] = encode(rgb[2])
        out[offset + 3] = alpha
    }

    private fun parallel(count: Int, body: (Int, Int) -> Unit) {
        if (isCancelled()) throw java.util.concurrent.CancellationException("render superseded")
        if (executor == null || parallelism <= 1 || count < 64) {
            body(0, count)
            return
        }
        // Four chunks per thread: a cancelled render stops within one chunk (rows are independent, so the chunking
        // changes no pixel).
        val chunk = (count + CHUNKS_PER_THREAD * parallelism - 1) / (CHUNKS_PER_THREAD * parallelism)
        executor.invokeAll((0 until count step chunk).map { first ->
            Callable { if (!isCancelled()) body(first, min(count, first + chunk)) }
        }).forEach { it.get() }
        if (isCancelled()) throw java.util.concurrent.CancellationException("render superseded")
    }

    companion object {
        private const val CHUNKS_PER_THREAD = 4

        /** 2×2 box average to half size (odd edges keep their last row/column), alpha kept from the top-left. */
        fun halfSize(image: Rgba8Image): Rgba8Image {
            if (image.width < 2 || image.height < 2) return image
            val w = image.width / 2
            val h = image.height / 2
            val src = image.pixels
            val out = ByteArray(w * h * 4)
            for (y in 0 until h) for (x in 0 until w) {
                val a = ((2 * y) * image.width + 2 * x) * 4
                val b = a + 4
                val c = a + image.width * 4
                val d = c + 4
                for (k in 0 until 3) {
                    val sum = (src[a + k].toInt() and 0xff) + (src[b + k].toInt() and 0xff) + (src[c + k].toInt() and 0xff) + (src[d + k].toInt() and 0xff)
                    out[(y * w + x) * 4 + k] = ((sum + 2) / 4).toByte()
                }
                out[(y * w + x) * 4 + 3] = src[a + 3]
            }
            return Rgba8Image(w, h, out)
        }

        /** O4 rounding, as CpuLutRenderer.encodeUint8: `x·255 + 0.5`, clamp, truncate. */
        fun encode(value: Float): Byte {
            val scaled = value * 255f + 0.5f
            val clamped = if (scaled > 0f) (if (scaled < 255f) scaled else 255f) else 0f
            return clamped.toInt().toByte()
        }
    }
}

/**
 * The preset's finishing operators (rendering-v2.md §6 F1 vignette, F2 grain), in that order, at
 * absolute frame coordinates. Stage effects runs after edit.geometry; until the Edit tool exists the
 * frame is the source frame.
 */
internal class FinishingPass(
    vignette: Vignette?,
    grain: Grain?,
    private val experimental: ExperimentalConstants,
    private val width: Int,
    private val height: Int,
) {
    constructor(plan: DevelopRenderPlan, width: Int, height: Int) : this(plan.finishing.vignette, plan.finishing.grain, plan.model.experimental, width, height)

    private val vignette = vignette?.takeIf { it.amount != 0.0 }
    private val grain = grain?.takeIf { it.amount != 0.0 }
    private val vignetteK = experimental.vignetteK
    private val grainK = experimental.grainK

    // Grain fields (rows × cols cells), sampled bilinearly per pixel.
    private val grainRows: Int
    private val grainCols: Int
    private val coarseRows: Int
    private val coarseCols: Int
    private val fine: DoubleArray?
    private val coarse: DoubleArray?

    /**
     * Revision 1 supersampling factor s = max(1, ceil(2·cells/longEdge)): the field is interpolated at
     * s·H × s·W and each output pixel is the mean of its s × s block, so a render with fewer than two
     * pixels per grain cell gets what downscaling the export would give it (no point-sampled 1.5× grain).
     */
    private val grainSupersampling: Int

    init {
        val g = grain
        if (g != null) {
            val longEdge = max(width, height)
            val size = g.size / 100
            val cellsLong = max(8, Math.rint(experimental.grainRefLong / (1 + 4 * size)).toInt()) // Python round(): half to even
            grainRows = max(2, Math.rint(cellsLong.toDouble() * height / longEdge).toInt())
            grainCols = max(2, Math.rint(cellsLong.toDouble() * width / longEdge).toInt())
            coarseRows = max(2, grainRows / 3)
            coarseCols = max(2, grainCols / 3)
            fine = PortableRandom.field(g.seed, 0, grainRows, grainCols)
            coarse = PortableRandom.field(g.seed, 1, coarseRows, coarseCols)
            grainSupersampling = max(1, kotlin.math.ceil(2.0 * cellsLong / longEdge).toInt())
        } else {
            grainRows = 0; grainCols = 0; coarseRows = 0; coarseCols = 0; fine = null; coarse = null; grainSupersampling = 1
        }
    }

    /** Applies vignette then grain to rgb (sRGB-encoded, in [0, 1]) at frame pixel (x, y). [work] holds ≥ 6 doubles. */
    fun apply(rgb: FloatArray, x: Int, y: Int, work: DoubleArray) {
        vignette?.let { applyVignette(rgb, x, y, it, work) }
        grain?.let { applyGrain(rgb, x, y, it, work) }
    }

    private fun applyVignette(rgb: FloatArray, column: Int, row: Int, v: Vignette, work: DoubleArray) {
        val amount = v.amount / 100
        val midpoint = v.midpoint / 100
        val feather = v.feather / 100
        val roundness = v.roundness / 100
        var x = if (width > 1) -1.0 + 2.0 * column / (width - 1) else -1.0 // linspace(-1, 1, n)
        val y = if (height > 1) -1.0 + 2.0 * row / (height - 1) else -1.0
        if (roundness > 0) x *= 1 + roundness * (width.toDouble() / height - 1)
        val power = 2.0 + max(0.0, -roundness) * 6.0
        val radius = (abs(x).pow(power) + abs(y).pow(power)).pow(1 / power) / 2.0.pow(1 / power)
        val centre = 0.25 + 0.65 * midpoint
        val widthBand = 0.05 + 0.6 * feather
        val t = smoothstep(centre - widthBand / 2, centre + widthBand / 2, radius)
        when (v.style) {
            3 -> { // paint overlay
                val target = if (amount < 0) 0.0 else 1.0
                val weight = (abs(amount) * vignetteK * t).coerceIn(0.0, 1.0)
                for (c in 0 until 3) rgb[c] = (rgb[c] * (1 - weight) + target * weight).coerceIn(0.0, 1.0).toFloat()
            }
            2 -> { // colour priority: lightness only
                val gain = 1 + vignetteK * amount * t
                ColourMath.linearToOklab(srgbToLinear(rgb[0].toDouble()), srgbToLinear(rgb[1].toDouble()), srgbToLinear(rgb[2].toDouble()), work)
                withLightness(rgb, work[0] * max(gain, 0.0).pow(1.0 / 3), work[1], work[2], work)
            }
            else -> { // 1: highlight priority
                var gain = 1 + vignetteK * amount * t
                val lr = srgbToLinear(rgb[0].toDouble())
                val lg = srgbToLinear(rgb[1].toDouble())
                val lb = srgbToLinear(rgb[2].toDouble())
                val highlightContrast = v.highlightContrast / 100
                if (amount < 0 && highlightContrast != 0.0) {
                    val luma = (lr * LUMA_R + lg * LUMA_G + lb * LUMA_B).coerceIn(0.0, 1.0)
                    gain = 1 + (gain - 1) * (1 - highlightContrast * smoothstep(0.35, 0.9, luma))
                }
                val g = max(gain, 0.0)
                rgb[0] = linearToSrgb(lr * g).coerceIn(0.0, 1.0).toFloat()
                rgb[1] = linearToSrgb(lg * g).coerceIn(0.0, 1.0).toFloat()
                rgb[2] = linearToSrgb(lb * g).coerceIn(0.0, 1.0).toFloat()
            }
        }
    }

    private fun applyGrain(rgb: FloatArray, x: Int, y: Int, g: Grain, work: DoubleArray) {
        val noise = grainNoise(x, y, g.roughness / 100)
        ColourMath.linearToOklab(srgbToLinear(rgb[0].toDouble()), srgbToLinear(rgb[1].toDouble()), srgbToLinear(rgb[2].toDouble()), work)
        val l = work[0]
        withLightnessKeepChromaticity(rgb, l + grainK * (g.amount / 100) * noise * (4 * l * (1 - l) + 0.2), l, work[1], work[2], work)
    }

    /** reference `grain_noise` at one output pixel: the s × s block mean of the supersampled mixed field. */
    internal fun grainNoise(x: Int, y: Int, roughness: Double): Double {
        val s = grainSupersampling
        val norm = sqrt((1 - roughness) * (1 - roughness) + roughness * roughness)
        var sum = 0.0
        for (j in 0 until s) for (i in 0 until s) {
            val fineValue = bilinear(fine!!, grainRows, grainCols, x * s + i, y * s + j, width * s, height * s) / (2.0 / 3)
            val coarseValue = bilinear(coarse!!, coarseRows, coarseCols, x * s + i, y * s + j, width * s, height * s) / (2.0 / 3)
            sum += ((1 - roughness) * fineValue + roughness * coarseValue) / norm
        }
        return sum / (s * s)
    }

    /** bilinear_upsample at one output pixel (half-pixel centres), from a rows × cols field to outHeight × outWidth. */
    private fun bilinear(field: DoubleArray, rows: Int, cols: Int, x: Int, y: Int, outWidth: Int, outHeight: Int): Double {
        val sy = ((y + 0.5) * rows / outHeight - 0.5).coerceIn(0.0, (rows - 1).toDouble())
        val sx = ((x + 0.5) * cols / outWidth - 0.5).coerceIn(0.0, (cols - 1).toDouble())
        val y0 = sy.toInt()
        val x0 = sx.toInt()
        val y1 = min(y0 + 1, rows - 1)
        val x1 = min(x0 + 1, cols - 1)
        val fy = sy - y0
        val fx = sx - x0
        val top = field[y0 * cols + x0] * (1 - fx) + field[y0 * cols + x1] * fx
        val bottom = field[y1 * cols + x0] * (1 - fx) + field[y1 * cols + x1] * fx
        return top * (1 - fy) + bottom * fy
    }

    /**
     * reference `_with_lightness_keep_chromaticity` (revision 1): L clipped to [0, 1], a and b scaled by
     * L'/L so hue and saturation are kept (linear RGB scales by (L'/L)³); output clipped to [0, 1].
     */
    private fun withLightnessKeepChromaticity(rgb: FloatArray, lightness: Double, original: Double, a: Double, b: Double, work: DoubleArray) {
        val target = lightness.coerceIn(0.0, 1.0)
        val ratio = target / max(original, 1e-6)
        ColourMath.oklabToLinear(target, a * ratio, b * ratio, work)
        for (c in 0 until 3) rgb[c] = linearToSrgb(work[c]).coerceIn(0.0, 1.0).toFloat()
    }

    /** reference `_with_lightness`: L clipped to [0, 1], a and b kept, output clipped to [0, 1]. */
    private fun withLightness(rgb: FloatArray, lightness: Double, a: Double, b: Double, work: DoubleArray) {
        ColourMath.oklabToLinear(lightness.coerceIn(0.0, 1.0), a, b, work)
        for (c in 0 until 3) rgb[c] = linearToSrgb(work[c]).coerceIn(0.0, 1.0).toFloat()
    }
}
