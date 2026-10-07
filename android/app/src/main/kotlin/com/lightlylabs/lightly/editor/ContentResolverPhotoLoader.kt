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
    override suspend fun loadForEditing(assetId: String): LoadedPhoto = loadFrom(assetId, keepCopy = true)

    override fun releaseEditingCopy() { editingCopy?.delete() }

    private suspend fun loadFrom(assetId: String, keepCopy: Boolean): LoadedPhoto = try {
        val uri = Uri.parse(assetId)
        val copy = if (keepCopy) copyOriginal(uri) else null
        decodeAll(uri, copy)
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
            if (!partial.renameTo(target)) { partial.delete(); return@withContext null }
            target
        } catch (failure: IOException) {
            partial.delete(); target.delete()
            null
        }
    }

    private suspend fun decodeAll(uri: Uri, copy: java.io.File? = null): LoadedPhoto = withContext(Dispatchers.IO) {
        val analysis = decoder.decodeForAnalysis(ImageDecoder.createSource(resolver, uri))
        val display = decoder.decodeForDisplay(ImageDecoder.createSource(resolver, uri), screenLongestPx)
        val byteSize = if (uri.scheme == "file") {
            if (!allowFileUris) throw IOException("Couldn't open this photo")
            uri.path?.let { java.io.File(it).length() }?.takeIf { it > 0 }
        } else {
            resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else null
            }
        } ?: throw IOException("Couldn't open this photo")
        val fingerprint = resolver.openInputStream(uri)?.use { stream ->
            SourceFingerprints.compute(stream, byteSize, analysis.originalSize.width, analysis.originalSize.height)
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
