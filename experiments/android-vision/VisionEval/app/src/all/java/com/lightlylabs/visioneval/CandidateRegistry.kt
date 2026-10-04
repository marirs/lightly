package com.lightlylabs.visioneval

/** Candidates compiled into the `all` flavour. */
object CandidateRegistry {
    fun create(): List<VisionCandidate> = MlKitFaceCandidate.all() + MlKitFaceMeshCandidate.all() + MediaPipeCandidates.all().filter { it.kind == CandidateKind.FACE } +
        MlKitSelfieCandidate.all() + MlKitSubjectCandidate.all() + MediaPipeCandidates.all().filter { it.kind == CandidateKind.SEGMENTATION }
}
