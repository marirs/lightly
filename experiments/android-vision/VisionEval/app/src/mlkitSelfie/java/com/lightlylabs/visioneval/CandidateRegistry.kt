package com.lightlylabs.visioneval

/** Candidates compiled into the `mlkitSelfie` flavour. */
object CandidateRegistry {
    fun create(): List<VisionCandidate> = MlKitSelfieCandidate.all()
}
