package com.lightlylabs.lightly.vision

import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/** A detection in normalised photo coordinates (top-left origin), with its keypoints. */
data class Detection(
    val score: Float,
    val xMin: Double,
    val yMin: Double,
    val xMax: Double,
    val yMax: Double,
    /** (x, y) pairs, normalised. BlazeFace: right eye, left eye (subject's), nose, mouth, right ear, left ear. */
    val keypoints: List<Pair<Double, Double>>,
) {
    val width get() = xMax - xMin
    val height get() = yMax - yMin
    val centreX get() = (xMin + xMax) / 2
    val centreY get() = (yMin + yMax) / 2

    fun iou(other: Detection): Double {
        val ix = max(0.0, min(xMax, other.xMax) - max(xMin, other.xMin))
        val iy = max(0.0, min(yMax, other.yMax) - max(yMin, other.yMin))
        val intersection = ix * iy
        val union = width * height + other.width * other.height - intersection
        return if (union > 0) intersection / union else 0.0
    }
}

/**
 * MediaPipe's SSD detector post-processing: SsdAnchorsCalculator, TensorsToDetectionsCalculator and
 * the WEIGHTED NonMaxSuppressionCalculator, with the parameters of each model's graph.
 */
class SsdDecoder(
    private val inputSize: Int,
    strides: List<Int>,
    /** Anchors per location for each stride group = aspect ratios (1) + 1 when interpolated_scale_aspect_ratio > 0. */
    interpolatedScaleAspectRatio: Double,
    private val numKeypoints: Int,
    private val minScore: Float,
    private val nmsThreshold: Double = 0.3,
) {
    /** Anchor centres (x, y), normalised; fixed_anchor_size = true, so every anchor's size is 1. */
    val anchors: List<Pair<Double, Double>> = buildAnchors(inputSize, strides, interpolatedScaleAspectRatio)

    private val coordsPerBox = 4 + 2 * numKeypoints

    /**
     * Decodes raw regressors (anchors × coords) and classifier logits (anchors), keeps scores ≥
     * [minScore], merges overlaps (weighted NMS), and removes the letterbox. Highest score first.
     */
    fun decode(regressors: FloatArray, logits: FloatArray, letterbox: Letterbox): List<Detection> {
        require(logits.size == anchors.size && regressors.size == anchors.size * coordsPerBox) {
            "expected ${anchors.size} anchors × $coordsPerBox, got ${logits.size} scores and ${regressors.size} values"
        }
        val scale = inputSize.toDouble()
        val candidates = ArrayList<Detection>()
        for (i in anchors.indices) {
            // score_clipping_thresh 100, sigmoid_score true.
            val score = (1.0 / (1.0 + exp(-logits[i].toDouble().coerceIn(-100.0, 100.0)))).toFloat()
            if (score < minScore) continue
            val (ax, ay) = anchors[i]
            val o = i * coordsPerBox
            // reverse_output_order: x before y, width before height.
            val xc = regressors[o] / scale + ax
            val yc = regressors[o + 1] / scale + ay
            val w = regressors[o + 2] / scale
            val h = regressors[o + 3] / scale
            val keypoints = List(numKeypoints) { k -> (regressors[o + 4 + 2 * k] / scale + ax) to (regressors[o + 5 + 2 * k] / scale + ay) }
            candidates += Detection(score, xc - w / 2, yc - h / 2, xc + w / 2, yc + h / 2, keypoints)
        }
        return weightedNms(candidates, nmsThreshold).map { d ->
            Detection(d.score, letterbox.removeX(d.xMin), letterbox.removeY(d.yMin), letterbox.removeX(d.xMax), letterbox.removeY(d.yMax),
                d.keypoints.map { (x, y) -> letterbox.removeX(x) to letterbox.removeY(y) })
        }
    }

    companion object {
        fun buildAnchors(inputSize: Int, strides: List<Int>, interpolatedScaleAspectRatio: Double): List<Pair<Double, Double>> {
            val anchors = ArrayList<Pair<Double, Double>>()
            var layer = 0
            while (layer < strides.size) {
                var lastSameStride = layer
                var perLocation = 0
                while (lastSameStride < strides.size && strides[lastSameStride] == strides[layer]) {
                    perLocation += 1 + if (interpolatedScaleAspectRatio > 0) 1 else 0
                    lastSameStride++
                }
                val featureMap = ceil(inputSize.toDouble() / strides[layer]).toInt()
                for (y in 0 until featureMap) for (x in 0 until featureMap) repeat(perLocation) {
                    anchors += ((x + 0.5) / featureMap) to ((y + 0.5) / featureMap)
                }
                layer = lastSameStride
            }
            return anchors
        }

        /**
         * WEIGHTED non-max suppression: the best remaining detection absorbs every detection whose IoU
         * with it exceeds [threshold]; its box and keypoints become their score-weighted mean, its
         * score stays the best one.
         */
        fun weightedNms(detections: List<Detection>, threshold: Double): List<Detection> {
            var remaining = detections.sortedByDescending { it.score }
            val out = ArrayList<Detection>()
            while (remaining.isNotEmpty()) {
                val top = remaining.first()
                val (cluster, rest) = remaining.partition { it.iou(top) > threshold }
                remaining = rest
                if (cluster.size <= 1) { out += top; continue }
                val total = cluster.sumOf { it.score.toDouble() }
                fun mean(value: (Detection) -> Double) = cluster.sumOf { value(it) * it.score } / total
                out += Detection(
                    top.score, mean { it.xMin }, mean { it.yMin }, mean { it.xMax }, mean { it.yMax },
                    top.keypoints.indices.map { k -> mean { it.keypoints[k].first } to mean { it.keypoints[k].second } },
                )
            }
            return out
        }
    }
}
