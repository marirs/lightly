package com.lightlylabs.lightly.background

/**
 * Subject separation (the matte shared by Change background and Focus & Blur), behind an interface.
 * DEFERRED(D3): the SDK (ML Kit Subject Segmentation or MediaPipe) is chosen only after the device
 * evaluation on the two dev phones; until then the app wires [PendingSubjectSegmenter] and every
 * feature that needs a matte shows the approved "Couldn't separate the subject" state. Nothing fakes a
 * matte (no ellipse, no saliency stand-in).
 */
fun interface SubjectSegmenter {
    /**
     * Soft matte in [0, 1] (1 = subject) at [width] × [height] for tightly packed RGBA8 pixels, or null
     * when the photo has no clear subject (the approved "No clear subject found" state).
     * @throws SegmentationUnavailableException when this build or device cannot separate subjects.
     */
    suspend fun segment(rgba: ByteArray, width: Int, height: Int): FloatPlane?
}

class SegmentationUnavailableException(reason: String) : Exception(reason)

object PendingSubjectSegmenter : SubjectSegmenter {
    override suspend fun segment(rgba: ByteArray, width: Int, height: Int): FloatPlane? =
        throw SegmentationUnavailableException("Subject segmentation is pending (D3: ML Kit / MediaPipe device evaluation)")
}
