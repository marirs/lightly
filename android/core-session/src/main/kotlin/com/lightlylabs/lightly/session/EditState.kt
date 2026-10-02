package com.lightlylabs.lightly.session

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * EditState schema 2 (docs/m1/spec.md §3). An immutable snapshot of one committed edit. Field names are
 * the shared contract: iOS and Android must serialise the same JSON, so renaming a property here is
 * a contract change and must bump [EditState.CURRENT_SCHEMA].
 */
@Serializable
data class EditState(
    val schema: Int = CURRENT_SCHEMA,
    val source: SourceRef,
    val auto: AutoResult,
    /** At most one creative Look (Invariant R). `null` means "Auto only". */
    val look: LookRef?,
    /** Commit counter, monotonically increasing within a session; assigned by [EditSession]. */
    val revision: Long,
) {
    init {
        require(schema == CURRENT_SCHEMA) { "Unsupported EditState schema $schema (expected $CURRENT_SCHEMA)" }
        require(revision >= 0) { "revision must be non-negative, was $revision" }
    }

    /**
     * The state a transient preview renders: the committed state with [candidate] *replacing* the
     * Look. Never composes the candidate on top of the committed Look (fixes iOS defect §12e).
     * The revision is kept because a preview is not a commit.
     */
    fun withCandidateLook(candidate: LookRef?): EditState = copy(look = candidate)

    companion object {
        /**
         * 2: `look.lookVersion` became the Look pack's version string (was an Int in schema 1).
         * v3 differs: a schema 1 edit is no longer dropped. [SavedEdits] migrates it to schema 2
         * with `lookVersion = "legacy-v1-<n>"`, which never matches a pack version, so the Look
         * resolves as "changed" and is not rendered until the user accepts the current version.
         * Constructing an EditState directly still requires schema 2.
         */
        const val CURRENT_SCHEMA = 2
    }
}

/** The Original's identity. The fingerprint is what a recovery snapshot is validated against. */
@Serializable
data class SourceRef(
    /** Content URI on Android, PHAsset local identifier on iOS. Opaque to the session. */
    val assetId: String,
    val fingerprint: SourceFingerprint,
    /** EXIF orientation (1–8) of the Original as decoded. */
    val orientation: Int,
) {
    init {
        require(orientation in 1..8) { "EXIF orientation must be 1..8, was $orientation" }
    }
}

/**
 * `sha256(first 64 KiB) + byte size + pixel size` (spec §3). Hashing only the head keeps this
 * O(1) for 48 MP files; the size fields catch most edits that leave the head intact.
 */
@Serializable
data class SourceFingerprint(
    val headSha256: String,
    val byteSize: Long,
    val pixelWidth: Int,
    val pixelHeight: Int,
) {
    init {
        require(headSha256.length == 64 && headSha256.all { it in '0'..'9' || it in 'a'..'f' }) {
            "headSha256 must be 64 lowercase hex characters"
        }
        require(byteSize > 0) { "byteSize must be positive" }
        require(pixelWidth > 0 && pixelHeight > 0) { "pixel size must be positive" }
    }
}

/** Guardrail applied to the fused Auto LUT. Versioned so old edits re-render identically (§4.6). */
@Serializable
enum class AutoGuardrail {
    @SerialName("endpoint-v1")
    ENDPOINT_V1,
}

/**
 * The Auto correction (spec §3). Deterministic for an Original and model version; the weights are
 * stored so a saved session never silently re-runs a different model.
 */
@Serializable
data class AutoResult(
    val modelId: String,
    val modelVersion: String,
    /** Raw linear basis weights. A List (not FloatArray) so data-class equality is by value. */
    val weights: List<Float>,
    val guardrail: AutoGuardrail?,
    val strength: Float,
) {
    init {
        require(weights.size == WEIGHT_COUNT) { "Auto weights must have $WEIGHT_COUNT entries, had ${weights.size}" }
        require(weights.all { it.isFinite() }) { "Auto weights must be finite" }
        requireUnitStrength(strength, "Auto strength")
    }

    companion object {
        const val WEIGHT_COUNT = 3
        const val MODEL_ID_IA3DLUT = "ia3dlut"
    }
}

/**
 * A reference to one curated Look; the LUT itself lives in the Look pack, keyed by id + version.
 *
 * [lookVersion] is the pack's opaque version string (today the first 12 hex digits of the LUT's
 * sha256, see experiments/presets/look_pack/build_look_pack.py). It changes whenever the LUT's
 * pixels change, so a restored edit never silently replays a different Look under the same ID.
 * Schema 1 used a hand-numbered Int here; that is why [EditState.CURRENT_SCHEMA] is 2.
 */
@Serializable
data class LookRef(
    val lookId: String,
    val lookVersion: String,
    val strength: Float,
) {
    init {
        require(lookId.isNotBlank()) { "lookId must not be blank" }
        require(lookVersion.isNotBlank()) { "lookVersion must not be blank" }
        requireUnitStrength(strength, "Look strength")
    }
}

private fun requireUnitStrength(value: Float, label: String) {
    require(value.isFinite() && value in 0f..1f) { "$label must be in [0,1], was $value" }
}
