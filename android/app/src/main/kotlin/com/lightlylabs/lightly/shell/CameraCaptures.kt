package com.lightlylabs.lightly.shell

import android.content.Context
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File

/**
 * Files the system camera writes into (ACTION_IMAGE_CAPTURE via TakePicture). They live in the app's
 * cache under `captures/`, shared with the camera app through this app's FileProvider
 * (res/xml/capture_paths.xml), so the capture never needs storage permissions and is not added to
 * the user's library by Lightly. Saving the edit uses Save copy, like any other photo.
 *
 * DEFERRED(slice 6): whether an unedited camera capture should also be kept in the library is a
 * product decision; today it stays private to Lightly and is replaced by the next capture.
 */
class CameraCaptures(private val context: Context) {
    private val directory: File get() = File(context.cacheDir, DIRECTORY).apply { mkdirs() }

    /**
     * A new, empty target for the camera. Earlier captures are deleted except [keep] (the photo the
     * editor currently has open, which a restore after process death must still be able to read).
     */
    fun newCaptureUri(keep: String?): Uri {
        directory.listFiles().orEmpty().filter { uriFor(it).toString() != keep }.forEach { it.delete() }
        val file = File(directory, "capture_${System.currentTimeMillis()}.jpg")
        return uriFor(file)
    }

    /** The camera was cancelled: remove the empty file it was offered. */
    fun discard(uri: String) {
        directory.listFiles().orEmpty().firstOrNull { uriFor(it).toString() == uri }?.delete()
    }

    private fun uriFor(file: File): Uri = FileProvider.getUriForFile(context, authority(context), file)

    companion object {
        private const val DIRECTORY = "captures"
        fun authority(context: Context) = "${context.packageName}.captures"
    }
}
