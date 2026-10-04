package com.lightlylabs.visioneval

/** Candidates compiled into the `mlkitFace` flavour. */
object CandidateRegistry {
    fun create(): List<VisionCandidate> = MlKitFaceCandidate.all()
}
