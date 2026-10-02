package com.lightlylabs.lightly.editor

import android.content.Context
import android.net.Uri
import com.lightlylabs.lightly.decode.ProxyDecoder
import com.lightlylabs.lightly.export.BitmapExportFrame
import com.lightlylabs.lightly.export.BitmapFrameJpegEncoder
import com.lightlylabs.lightly.export.ContentResolverGateway
import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.MediaStoreGateway
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.export.SaveCopyExporter
import com.lightlylabs.lightly.model.BasisRegistry
import com.lightlylabs.lightly.model.RegistryAutoLutResolver
import com.lightlylabs.lightly.render.lut.CpuLutPassRenderer
import kotlinx.coroutines.asCoroutineDispatcher
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
 * - **Looks:** [BundledLookBook]: provisional procedural placeholders in debug builds only, none in
 *   release builds, until the curated look-book (M3/M4).
 */
object AndroidEditorEnvironment {

    /** One thread owns rendering (it will own the EGL context once GL is wired). */
    private val renderDispatcher = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "lightly-render") }.asCoroutineDispatcher()

    fun create(context: Context, screenLongestPx: Int): EditorEnvironment {
        val resolver = context.applicationContext.contentResolver
        val decoder = ProxyDecoder()
        val gateway = UriStringGateway(ContentResolverGateway(resolver))
        return EditorEnvironment(
            photoLoader = ContentResolverPhotoLoader(resolver, decoder, screenLongestPx),
            photoAccess = ContentResolverPhotoAccessGrants(resolver),
            // DEFERRED: no production Auto model or inference engine is bundled; research (FiveK)
            // weights must never ship. Until one exists every photo opens with Auto off.
            autoDeveloper = AutoDeveloper { _, _ -> DevelopResult.NoModelInThisBuild },
            autoResolver = RegistryAutoLutResolver(BasisRegistry(installed = emptyList())),
            lookBook = BundledLookBook.create(),
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

    /** The editor keys assets by string; MediaStore by Uri. */
    private class UriStringGateway(private val delegate: ContentResolverGateway) : MediaStoreGateway<String> {
        override fun insertPending(spec: NewImageSpec): String? = delegate.insertPending(spec)?.toString()
        override fun openForWrite(handle: String): OutputStream = delegate.openForWrite(Uri.parse(handle))
        override fun publish(handle: String): Boolean = delegate.publish(Uri.parse(handle))
        override fun delete(handle: String) = delegate.delete(Uri.parse(handle))
    }
}
