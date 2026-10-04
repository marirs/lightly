package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.background.DepthEstimator
import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.background.SubjectSegmenter
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

/**
 * The last few model results of this process, keyed by the SHA-256 of the exact model input, so
 * reopening the same photo (or Background › Try again after a cancel) does not run depth, subject
 * separation or the people analysis again. In memory only: nothing about a photo is written to disk
 * here. A different input (another photo, another proxy size) is a different key, so a stale result
 * can never be returned for a changed image.
 */
class AnalysisCache<T>(private val capacity: Int = 2) {
    private val entries = LinkedHashMap<String, T>(capacity + 1, 0.75f, true)

    @Synchronized fun get(key: String): T? = entries[key]

    @Synchronized fun put(key: String, value: T) {
        entries[key] = value
        while (entries.size > capacity) entries.remove(entries.keys.first())
    }

    /** A cached outcome; a null value is a result too (separation's "no clear subject", no detector). */
    class Result<T>(val value: T?)

    companion object {
        fun key(bytes: ByteArray, vararg dims: Int): String {
            val digest = MessageDigest.getInstance("SHA-256")
            dims.forEach { digest.update(ByteBuffer.allocate(4).putInt(it).array()) }
            digest.update(bytes)
            return digest.digest().joinToString("") { "%02x".format(it) }
        }

        fun key(values: FloatArray): String {
            val buffer = ByteBuffer.allocate(values.size * 4).order(ByteOrder.LITTLE_ENDIAN)
            buffer.asFloatBuffer().put(values)
            return key(buffer.array(), values.size)
        }

        // Process-wide: the editor's environment is recreated with its Activity (rotation, fold).
        private val depthCache = AnalysisCache<FloatPlane>()
        private val subjectCache = AnalysisCache<Result<FloatPlane>>()
        private val peopleCache = AnalysisCache<Result<com.lightlylabs.lightly.vision.PeopleAnalysis>>()

        /** Depth: the same input tensor gives the same map. */
        fun depth(estimator: DepthEstimator, cache: AnalysisCache<FloatPlane> = depthCache): DepthEstimator {
            return DepthEstimator { input ->
                val key = key(input.tensor)
                cache.get(key) ?: estimator.estimate(input).also { cache.put(key, it) }
            }
        }

        /** Subject separation: the same pixels give the same matte, or the same "no clear subject". */
        fun subject(segmenter: SubjectSegmenter, cache: AnalysisCache<Result<FloatPlane>> = subjectCache): SubjectSegmenter {
            return SubjectSegmenter { rgba, width, height ->
                val key = key(rgba, width, height)
                (cache.get(key) ?: Result(segmenter.segment(rgba, width, height)).also { cache.put(key, it) }).value
            }
        }

        /** People: the same analysis image gives the same faces and people. */
        fun people(detector: PersonDetector, cache: AnalysisCache<Result<com.lightlylabs.lightly.vision.PeopleAnalysis>> = peopleCache): PersonDetector {
            return PersonDetector { image ->
                val key = key(image.pixels, image.width, image.height)
                (cache.get(key) ?: Result(detector.analyse(image)).also { cache.put(key, it) }).value
            }
        }
    }
}
