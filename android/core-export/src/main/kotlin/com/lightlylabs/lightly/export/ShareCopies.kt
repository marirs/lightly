package com.lightlylabs.lightly.export

import java.io.File
import java.io.OutputStream

/**
 * Share's copies of saved files, in an app-private cache folder exposed only through the app's
 * FileProvider. One copy is kept (the latest save): the folder is emptied when a new save starts. The
 * copy holds the saved file's bytes exactly, so the share target gets the same pixels and the same
 * metadata policy as the saved copy (MediaStore would strip GPS from readers without
 * ACCESS_MEDIA_LOCATION, so the saved asset's own URI is not byte-exact for "Include location").
 */
class ShareCopies(private val directory: File) : ShareCopySink<String> {
    override fun open(saved: String): OutputStream? {
        directory.mkdirs()
        directory.listFiles()?.forEach { it.delete() }
        return fileFor(saved).outputStream()
    }

    override fun discard(saved: String) {
        fileFor(saved).delete()
    }

    /** The share copy of [saved], or null when there is none (another save replaced it, or the cache was cleared). */
    fun existingFor(saved: String): File? = fileFor(saved).takeIf { it.isFile && it.length() > 0 }

    private fun fileFor(saved: String) = File(directory, "Lightly_${saved.substringAfterLast('/').filter { it.isLetterOrDigit() }.ifEmpty { "copy" }}.jpg")
}
