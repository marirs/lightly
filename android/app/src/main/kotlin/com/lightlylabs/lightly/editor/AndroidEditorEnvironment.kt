package com.lightlylabs.lightly.editor

import android.content.ContentResolver
import android.content.Context
import android.graphics.ImageDecoder
import android.net.Uri
import android.provider.OpenableColumns
import com.lightlylabs.lightly.decode.DecodeTargets
import com.lightlylabs.lightly.decode.ProxyDecoder
import com.lightlylabs.lightly.export.BitmapExportFrame
import com.lightlylabs.lightly.export.BitmapFrameJpegEncoder
import com.lightlylabs.lightly.export.ContentResolverGateway
import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.FullResolutionSource
import com.lightlylabs.lightly.export.MediaStoreGateway
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.export.SaveCopyExporter
import com.lightlylabs.lightly.model.BasisRegistry
import com.lightlylabs.lightly.model.RegistryAutoLutResolver
import com.lightlylabs.lightly.render.lut.CpuLutPassRenderer
import com.lightlylabs.lightly.session.SourceFingerprints
import com.lightlylabs.lightly.session.SourceRef
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.withContext
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.Executors

/**
 * Production wiring of [EditorEnvironment] for the M2 shell.
 *
 * Honest about what is missing:
 * - **Auto:** no inference engine ships (ONNX Runtime PENDING on device) and no basis LUT ships
 *   (the research basis must not be bundled), so develop reports DevelopFailed and the user
 *   continues with "Use original". Tests inject a fake model and a test basis instead.
 * - **Preview renderer:** the CPU reference ([CpuLutPassRenderer]) on the display proxy. The GLES
 *   renderer (:core-render-gl) is not wired until it has been validated on Adreno/Mali (PENDING);
 *   swapping it in only changes [EditorEnvironment.previewRenderer] and the render thread.
 * - **Looks:** procedural placeholders ([PlaceholderLookBook]), not the curated look-book (M3).
 */
object AndroidEditorEnvironment {

    /** One thread owns rendering (it will own the EGL context once GL is wired). */
    private val renderDispatcher = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "lightly-render") }.asCoroutineDispatcher()

    fun create(context: Context, screenLongestPx: Int): EditorEnvironment {
        val resolver = context.applicationContext.contentResolver
        val decoder = ProxyDecoder()
        val gateway = UriStringGateway(ContentResolverGateway(resolver))
        return EditorEnvironment(
            photoLoader = PhotoLoader { assetId -> load(resolver, decoder, Uri.parse(assetId), screenLongestPx) },
            autoDeveloper = AutoDeveloper { _, _ ->
                DevelopResult.Failed("Auto enhancement isn't available in this build yet.")
            },
            autoResolver = RegistryAutoLutResolver(BasisRegistry(installed = emptyList())),
            lookBook = PlaceholderLookBook.create(),
            previewRenderer = CpuLutPassRenderer,
            renderDispatcher = renderDispatcher,
            exporter = ExportCoordinator(
                renderer = CpuLutPassRenderer,
                saver = SaveCopyExporter(gateway, BitmapFrameJpegEncoder()),
                frameFactory = BitmapExportFrame.factory,
                renderDispatcher = renderDispatcher,
            ),
            newImageSpec = { source -> NewImageSpec(displayName = "Lightly_${System.currentTimeMillis()}.jpg") },
        )
    }

    private suspend fun load(resolver: ContentResolver, decoder: ProxyDecoder, uri: Uri, screenLongestPx: Int): LoadedPhoto =
        withContext(Dispatchers.IO) {
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

    /** The editor keys assets by string; MediaStore by Uri. */
    private class UriStringGateway(private val delegate: ContentResolverGateway) : MediaStoreGateway<String> {
        override fun insertPending(spec: NewImageSpec): String? = delegate.insertPending(spec)?.toString()
        override fun openForWrite(handle: String): OutputStream = delegate.openForWrite(Uri.parse(handle))
        override fun publish(handle: String): Boolean = delegate.publish(Uri.parse(handle))
        override fun delete(handle: String) = delegate.delete(Uri.parse(handle))
    }
}
