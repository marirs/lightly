package com.lightlylabs.lightly.session

/** Fixed values shared by the session tests. Kept literal so golden JSON stays readable. */
object SessionFixtures {
    val fingerprint = SourceFingerprint(
        headSha256 = "ab".repeat(32),
        byteSize = 1_048_576,
        pixelWidth = 4032,
        pixelHeight = 3024,
    )
    val source = SourceRef(assetId = "content://media/picker/0/42", fingerprint = fingerprint, orientation = 6)
    val auto = AutoResult(
        modelId = AutoResult.MODEL_ID_IA3DLUT,
        modelVersion = "research-fivek-1",
        weights = listOf(1.5f, -0.25f, -0.75f),
        guardrail = AutoGuardrail.ENDPOINT_V1,
        strength = 0.75f,
    )
    val portra = LookRef(lookId = "film.portra", lookVersion = 2, strength = 0.8f)
    val warmGolden = LookRef(lookId = "warm.golden", lookVersion = 1, strength = 1f)
    val mono = LookRef(lookId = "mono.silver", lookVersion = 1, strength = 1f)

    fun newSession(capacity: Int = UndoStack.DEFAULT_CAPACITY): EditSession =
        EditSession.start(source, auto, capacity)
}
