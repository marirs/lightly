package com.lightlylabs.visioneval

/** Candidates compiled into the `mediapipe` flavour. */
object CandidateRegistry {
    fun create(): List<VisionCandidate> = MediaPipeCandidates.all()
}
