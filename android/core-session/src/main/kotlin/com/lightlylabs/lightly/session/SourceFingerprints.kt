package com.lightlylabs.lightly.session

import java.io.InputStream
import java.security.MessageDigest

object SourceFingerprints {
    /** Spec §3: only the first 64 KiB of the encoded file are hashed. */
    const val HEAD_BYTES: Int = 64 * 1024

    /**
     * Reads at most [HEAD_BYTES] from [encodedFile] (the caller owns and closes the stream) and
     * returns the fingerprint. [byteSize] comes from the provider's size column rather than from
     * reading the stream to the end, so a 48 MP file is never read in full just to identify it.
     */
    fun compute(encodedFile: InputStream, byteSize: Long, pixelWidth: Int, pixelHeight: Int): SourceFingerprint {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(8 * 1024)
        var remaining = HEAD_BYTES
        while (remaining > 0) {
            val read = encodedFile.read(buffer, 0, minOf(buffer.size, remaining))
            if (read < 0) break
            digest.update(buffer, 0, read)
            remaining -= read
        }
        val hex = digest.digest().joinToString(separator = "") { byte -> "%02x".format(byte) }
        return SourceFingerprint(hex, byteSize, pixelWidth, pixelHeight)
    }
}
