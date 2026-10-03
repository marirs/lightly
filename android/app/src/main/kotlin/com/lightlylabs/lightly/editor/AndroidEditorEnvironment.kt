package com.lightlylabs.lightly.editor

import android.content.Context
import android.net.Uri
import android.util.Log
import com.lightlylabs.lightly.BuildConfig
import com.lightlylabs.lightly.decode.ProxyDecoder
import com.lightlylabs.lightly.develop.DevelopRenderer
import com.lightlylabs.lightly.export.BitmapExportFrame
import com.lightlylabs.lightly.export.BitmapFrameJpegEncoder
import com.lightlylabs.lightly.export.ContentResolverGateway
import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.ExportMetadataStep
import com.lightlylabs.lightly.export.MediaStoreGateway
import com.lightlylabs.lightly.export.MetadataPolicy
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.export.PlatformExifMetadata
import com.lightlylabs.lightly.export.SaveCopyExporter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.asCoroutineDispatcher
import java.io.File
import java.io.OutputStream
import java.util.concurrent.Executors

/**
 * Production wiring of [EditorEnvironment] for slice 2.
 *
 * Honest about what is missing:
 * - **Auto:** no shippable model (dependency D1): every photo opens with the approved
 *   "Automatic correction isn't available on this device. Presets still work." state.
 * - **Rendering:** the CPU [DevelopRenderer] (core-develop) on the display proxy and, tile by tile,
 *   on the full-resolution decode for Save copy. The GLES path (:core-render-gl) is not wired: it
 *   implements only LUT passes and has not been validated on a GPU (PENDING), while Develop also
 *   needs its spatial operators.
 * - **Portrait visibility:** the person detector is a pending dependency (D3) — see [PendingPersonDetector].
 */
object AndroidEditorEnvironment {
    private const val LOG_TAG = "LightlyDevelop"

    /** Preview renders run on one thread; their per-pixel work fans out on [workerPool]. */
    private val renderDispatcher = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "lightly-render") }.asCoroutineDispatcher()
    private val prefetchDispatcher = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "lightly-prefetch").apply { priority = Thread.MIN_PRIORITY } }.asCoroutineDispatcher()

    /** Threads for bakes and row-parallel rendering: at most 4, leaving the UI thread a core. */
    private val parallelism = Runtime.getRuntime().availableProcessors().coerceIn(1, 4)
    private val workerPool = Executors.newFixedThreadPool(parallelism) { runnable -> Thread(runnable, "lightly-develop-worker").apply { isDaemon = true } }

    /**
     * The display proxy's long edge: enough for every approved stage (the largest is a tablet's photo
     * area), small enough for the CPU spatial operators to finish a committed preview interactively.
     */
    const val PREVIEW_LONG_EDGE_PX = 1600

    /** Wall-clock milliseconds the bundled manifest took to parse and index (debug benchmark). */
    @Volatile var manifestParseMillis: Double = -1.0
        private set

    fun create(context: Context, screenLongestPx: Int, metadataPolicy: () -> MetadataPolicy, favourites: FavouritesStore): EditorEnvironment {
        val app = context.applicationContext
        val resolver = app.contentResolver
        val gateway = UriStringGateway(ContentResolverGateway(resolver))
        val library = CoroutineScope(SupervisorJob() + Dispatchers.IO).async {
            val manifest = app.assets.open(DevelopLibrary.ASSET_MANIFEST).use { it.readBytes().toString(Charsets.UTF_8) }
            val contract = app.assets.open(DevelopLibrary.ASSET_CONTRACT).use { it.readBytes().toString(Charsets.UTF_8) }
            DevelopLibrary.load(
                manifest, contract, workerPool, parallelism,
                parseMillis = { millis ->
                    manifestParseMillis = millis
                    Log.i(LOG_TAG, "manifest parse + index: ${"%.0f".format(millis)} ms")
                },
                onBake = { millis -> Log.i(LOG_TAG, "bake 33³: ${"%.1f".format(millis)} ms") },
            )
        }
        val exportTileEdge = 1024
        return EditorEnvironment(
            photoLoader = ContentResolverPhotoLoader(resolver, ProxyDecoder(), minOf(screenLongestPx, PREVIEW_LONG_EDGE_PX), allowFileUris = BuildConfig.DEBUG),
            photoAccess = ContentResolverPhotoAccessGrants(resolver),
            // DEFERRED(D1): no production Auto model or inference engine is bundled; research weights must never ship.
            autoDeveloper = AutoDeveloper { _, _ -> DevelopResult.NoModelInThisBuild },
            personDetector = PendingPersonDetector,
            library = library,
            previewRenderer = DevelopRenderer(workerPool, parallelism),
            renderDispatcher = renderDispatcher,
            prefetchDispatcher = prefetchDispatcher,
            exporter = ExportCoordinator(
                saver = SaveCopyExporter(gateway, BitmapFrameJpegEncoder(), metadataStep = metadataStep(app)),
                frameFactory = BitmapExportFrame.factory,
                renderDispatcher = renderDispatcher,
                maxTileEdge = exportTileEdge,
            ),
            favourites = favourites,
            debugBuild = BuildConfig.DEBUG,
            exportTileEdge = exportTileEdge,
            depthImageDecoder = { bytes -> if (com.lightlylabs.lightly.background.PngGrayDecoder.isPng(bytes)) com.lightlylabs.lightly.background.PngGrayDecoder.decode(bytes) else decodeJpegDepth(bytes) },
            exifOrientation = { bytes ->
                runCatching { android.media.ExifInterface(java.io.ByteArrayInputStream(bytes)).getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, 1) }.getOrDefault(1).coerceIn(1, 8)
            },
            bundledBackground = { id -> loadBundledBackground(app, id) },
            onPreviewRendered = { millis, globalOnly -> Log.i(LOG_TAG, "preview ${if (globalOnly) "drag" else "committed"}: ${"%.1f".format(millis)} ms") },
            newImageSpec = { _ -> NewImageSpec(displayName = "Lightly_${System.currentTimeMillis()}.jpg", metadataPolicy = metadataPolicy()) },
        )
    }

    /** An 8-bit JPEG depth image (Dynamic Depth allows JPEG items): the first channel in [0, 1]. */
    private fun decodeJpegDepth(bytes: ByteArray): com.lightlylabs.lightly.background.FloatPlane {
        val bitmap = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: throw IllegalArgumentException("depth image cannot be decoded")
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return com.lightlylabs.lightly.background.FloatPlane(bitmap.width, bitmap.height, FloatArray(pixels.size) { ((pixels[it] shr 16) and 0xff) / 255f })
    }

    /**
     * The approved bundled background photos (docs/ui/app/data.js `BACKGROUNDS`), packaged in DEBUG builds
     * only: their redistribution licence for release is unconfirmed (docs/v1/slice3-android.md › Blockers).
     */
    private fun loadBundledBackground(context: Context, id: String): com.lightlylabs.lightly.render.image.Rgba8Image? {
        val name = BackgroundOptions.IMAGES.firstOrNull { it.first == id }?.second ?: return null
        val bitmap = runCatching { context.assets.open("backgrounds/$name.jpg").use { android.graphics.BitmapFactory.decodeStream(it) } }.getOrNull() ?: return null
        val scale = minOf(1f, PREVIEW_LONG_EDGE_PX.toFloat() / maxOf(bitmap.width, bitmap.height))
        val scaled = if (scale < 1f) android.graphics.Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).toInt(), (bitmap.height * scale).toInt(), true) else bitmap
        val argb = scaled.copy(android.graphics.Bitmap.Config.ARGB_8888, false)
        val buffer = java.nio.ByteBuffer.allocate(argb.byteCount)
        argb.copyPixelsToBuffer(buffer)
        return com.lightlylabs.lightly.render.image.Rgba8Image(argb.width, argb.height, buffer.array())
    }

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

    /** The editor keys assets by string; MediaStore by Uri. */
    private class UriStringGateway(private val delegate: ContentResolverGateway) : MediaStoreGateway<String> {
        override fun insertPending(spec: NewImageSpec): String? = delegate.insertPending(spec)?.toString()
        override fun openForWrite(handle: String): OutputStream = delegate.openForWrite(Uri.parse(handle))
        override fun publish(handle: String): Boolean = delegate.publish(Uri.parse(handle))
        override fun delete(handle: String) = delegate.delete(Uri.parse(handle))
    }
}
