package com.lightlylabs.lightly.develop.auto

import kotlin.math.cbrt
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Android Auto's analysis (2026-10-06): proposes a correction from the photo's own statistics, then applies the iOS
 * guards (`CoreImageAutoGuards`, same thresholds and step-down ladders), so both platforms keep the same rules even
 * though the proposals come from different engines:
 * - **cast balance** only with a measured global cast (the least-coloured 20 % of mid-tones away from grey by ≥ 3),
 *   at the largest strength that reduces the cast without reversing it; vibrance is then not applied;
 * - **vibrance** stepped down until it adds no clipping;
 * - **exposure** (the tonal correction) only when the photo does not already span its range (p1 ≤ 0.15 and p99 ≥ 0.85),
 *   at the largest strength that adds ≤ 0.1 pp clipping and keeps a face's lightness (low-key ±5 L; backlit or
 *   underexposed may be lifted ≤ 20 L) and chroma (±15 %).
 *
 * Proposals (Android's own; Core Image's are not public): exposure maps the 99.5th-percentile luma, in linear light, to
 * [WHITE_TARGET] (a gain in [1, [MAX_EXPOSURE]], at most +1 EV: a photo without highlights may be low-key, not
 * underexposed, and a larger lift relit the dark studio portrait: an exposure loss is a linear scale, so this undoes it, and a photo with
 * real highlights keeps a gain near 1); vibrance is 0.3 − mean saturation, in [0, 0.3]; the balance gains move the
 * neutrals' mean linear colour toward grey at its own luminance, at most halfway ([MAX_BALANCE]).
 */
object AutoAnalysis {
    const val CAST_THRESHOLD = 3.0
    const val CLIP_TOLERANCE = 0.001
    const val SPAN_LOW = 0.15
    const val SPAN_HIGH = 0.85
    const val SKIN_LIGHTNESS_TOLERANCE = 5.0
    const val SKIN_CHROMA_TOLERANCE = 0.15
    const val BACKLIT_MARGIN = 10.0
    const val LOW_KEY_MARGIN = 15.0
    const val UNDEREXPOSED_P99 = 0.7
    const val LIFT_LIMIT = 20.0
    private val STEPS = doubleArrayOf(1.0, 0.75, 0.5, 0.25)
    /** Linear luma the 99.5th percentile is mapped to, and the largest exposure gain (+2 EV). */
    const val WHITE_TARGET = 0.9
    const val MAX_EXPOSURE = 2.0
    /**
     * The balance removes at most this share of the measured cast (in log gain): warm light in a sunset or a golden
     * backlit scene and skin-dominated frames read as a "cast" in the neutrals, and the iOS rule is to reduce a cast,
     * never force the photo neutral. Full correction moved such originals ΔE 8–9 (first evaluation).
     */
    const val MAX_BALANCE = 0.5

    /** A face, normalised to the image, origin top-left. */
    data class Face(val x: Double, val y: Double, val width: Double, val height: Double)

    /** sRGB RGBA8 pixels of the analysis proxy. */
    class Image(val width: Int, val height: Int, val rgba: ByteArray)

    class Stats(
        val highlightClip: Double, val shadowClip: Double, val p1: Double, val p99: Double, val p05: Double, val p995: Double,
        val medianLuma: Double, val meanSaturation: Double, val medianLightness: Double,
        val skinLightness: Double?, val skinChroma: Double?, val neutralCast: Pair<Double, Double>?,
        /** Mean linear RGB of the neutral samples (for the balance gains). */
        val neutralLinear: DoubleArray?,
    ) {
        val spansRange get() = p1 <= SPAN_LOW && p99 >= SPAN_HIGH
    }

    /** The analysis runs on a copy at most this long (box-averaged): ~13 measurement passes at 1024 px took 3–5 s on the emulator. */
    const val ANALYSIS_LONG_EDGE = 512

    fun analyse(photo: Image, faces: List<Face> = emptyList()): AutoCorrection {
        val image = reduced(photo, ANALYSIS_LONG_EDGE)
        val base = stats(image, faces, AutoCorrection())
        val notes = mutableListOf("original: p1 %.2f p99 %.2f clip %.2f%%/%.2f%%".format(base.p1, base.p99, base.highlightClip * 100, base.shadowClip * 100))
        var kept = AutoCorrection()
        val cast = base.neutralCast
        val hasCast = cast != null && hypot(cast.first, cast.second) >= CAST_THRESHOLD

        // Vibrance (not with a cast: it would amplify it).
        val vibranceProposal = (0.3 - base.meanSaturation).coerceIn(0.0, 0.3)
        if (hasCast) notes += "vibrance not applied: it would amplify the measured colour cast"
        else if (vibranceProposal > 0) {
            val t = largestStep { t -> addsNoClipping(stats(image, emptyList(), kept.copy(vibrance = vibranceProposal * t)), base) }
            if (t > 0) kept = kept.copy(vibrance = vibranceProposal * t)
            notes += "vibrance %.3f x%.2f (clipping guard)".format(vibranceProposal, t)
        }

        // Cast balance: only with a measured cast, as far as it reduces it without reversing it.
        if (hasCast && base.neutralLinear != null) {
            val n = base.neutralLinear
            val grey = 0.2126 * n[0] + 0.7152 * n[1] + 0.0722 * n[2]
            val full = DoubleArray(3) { (grey / max(n[it], 1e-6)).pow(MAX_BALANCE) }
            var strength = 0.0
            for (s in STEPS) {
                val trial = kept.copy(gains = full.map { it.pow(s) })
                val after = stats(image, emptyList(), trial).neutralCast ?: continue
                val before = hypot(cast!!.first, cast.second)
                val now = hypot(after.first, after.second)
                val reversed = after.first * cast.first + after.second * cast.second < 0 && now > CAST_THRESHOLD
                if (now < before && !reversed) { strength = s; break }
            }
            if (strength > 0) kept = kept.copy(gains = full.map { it.pow(strength) })
            notes += "cast balance strength %.2f: neutral cast a %.1f b %.1f".format(strength, cast!!.first, cast.second)
        } else {
            notes += cast?.let { "cast balance not applied: no global cast (neutrals a %.1f b %.1f)".format(it.first, it.second) }
                ?: "cast balance not applied: too few neutral pixels to judge a cast"
        }

        // Exposure: not when the photo spans its range; stepped down for clipping and the face (gain^t).
        if (base.spansRange) notes += "exposure not applied: the photo already spans its range"
        else {
            val proposal = proposeExposure(base)
            val t = if (proposal <= 1.0) 0.0 else largestStep { t ->
                val s = stats(image, faces, kept.copy(exposure = proposal.pow(t)))
                addsNoClipping(s, base) && keepsSkin(s, base, faces.isNotEmpty())
            }
            if (t > 0) kept = kept.copy(exposure = proposal.pow(t))
            notes += "exposure x%.2f at strength %.2f (clipping and skin guards)".format(proposal, t)
        }
        val result = stats(image, emptyList(), kept)
        notes += "result: p1 %.2f p99 %.2f clip %.2f%%/%.2f%%".format(result.p1, result.p99, result.highlightClip * 100, result.shadowClip * 100)
        return kept.copy(notes = notes)
    }

    /** The gain that maps the 99.5th-percentile luma (linear) to [WHITE_TARGET], in [1, MAX_EXPOSURE]. */
    internal fun proposeExposure(s: Stats): Double =
        (WHITE_TARGET / max(AutoCorrection.decode(s.p995), 1e-4)).coerceIn(1.0, MAX_EXPOSURE)

    private fun largestStep(ok: (Double) -> Boolean): Double {
        for (t in STEPS) if (ok(t)) return t
        return 0.0
    }

    private fun addsNoClipping(s: Stats, base: Stats) =
        s.highlightClip <= base.highlightClip + CLIP_TOLERANCE && s.shadowClip <= base.shadowClip + CLIP_TOLERANCE

    private fun keepsSkin(s: Stats, base: Stats, hasFaces: Boolean): Boolean {
        if (!hasFaces) return true
        val l0 = base.skinLightness ?: return true
        val c0 = base.skinChroma ?: return true
        val l1 = s.skinLightness ?: return true
        val c1 = s.skinChroma ?: return true
        if (kotlin.math.abs(c1 / max(c0, 1e-6) - 1) > SKIN_CHROMA_TOLERANCE) return false
        val lowKey = l0 >= base.medianLightness + LOW_KEY_MARGIN
        val needsLift = !lowKey && (l0 < base.medianLightness - BACKLIT_MARGIN || base.p99 < UNDEREXPOSED_P99)
        return if (needsLift) l1 >= l0 - SKIN_LIGHTNESS_TOLERANCE && l1 <= l0 + LIFT_LIMIT else kotlin.math.abs(l1 - l0) <= SKIN_LIGHTNESS_TOLERANCE
    }

    /**
     * The photo after [correction]: clipping (any channel ≥ 254 / all ≤ 1 of 255), luma percentiles and median, mean
     * saturation, CIELAB median lightness, the neutrals' cast (mean a, b of the least-coloured 20 % of mid-tones,
     * 20 < L < 90, every 4th pixel) and the inner 60 % of each face's lightness and chroma (as iOS `stats`).
     */
    fun stats(image: Image, faces: List<Face>, correction: AutoCorrection): Stats {
        val w = image.width
        val h = image.height
        val n = w * h
        val histogram = IntArray(256)
        val lHistogram = IntArray(101)
        var high = 0; var low = 0; var satSum = 0.0
        val chroma = ArrayList<Double>(); val aList = ArrayList<Double>(); val bList = ArrayList<Double>()
        val linR = ArrayList<Double>(); val linG = ArrayList<Double>(); val linB = ArrayList<Double>()
        val rgb = DoubleArray(3)
        val identity = correction.isIdentity
        val out = IntArray(3)
        val inFace = faceMask(w, h, faces)
        var skinL = 0.0; var skinA = 0.0; var skinB = 0.0; var skinN = 0
        for (p in 0 until n) {
            for (c in 0 until 3) rgb[c] = (image.rgba[p * 4 + c].toInt() and 0xff) / 255.0
            if (!identity) correction.apply(rgb)
            for (c in 0 until 3) out[c] = (rgb[c] * 255 + 0.5).toInt().coerceIn(0, 255)
            val hi = max(out[0], max(out[1], out[2])); val lo = min(out[0], min(out[1], out[2]))
            if (hi >= 254) high++
            if (hi <= 1) low++
            val y = (2126 * out[0] + 7152 * out[1] + 722 * out[2]) / 10000
            histogram[min(y, 255)]++
            satSum += (hi - lo) / 255.0
            val sampled = p % 4 == 0
            val face = inFace != null && inFace[p] && (p % w) % 2 == 0 && (p / w) % 2 == 0
            if (sampled || face) {
                val (l, a, b) = lab(out[0], out[1], out[2])
                if (sampled) {
                    lHistogram[l.toInt().coerceIn(0, 100)]++
                    if (l > 20 && l < 90) {
                        chroma += hypot(a, b); aList += a; bList += b
                        linR += LINEAR[out[0]]; linG += LINEAR[out[1]]; linB += LINEAR[out[2]]
                    }
                }
                if (face) { skinL += l; skinA += a; skinB += b; skinN++ }
            }
        }
        fun percentile(q: Double): Double {
            var acc = 0
            for (v in 0 until 256) { acc += histogram[v]; if (acc >= q * n) return v / 255.0 }
            return 1.0
        }
        val sampledCount = lHistogram.sum()
        var cast: Pair<Double, Double>? = null
        var neutralLinear: DoubleArray? = null
        if (chroma.size >= max(50, sampledCount / 10)) {
            val order = chroma.indices.sortedBy { chroma[it] }.take(chroma.size / 5)
            cast = order.sumOf { aList[it] } / order.size to order.sumOf { bList[it] } / order.size
            neutralLinear = doubleArrayOf(order.sumOf { linR[it] } / order.size, order.sumOf { linG[it] } / order.size, order.sumOf { linB[it] } / order.size)
        }
        var medianL = 50.0
        var acc = 0
        for (l in 0..100) { acc += lHistogram[l]; if (acc * 2 >= sampledCount) { medianL = l.toDouble(); break } }
        return Stats(high.toDouble() / n, low.toDouble() / n, percentile(0.01), percentile(0.99), percentile(0.005), percentile(0.995),
            percentile(0.5), satSum / n, medianL,
            if (skinN > 0) skinL / skinN else null, if (skinN > 0) hypot(skinA / skinN, skinB / skinN) else null, cast, neutralLinear)
    }

    /** [image] box-averaged by an integer factor so its long edge is at most [longEdge] (unchanged if already). */
    internal fun reduced(image: Image, longEdge: Int): Image {
        val factor = (max(image.width, image.height) + longEdge - 1) / longEdge
        if (factor <= 1) return image
        val w = image.width / factor
        val h = image.height / factor
        val out = ByteArray(w * h * 4)
        for (y in 0 until h) for (x in 0 until w) {
            for (c in 0 until 3) {
                var sum = 0
                for (dy in 0 until factor) for (dx in 0 until factor) sum += image.rgba[((y * factor + dy) * image.width + x * factor + dx) * 4 + c].toInt() and 0xff
                out[(y * w + x) * 4 + c] = ((sum + factor * factor / 2) / (factor * factor)).toByte()
            }
            out[(y * w + x) * 4 + 3] = -1
        }
        return Image(w, h, out)
    }

    /** The inner 60 % of each face box (iOS measures the same region). */
    private fun faceMask(w: Int, h: Int, faces: List<Face>): BooleanArray? {
        if (faces.isEmpty()) return null
        val mask = BooleanArray(w * h)
        for (f in faces) {
            val x0 = ((f.x + f.width * 0.2) * w).toInt().coerceIn(0, w); val x1 = ((f.x + f.width * 0.8) * w).toInt().coerceIn(0, w)
            val y0 = ((f.y + f.height * 0.2) * h).toInt().coerceIn(0, h); val y1 = ((f.y + f.height * 0.8) * h).toInt().coerceIn(0, h)
            for (y in y0 until y1) for (x in x0 until x1) mask[y * w + x] = true
        }
        return mask
    }

    private val LINEAR = DoubleArray(256) { AutoCorrection.decode(it / 255.0) }

    /** CIELAB (D65) of an 8-bit sRGB colour, as iOS `CoreImageAutoGuards.lab`. */
    fun lab(r: Int, g: Int, b: Int): Triple<Double, Double, Double> {
        val rl = LINEAR[r]; val gl = LINEAR[g]; val bl = LINEAR[b]
        fun f(t: Double) = if (t > 0.008856) cbrt(t) else 7.787 * t + 16.0 / 116
        val x = f((0.4124 * rl + 0.3576 * gl + 0.1805 * bl) / 0.95047)
        val y = f(0.2126 * rl + 0.7152 * gl + 0.0722 * bl)
        val z = f((0.0193 * rl + 0.1192 * gl + 0.9505 * bl) / 1.08883)
        return Triple(116 * y - 16, 500 * (x - y), 200 * (y - z))
    }

}
