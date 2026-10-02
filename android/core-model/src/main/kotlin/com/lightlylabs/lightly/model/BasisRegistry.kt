package com.lightlylabs.lightly.model

import com.lightlylabs.lightly.render.lut.Lut3D
import java.io.File
import java.io.IOException
import java.security.MessageDigest

/** Identifies one model release. `modelVersion` changes whenever weights, basis or preprocessing change (§4.6). */
data class ModelKey(val modelId: String, val modelVersion: String)

/**
 * One installed basis-LUT file and the sha256 its model manifest pins. Bytes are read lazily, and
 * only when the version is first needed.
 */
class InstalledBasis(
    val key: ModelKey,
    val expectedSha256: String,
    val basisCount: Int = 3,
    val dimension: Int = Lut3D.CONTRACT_DIMENSION,
    private val readBytes: () -> ByteArray,
) {
    init {
        require(expectedSha256.length == 64 && expectedSha256.all { it in '0'..'9' || it in 'a'..'f' }) {
            "expectedSha256 for $key must be 64 lowercase hex characters"
        }
    }

    internal fun bytes(): ByteArray = readBytes()

    companion object {
        fun fromFile(key: ModelKey, file: File, expectedSha256: String): InstalledBasis =
            InstalledBasis(key, expectedSha256) { file.readBytes() }
    }
}

/** Why a model version's basis cannot be used. Each case is user-visible as "Auto unavailable". */
sealed interface BasisUnavailableReason {
    /** No basis for this (modelId, modelVersion) ships in this build. */
    data object NotInstalled : BasisUnavailableReason

    /** The file is present but is not the file the manifest pins (corrupt or tampered). */
    data class HashMismatch(val expectedSha256: String, val actualSha256: String) : BasisUnavailableReason

    data class Unreadable(val message: String) : BasisUnavailableReason
}

sealed interface BasisResolution {
    val key: ModelKey

    data class Available(override val key: ModelKey, val basis: BasisLuts) : BasisResolution

    data class Unavailable(override val key: ModelKey, val reason: BasisUnavailableReason) : BasisResolution
}

/**
 * All basis-LUT versions this build can render, keyed by (modelId, modelVersion).
 *
 * Codex M2 finding 4: a saved AutoResult must be fused with the basis of the version that produced
 * it. The registry never falls back to another version: an unknown key, or a file whose sha256 does
 * not match the manifest, is reported as [BasisResolution.Unavailable] and the caller turns Auto off
 * with a notice. Substituting "the closest" basis would silently change how an old edit looks.
 *
 * Verified bases are cached; failures are not, so they are re-checked on the next request.
 * Thread-safe (the develop path and the render path may resolve concurrently).
 */
class BasisRegistry(installed: List<InstalledBasis>) {
    private val byKey: Map<ModelKey, InstalledBasis> = installed.associateBy { it.key }
    private val verified = HashMap<ModelKey, BasisLuts>()

    init {
        require(byKey.size == installed.size) { "Duplicate basis registrations: ${installed.map { it.key }}" }
    }

    val installedKeys: Set<ModelKey> get() = byKey.keys

    fun resolve(key: ModelKey): BasisResolution = synchronized(verified) {
        verified[key]?.let { return BasisResolution.Available(key, it) }
        val entry = byKey[key] ?: return BasisResolution.Unavailable(key, BasisUnavailableReason.NotInstalled)

        val bytes = try {
            entry.bytes()
        } catch (failure: IOException) {
            return BasisResolution.Unavailable(key, BasisUnavailableReason.Unreadable(failure.message ?: failure.javaClass.simpleName))
        }
        val actual = sha256Hex(bytes)
        // Hash before parsing: a tampered file must never be interpreted, even if it happens to parse.
        if (actual != entry.expectedSha256) {
            return BasisResolution.Unavailable(key, BasisUnavailableReason.HashMismatch(entry.expectedSha256, actual))
        }
        val basis = try {
            BasisLuts.fromLittleEndianBytes(bytes, entry.basisCount, entry.dimension)
        } catch (malformed: IllegalArgumentException) {
            return BasisResolution.Unavailable(key, BasisUnavailableReason.Unreadable(malformed.message ?: "malformed basis"))
        }
        verified[key] = basis
        BasisResolution.Available(key, basis)
    }

    companion object {
        fun sha256Hex(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
