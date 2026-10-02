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
    private val screenLongestPx: Int,
) : PhotoLoader {

    override suspend fun load(assetId: String): LoadedPhoto = try {
        decodeAll(Uri.parse(assetId))
    } catch (failure: Exception) {
        // A restore after process death reads a URI whose grant may be gone (never persisted, or
        // revoked) or whose item was deleted. Report that distinctly so the editor can offer to
        // choose the photo again (Codex finding 4). CancellationException is neither, so it passes.
        if (PhotoAccessLostException.isAccessLoss(failure)) throw PhotoAccessLostException(failure) else throw failure
    }

    private suspend fun decodeAll(uri: Uri): LoadedPhoto = withContext(Dispatchers.IO) {
        val analysis = decoder.decodeForAnalysis(ImageDecoder.createSource(resolver, uri))
        val display = decoder.decodeForDisplay(ImageDecoder.createSource(resolver, uri), screenLongestPx)
        val byteSize = resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else null
        } ?: throw IOException("Couldn't open this photo")
        val fingerprint = resolver.openInputStream(uri)?.use { stream ->
            SourceFingerprints.compute(stream, byteSize, analysis.originalSize.width, analysis.originalSize.height)
        } ?: throw IOException("Couldn't open this photo")
        LoadedPhoto(
            // ImageDecoder already applied EXIF orientation, so the decoded frames are upright (1).
            source = SourceRef(assetId = uri.toString(), fingerprint = fingerprint, orientation = 1),
            analysis = analysis.image,
            display = display.image,
            fullResolution = FullResolutionSource {
                withContext(Dispatchers.IO) {
                    decoder.decode(ImageDecoder.createSource(resolver, uri)) { original -> original.also(DecodeTargets::requireDecodable) }.image
                }
            },
        )
    }
}
