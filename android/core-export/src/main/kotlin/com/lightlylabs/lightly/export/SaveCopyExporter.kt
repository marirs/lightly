package com.lightlylabs.lightly.export

import java.io.IOException
import java.io.OutputStream

/**
 * Encodes one rendered image as JPEG into [sink]. Injected so tests can count calls: spec D9 says
 * the JPEG is encoded exactly once per export, and previews are never encoded.
 */
fun interface JpegEncoder<in I> {
    fun encode(image: I, quality: Int, sink: OutputStream)
}

/** What to create in the library. The copy is always a new asset (D8); there is no overwrite. */
data class NewImageSpec(
    val displayName: String,
    val mimeType: String = "image/jpeg",
    /** Under the shared Pictures collection, so the copy shows up next to camera photos. */
    val relativePath: String = "Pictures/Lightly",
    val dateTakenMillis: Long? = null,
)

/**
 * The few MediaStore operations the save path needs. [H] is the row handle (a content `Uri` in the
 * app; a plain value in JVM tests, where android.net.Uri is unavailable).
 */
interface MediaStoreGateway<H> {
    /** Inserts a new row with IS_PENDING=1 so no other app sees a half-written file. */
    fun insertPending(spec: NewImageSpec): H?

    /** Opens the new row's file for writing ("w"). Only ever called with a handle from [insertPending]. */
    fun openForWrite(handle: H): OutputStream

    /** Sets IS_PENDING=0. Returns false if the row was not updated. */
    fun publish(handle: H): Boolean

    fun delete(handle: H)
}

/** Failure categories mapped to the spec §5.4 messages. The edit state is kept in every case. */
sealed class SaveCopyFailure(message: String, cause: Throwable?) : Exception(message, cause) {
    class PermissionDenied(cause: Throwable) : SaveCopyFailure("Permission denied while saving", cause)
    class OutOfStorage(cause: Throwable) : SaveCopyFailure("Out of storage while saving", cause)
    class InsertRejected : SaveCopyFailure("MediaStore did not create a row", null)
    class WriteFailed(cause: Throwable) : SaveCopyFailure("Writing the JPEG failed", cause)
    class PublishFailed : SaveCopyFailure("Clearing IS_PENDING failed", null)
}

/**
 * Save copy (spec §5.4 steps 4–5, Android): insert pending → open → encode once → close →
 * IS_PENDING=0. On any failure after the insert, the pending row is deleted so no partial asset is
 * left behind. Nothing is retried here: retry is user-initiated (spec §5.6) and re-runs the export.
 *
 * The Original is never opened for write: the exporter only writes to the row it just inserted,
 * and [save] refuses a target equal to the source handle.
 *
 * Blocking; call it off the main thread. Not cancellable once started (spec §5.4 step 8: encode
 * and write are not cancellable, to avoid partial assets).
 */
class SaveCopyExporter<H, I>(
    private val gateway: MediaStoreGateway<H>,
    private val encoder: JpegEncoder<I>,
    private val quality: Int = DEFAULT_QUALITY,
) {
    init {
        require(quality in 1..100) { "JPEG quality must be 1..100, was $quality" }
    }

    fun save(source: H, spec: NewImageSpec, rendered: I): H {
        val target = try {
            gateway.insertPending(spec)
        } catch (denied: SecurityException) {
            throw SaveCopyFailure.PermissionDenied(denied)
        } ?: throw SaveCopyFailure.InsertRejected()

        // Defence in depth: MediaStore never hands back an existing row on insert, but if a gateway
        // ever did, writing to it would modify the user's Original (D8). Deliberately no cleanup
        // either: "deleting the pending row" would delete the Original.
        check(target != source) { "MediaStore returned the source row as the insert target; refusing to write" }

        try {
            gateway.openForWrite(target).use { sink -> encoder.encode(rendered, quality, sink) }
            if (!gateway.publish(target)) throw SaveCopyFailure.PublishFailed()
            return target
        } catch (failure: Throwable) {
            deletePendingQuietly(target, failure)
            throw classify(failure)
        }
    }

    /** Cleanup must not replace the original error: a failed delete is attached as suppressed. */
    private fun deletePendingQuietly(target: H, original: Throwable) {
        try {
            gateway.delete(target)
        } catch (cleanupFailure: Throwable) {
            original.addSuppressed(cleanupFailure)
        }
    }

    private fun classify(failure: Throwable): Throwable = when {
        failure is SaveCopyFailure -> failure
        failure is SecurityException -> SaveCopyFailure.PermissionDenied(failure)
        failure is IOException && failure.isOutOfSpace() -> SaveCopyFailure.OutOfStorage(failure)
        failure is IOException -> SaveCopyFailure.WriteFailed(failure)
        else -> failure // programming errors are not user-facing save failures
    }

    private fun Throwable.isOutOfSpace(): Boolean {
        val text = generateSequence(this) { it.cause }.mapNotNull { it.message }.joinToString(" ")
        return "ENOSPC" in text || "No space left" in text
    }

    companion object {
        /** Spec §5.4: quality 0.92. */
        const val DEFAULT_QUALITY = 92
    }
}
