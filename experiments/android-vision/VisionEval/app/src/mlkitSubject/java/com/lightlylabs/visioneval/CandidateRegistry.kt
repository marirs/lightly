package com.lightlylabs.visioneval

/** Candidates compiled into the `mlkitSubject` flavour. */
object CandidateRegistry {
    fun create(): List<VisionCandidate> = MlKitSubjectCandidate.all()
}
