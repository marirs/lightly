package com.lightlylabs.visioneval

/** Candidates compiled into the `mlkitFaceMesh` flavour. */
object CandidateRegistry {
    fun create(): List<VisionCandidate> = MlKitFaceMeshCandidate.all()
}
