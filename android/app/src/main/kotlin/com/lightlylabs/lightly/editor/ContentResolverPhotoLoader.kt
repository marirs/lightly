package com.lightlylabs.lightly.editor

import android.content.ContentResolver
import android.graphics.ImageDecoder
import android.net.Uri
import android.provider.OpenableColumns
import com.lightlylabs.lightly.decode.DecodeTargets
import com.lightlylabs.lightly.decode.ProxyDecoder
import com.lightlylabs.lightly.export.FullResolutionSource
import com.lightlylabs.lightly.session.SourceFingerprints
import com.lightlylabs.lightly.session.SourceRef
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException

/** Production [PhotoLoader]: analysis decode, display proxy and fingerprint from a content URI. */
class ContentResolverPhotoLoader(
    private val resolver: ContentResolver,
    private val decoder: ProxyDecoder,
    /** Long edge of the display proxy (the preview render input). */
    private val screenLongestPx: Int,
    /**
     * Debug builds only: also open `file://` URIs, which the scripted emulator comparison uses to open
     * the approved reference photos from the app's own external files folder (no picker, no permission).
     */
    private val allowFileUris: Boolean = false,
    /**
     * Where [loadForEditing] keeps its private copy of the edited photo's original bytes (app storage, not backed up);
     * null keeps no copy. One file, replaced by the next photo opened for editing and removed by [releaseEditingCopy].
     */
    private val editingCopy: java.io.File? = null,
) : PhotoLoader {

    override suspend fun load(assetId: String): LoadedPhoto = loadFrom(assetId, keepCopy = false)

    /**
     * v3 differs from the first Android build (A11, 2026-10-07): the photo being edited is read once into a private copy,
     * and Save copy and the embedded-depth read use that copy. Deleting the photo (or losing access to it) while it is
     * being edited no longer fails every Save copy ("Couldn't save the copy", whose Try again could never succeed); iOS
     * keeps the original's bytes in its session the same way. If the copy cannot be made, the photo is read as before.
     */
    override suspend fun loadForEditing(assetId: String, recovering: Boolean): LoadedPhoto {
        // Session recovery after the process was ended: the copy made when the photo was opened is still the edited
        // photo's original, and the photo itself may be gone by now, so the copy is read, not the URI.
        if (recovering) keptCopyFor(assetId)?.let { kept -> return decodeAll(Uri.parse(assetId), kept, fromCopyOnly = true) }
        return loadFrom(assetId, keepCopy = true)
    }

    override fun releaseEditingCopy() {
        editingCopy?.delete()
        editingCopy?.let(::ownerFile)?.delete()
    }

    /** The kept copy when it was made for [assetId] (its owner file names the photo), else null. */
    internal fun keptCopyFor(assetId: String): java.io.File? {
        val copy = editingCopy?.takeIf { it.isFile } ?: return null
        val owner = ownerFile(copy).takeIf { it.isFile }?.readText() ?: return null
        return copy.takeIf { owner == assetId }
    }

    private fun ownerFile(copy: java.io.File) = java.io.File(copy.parentFile, copy.name + ".asset")

    private suspend fun loadFrom(assetId: String, keepCopy: Boolean): LoadedPhoto = try {
        val uri = Uri.parse(assetId)
        val copy = if (keepCopy) copyOriginal(uri) else null
        decodeAll(uri, copy, fromCopyOnly = copy != null)
    } catch (failure: Exception) {
        // A restore after process death reads a URI whose grant may be gone (never persisted, or
        // revoked) or whose item was deleted. Report that distinctly so the editor can offer to
        // choose the photo again (Codex finding 4). CancellationException is neither, so it passes.
        if (PhotoAccessLostException.isAccessLoss(failure)) throw PhotoAccessLostException(failure) else throw failure
    }

    /** Copies the original's bytes to [editingCopy]; null (and no file) when there is no copy location or it fails. */
    internal suspend fun copyOriginal(uri: Uri): java.io.File? = withContext(Dispatchers.IO) {
        val target = editingCopy ?: return@withContext null
        if (uri.scheme == "file" && !allowFileUris) return@withContext null
        val partial = java.io.File(target.parentFile, target.name + ".partial")
        try {
            target.parentFile?.mkdirs()
            resolver.openInputStream(uri)?.use { input -> partial.outputStream().use { input.copyTo(it) } } ?: return@withContext null
            ownerFile(target).delete()
            if (!partial.renameTo(target)) { partial.delete(); return@withContext null }
            ownerFile(target).writeText(uri.toString())
            target
        } catch (failure: IOException) {
            partial.delete(); target.delete(); ownerFile(target).delete()
            null
        }
    }

    /**
     * [fromCopyOnly]: every read (decodes, size, fingerprint) comes from [copy], the same bytes as the photo, so the
     * fingerprint matches the one recorded at the first open and a restore needs no access to the photo.
     */
    private suspend fun decodeAll(uri: Uri, copy: java.io.File? = null, fromCopyOnly: Boolean = false): LoadedPhoto = withContext(Dispatchers.IO) {
        fun source(): ImageDecoder.Source = if (fromCopyOnly && copy != null) ImageDecoder.createSource(copy) else ImageDecoder.createSource(resolver, uri)
        val analysis = decoder.decodeForAnalysis(source())
        val display = decoder.decodeForDisplay(source(), screenLongestPx)
        val byteSize = (if (fromCopyOnly && copy != null) copy.length().takeIf { it > 0 } else if (uri.scheme == "file") {
            if (!allowFileUris) throw IOException("Couldn't open this photo")
            uri.path?.let { java.io.File(it).length() }?.takeIf { it > 0 }
        } else {
            resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else null
            }
        }) ?: throw IOException("Couldn't open this photo")
        val stream = if (fromCopyOnly && copy != null) copy.inputStream() else resolver.openInputStream(uri)
        val fingerprint = stream?.use { input ->
            SourceFingerprints.compute(input, byteSize, analysis.originalSize.width, analysis.originalSize.height)
        } ?: throw IOException("Couldn't open this photo")
        LoadedPhoto(
            // ImageDecoder already applied EXIF orientation, so the decoded frames are upright (1).
            source = SourceRef(assetId = uri.toString(), fingerprint = fingerprint, orientation = 1),
            analysis = analysis.image,
            display = display.image,
            readOriginal = {
                withContext(Dispatchers.IO) {
                    copy?.takeIf { it.isFile }?.readBytes() ?: resolver.openInputStream(uri)?.use { it.readBytes() } ?: ByteArray(0)
                }
            },
            fullResolution = FullResolutionSource {
                withContext(Dispatchers.IO) {
                    val source = copy?.takeIf { it.isFile }?.let { ImageDecoder.createSource(it) } ?: ImageDecoder.createSource(resolver, uri)
                    decoder.decode(source) { original -> original.also(DecodeTargets::requireDecodable) }.image
                }
            },
        )
    }
}
