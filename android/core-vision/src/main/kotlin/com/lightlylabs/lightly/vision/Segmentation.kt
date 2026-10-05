package com.lightlylabs.lightly.vision

import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.background.PlaneOps
import com.lightlylabs.lightly.background.SegmentationUnavailableException
import com.lightlylabs.lightly.background.SubjectSegmenter
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Low-resolution model mattes brought to the analysis image: bilinear upsampling, then a guided filter
 * on the photo's luma so the edge follows the photo. iOS gets a full-resolution soft matte from Vision
 * (`generateScaledMaskForImage`); this is the Android equivalent.
 *
 * Radius 0.25 % of the long edge (4 px at 1600) and ε = 1e-3: on the evaluation portraits this kept or
 * raised the IoU against Vision's matte (e.g. 0.969 → 0.971) without softening it; larger radii only
 * blurred the edge (evaluation §4).
 */
object MatteRefiner {
    const val RADIUS_FRACTION = 0.0025
    const val EPSILON = 1e-3

    fun refine(lowRes: FloatPlane, image: RgbaImage): FloatPlane {
        val up = PlaneOps.resizeBilinear(lowRes, image.width, image.height)
        val radius = max(1, (max(image.width, image.height) * RADIUS_FRACTION).roundToInt())
        return PlaneOps.guidedFilter(luma(image), up, radius, EPSILON)
    }

    fun luma(image: RgbaImage): FloatPlane = FloatPlane(image.width, image.height, FloatArray(image.width * image.height) { i ->
        val o = i * 4
        (0.299f * (image.pixels[o].toInt() and 0xff) + 0.587f * (image.pixels[o + 1].toInt() and 0xff) + 0.114f * (image.pixels[o + 2].toInt() and 0xff)) / 255f
    })
}

/**
 * MediaPipe selfie segmenter (square, 256 × 256): the whole photo stretched, RGB in [0, 1], one
 * confidence channel (person). Used for people only: it marks 12–32 % of landscapes with nobody in
 * them, so it can never decide that a photo has no subject (evaluation §4).
 */
class PersonSegmenter(private val model: TensorModel) {
    /**
     * The person matte at [image]'s size. With [people] (normalised face and person boxes), only regions
     * of the matte that touch a detected person are kept: the segmenter also lights up bright streaks and
     * furniture (a window reflection on portrait_light_01: IoU against Vision 0.940 → 0.966), and Vision's
     * matte holds only the subject.
     */
    fun segment(image: RgbaImage, people: List<com.lightlylabs.lightly.session.NormalisedRect> = emptyList()): FloatPlane {
        val output = model.run(TensorSampler.nhwc(image, TensorSampler.stretched(image), INPUT, INPUT, ValueRange.UNIT))[0]
        require(output.size == INPUT * INPUT) { "expected a 256 × 256 confidence mask, got ${output.size} values" }
        val low = FloatPlane(INPUT, INPUT, output.copyOf())
        return MatteRefiner.refine(if (people.isEmpty()) low else keepTouching(low, people), image)
    }

    companion object {
        const val INPUT = 256
        /** Soft edges next to a kept region survive within this many model pixels. */
        private const val EDGE_KEEP_PX = 3

        /** Zeroes the confident regions (> 0.5, 4-connected) that touch none of [boxes], and their soft edges. */
        fun keepTouching(matte: FloatPlane, boxes: List<com.lightlylabs.lightly.session.NormalisedRect>): FloatPlane {
            val w = matte.width
            val h = matte.height
            val labels = IntArray(w * h)
            var count = 0
            val queue = IntArray(w * h)
            for (start in labels.indices) {
                if (labels[start] != 0 || matte.values[start] <= 0.5f) continue
                count++
                var head = 0
                var tail = 0
                queue[tail++] = start
                labels[start] = count
                while (head < tail) {
                    val p = queue[head++]
                    val x = p % w
                    val y = p / w
                    for ((nx, ny) in arrayOf(x - 1 to y, x + 1 to y, x to y - 1, x to y + 1)) {
                        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue
                        val n = ny * w + nx
                        if (labels[n] == 0 && matte.values[n] > 0.5f) { labels[n] = count; queue[tail++] = n }
                    }
                }
            }
            val kept = BooleanArray(count + 1)
            for (box in boxes) {
                val x0 = (box.x * w).toInt().coerceIn(0, w - 1)
                val x1 = ((box.x + box.width) * w).toInt().coerceIn(0, w - 1)
                val y0 = (box.y * h).toInt().coerceIn(0, h - 1)
                val y1 = ((box.y + box.height) * h).toInt().coerceIn(0, h - 1)
                for (y in y0..y1) for (x in x0..x1) kept[labels[y * w + x]] = true
            }
            kept[0] = false
            val keptMask = FloatPlane(w, h, FloatArray(w * h) { if (kept[labels[it]]) 1f else 0f })
            val near = com.lightlylabs.lightly.background.PlaneOps.dilateDisc(keptMask, 0.5f, EDGE_KEEP_PX)
            return FloatPlane(w, h, FloatArray(w * h) { if (near[it]) matte.values[it] else 0f })
        }
    }
}

/**
 * MODNet photographic portrait matting (github.com/ZHKKKe/MODNet, Apache-2.0; converted by
 * experiments/android-vision/scripts/convert_modnet.py): a real alpha matte with hair detail, used for people
 * instead of the selfie segmenter when bundled.
 *
 * Why: the selfie segmenter's 256 × 256 mask, upscaled to the photo, is soft over ~30 px all round the person.
 * Over a replaced background that band showed as a dark halo (portrait_deep_03 on a light colour) and let the
 * old background show through hair (red wall in portrait_medium_02). Measured offline against Vision's matte
 * on both portraits: IoU 0.965/0.971 → 0.986/0.977, edge-band error 0.237/0.249 → 0.191/0.192, red in the hair
 * on a dark replacement 7.0 → 4.5 levels before foreground estimation.
 *
 * Input: the photo letterboxed into 512 × 512 (long edge 512, centred, zero padding), area-downsampled first,
 * RGB in [−1, 1]. Output: alpha at 512 × 512; the photo's part is bilinearly resized back to the photo.
 */
class PortraitMatting(private val model: TensorModel) {
    fun segment(image: RgbaImage, people: List<com.lightlylabs.lightly.session.NormalisedRect> = emptyList()): FloatPlane {
        val scale = INPUT.toDouble() / max(image.width, image.height)
        val fitWidth = max(1, (image.width * scale).roundToInt())
        val fitHeight = max(1, (image.height * scale).roundToInt())
        val x0 = (INPUT - fitWidth) / 2
        val y0 = (INPUT - fitHeight) / 2
        val input = FloatArray(INPUT * INPUT * 3) { ValueRange.SIGNED.offset }   // padding: 0 in [0, 1]
        val fitted = areaDownsample(image, fitWidth, fitHeight)
        for (y in 0 until fitHeight) for (x in 0 until fitWidth) {
            val o = ((y + y0) * INPUT + (x + x0)) * 3
            for (c in 0 until 3) input[o + c] = fitted[(y * fitWidth + x) * 3 + c] * ValueRange.SIGNED.scale + ValueRange.SIGNED.offset
        }
        val output = model.run(input)[0]
        require(output.size == INPUT * INPUT) { "expected a 512 × 512 alpha matte, got ${output.size} values" }
        val crop = FloatPlane(fitWidth, fitHeight, FloatArray(fitWidth * fitHeight) { i ->
            output[(i / fitWidth + y0) * INPUT + (i % fitWidth + x0)].coerceIn(0f, 1f)
        })
        val kept = if (people.isEmpty()) crop else PersonSegmenter.keepTouching(crop, people)
        return PlaneOps.resizeBilinear(kept, image.width, image.height)
    }

    companion object {
        const val INPUT = 512

        /** Box (area) downsampling to [width] × [height], RGB in [0, 1]: what OpenCV INTER_AREA does for these ratios. */
        fun areaDownsample(image: RgbaImage, width: Int, height: Int): FloatArray {
            val out = FloatArray(width * height * 3)
            for (y in 0 until height) {
                val sy0 = y * image.height / height
                val sy1 = max(sy0 + 1, (y + 1) * image.height / height)
                for (x in 0 until width) {
                    val sx0 = x * image.width / width
                    val sx1 = max(sx0 + 1, (x + 1) * image.width / width)
                    var r = 0f; var g = 0f; var b = 0f
                    for (sy in sy0 until sy1) for (sx in sx0 until sx1) {
                        r += image.channel(sx, sy, 0); g += image.channel(sx, sy, 1); b += image.channel(sx, sy, 2)
                    }
                    val n = ((sy1 - sy0) * (sx1 - sx0)).toFloat()
                    val o = (y * width + x) * 3
                    out[o] = r / n; out[o + 1] = g / n; out[o + 2] = b / n
                }
            }
            return out
        }
    }
}

/**
 * U²-Netp (xuebinqin/U-2-Net, Apache-2.0), class-agnostic salient-object segmentation: the photo
 * resized to 320 × 320, divided by its maximum, ImageNet mean/std, NCHW (u2net_test.py RescaleT(320) +
 * ToTensorLab(flag=0)); output 1 × 1 × 320 × 320 sigmoid saliency.
 *
 * DEFERRED(subject model): the LiteRT conversion awaits the owner's permission
 * (docs/v1/android-vision-evaluation.md §5). Until a converted file is bundled, the app never builds
 * this class, and the "no clear subject" thresholds below are placeholders that must be calibrated on
 * the evaluation fixtures (boat, swan: subject; lake, field, sunset: none) before use.
 */
class SubjectSaliency(private val model: TensorModel) {
    /** The refined saliency matte, or null when the photo has no clear subject. */
    fun segment(image: RgbaImage): FloatPlane? {
        val output = model.run(input(image))[0]
        require(output.size == INPUT * INPUT) { "expected a 320 × 320 saliency map, got ${output.size} values" }
        val low = FloatPlane(INPUT, INPUT, output.copyOf())
        if (!hasClearSubject(low)) return null
        return MatteRefiner.refine(low, image)
    }

    fun input(image: RgbaImage): FloatArray {
        // RescaleT(320): stretched; skimage resize ≈ bilinear for downscaling photos of this size.
        val rgb = TensorSampler.nhwc(image, TensorSampler.stretched(image), INPUT, INPUT, ValueRange.UNIT)
        val maximum = rgb.maxOrNull()?.takeIf { it > 0f } ?: 1f
        val plane = INPUT * INPUT
        val out = FloatArray(3 * plane)
        for (i in 0 until plane) for (c in 0 until 3) out[c * plane + i] = (rgb[i * 3 + c] / maximum - MEAN[c]) / STD[c]
        return out
    }

    companion object {
        const val INPUT = 320
        private val MEAN = floatArrayOf(0.485f, 0.456f, 0.406f)
        private val STD = floatArrayOf(0.229f, 0.224f, 0.225f)

        /** PENDING calibration (see the class note): area of confident saliency and its peak. */
        const val MIN_SUBJECT_AREA = 0.01f
        const val MIN_PEAK = 0.5f

        fun hasClearSubject(matte: FloatPlane): Boolean {
            val confident = matte.values.count { it >= 0.5f }.toFloat() / matte.values.size
            return confident >= MIN_SUBJECT_AREA && (matte.values.maxOrNull() ?: 0f) >= MIN_PEAK
        }
    }
}

/**
 * Background's subject separation (core-background [SubjectSegmenter]) from the people analysis, the
 * person matte and the class-agnostic subject model, matching iOS's Vision foreground-instance matte:
 * - every subject the class-agnostic model finds, people included, is the subject;
 * - people found by the people analysis are added from the person matte, which follows hair and
 *   clothing better than a saliency map;
 * - with no class-agnostic model in this build, a photo with people uses the person matte alone, and a
 *   photo without people cannot be judged: [SegmentationUnavailableException], the approved
 *   "Couldn't separate the subject" state, never a guessed "No clear subject found".
 */
class VisionSubjectSegmenter(
    private val people: (RgbaImage) -> PeopleAnalysis,
    private val personSegmenter: () -> PersonSegmenter?,
    private val subjectSaliency: () -> SubjectSaliency?,
    /** MODNet when bundled: the person matte with hair detail (preferred over [personSegmenter]). */
    private val portraitMatting: () -> PortraitMatting? = { null },
) : SubjectSegmenter {
    override suspend fun segment(rgba: ByteArray, width: Int, height: Int): FloatPlane? {
        val image = RgbaImage(width, height, rgba)
        val analysis = people(image)
        val personMatte = if (analysis.hasPerson) {
            val boxes = analysis.faces.map { it.box } + analysis.people
            portraitMatting()?.segment(image, boxes)
                ?: (personSegmenter() ?: throw SegmentationUnavailableException("No person segmenter in this build")).segment(image, boxes)
        } else null
        val saliency = subjectSaliency()
        if (saliency == null) {
            return personMatte ?: throw SegmentationUnavailableException("No class-agnostic subject model in this build (evaluation §5)")
        }
        val subject = saliency.segment(image)
        return when {
            subject == null -> personMatte
            personMatte == null -> subject
            else -> FloatPlane(width, height, FloatArray(width * height) { max(subject.values[it], personMatte.values[it]) })
        }
    }
}
