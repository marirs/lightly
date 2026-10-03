package com.lightlylabs.lightly.editor

import android.content.Context
import android.content.res.AssetManager
import android.net.Uri
import android.util.Log
import com.lightlylabs.lightly.decode.ProxyDecoder
import com.lightlylabs.lightly.export.BitmapExportFrame
import com.lightlylabs.lightly.export.BitmapFrameJpegEncoder
import com.lightlylabs.lightly.export.ContentResolverGateway
import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.ExportMetadataStep
import com.lightlylabs.lightly.export.MetadataPolicy
import com.lightlylabs.lightly.export.PlatformExifMetadata
import com.lightlylabs.lightly.export.MediaStoreGateway
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.export.SaveCopyExporter
import com.lightlylabs.lightly.model.BasisRegistry
import com.lightlylabs.lightly.model.RegistryAutoLutResolver
import com.lightlylabs.lightly.render.lut.CpuLutPassRenderer
import kotlinx.coroutines.asCoroutineDispatcher
import java.io.File
import java.io.FileNotFoundException
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
 * - **Looks:** the Look pack bundled under `assets/lookpack/` (see app/build.gradle.kts), loaded by
 *   [LookPackLoader]. Its LUTs are unvalidated approximations of the curated presets and omit
 *   spatial operators by design; the editor says so. A build made without the pack has no Looks.
 */
object AndroidEditorEnvironment {

    /** One thread owns rendering (it will own the EGL context once GL is wired). */
    private val renderDispatcher = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "lightly-render") }.asCoroutineDispatcher()

    /**
     * @param metadataPolicy read when Save copy is tapped (Preferences › Keep photo metadata /
     *   Include location), so the policy in force at the tap is the one the saved file follows.
     */
    fun create(context: Context, screenLongestPx: Int, metadataPolicy: () -> MetadataPolicy): EditorEnvironment {
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
            lookBook = loadBundledLookPack(context.applicationContext.assets),
            previewRenderer = CpuLutPassRenderer,
            renderDispatcher = renderDispatcher,
            exporter = ExportCoordinator(
                renderer = CpuLutPassRenderer,
                saver = SaveCopyExporter(gateway, BitmapFrameJpegEncoder(), metadataStep = metadataStep(context.applicationContext)),
                frameFactory = BitmapExportFrame.factory,
                renderDispatcher = renderDispatcher,
            ),
            newImageSpec = { _ -> NewImageSpec(displayName = "Lightly_${System.currentTimeMillis()}.jpg", metadataPolicy = metadataPolicy()) },
        )
    }

    /**
     * Loads the whole pack eagerly (18 LUTs, about 10 MB of floats, sha256-checked) when the editor
     * environment is first created. DEFERRED (M3): load off the main thread and decode LUTs lazily.
     */
    private fun loadBundledLookPack(assets: AssetManager): LookBook {
        val book = LookPackLoader.load(AssetLookPackSource(assets))
        book.unavailableReason?.let { Log.w(LOG_TAG, "Look pack unavailable: $it") }
        book.problems.forEach { Log.w(LOG_TAG, "Look pack: $it") }
        return book
    }

    private const val LOG_TAG = "LightlyLooks"

    /** EXIF copy for Save copy; the editor keys photos by URI string, the platform reader by Uri. */
    private fun metadataStep(context: Context): ExportMetadataStep<String> {
        val uriReader = PlatformExifMetadata.contentResolverReader(context.contentResolver)
        val scratch = File(context.cacheDir, "export-scratch").apply { mkdirs() }
        return ExportMetadataStep(
            reader = { source, tags -> uriReader.read(Uri.parse(source), tags) },
            writer = PlatformExifMetadata.writer,
            scratchDirectory = scratch,
        )
    }

    /** Pack files live under `assets/lookpack/`, put there by the app's Gradle build. */
    private class AssetLookPackSource(private val assets: AssetManager) : LookPackSource {
        override fun read(relativePath: String): ByteArray? = try {
            assets.open("$ASSET_ROOT/$relativePath").use { it.readBytes() }
        } catch (missing: FileNotFoundException) {
            null
        }
    }

    private const val ASSET_ROOT = "lookpack"

    /** The editor keys assets by string; MediaStore by Uri. */
    private class UriStringGateway(private val delegate: ContentResolverGateway) : MediaStoreGateway<String> {
        override fun insertPending(spec: NewImageSpec): String? = delegate.insertPending(spec)?.toString()
        override fun openForWrite(handle: String): OutputStream = delegate.openForWrite(Uri.parse(handle))
        override fun publish(handle: String): Boolean = delegate.publish(Uri.parse(handle))
        override fun delete(handle: String) = delegate.delete(Uri.parse(handle))
    }
}
