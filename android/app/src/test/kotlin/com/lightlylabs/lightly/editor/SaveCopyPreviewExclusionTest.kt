package com.lightlylabs.lightly.editor

import androidx.lifecycle.SavedStateHandle
import com.lightlylabs.lightly.develop.DevelopRenderer
import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.FullResolutionSource
import com.lightlylabs.lightly.export.JpegEncoder
import com.lightlylabs.lightly.export.MediaStoreGateway
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.export.Rgba8ExportFrame
import com.lightlylabs.lightly.export.SaveCopyExporter
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.BorderType
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Save copy never overlaps a preview render. A Background preview rendering during a 12 MP Save copy
 * ran the 192 MB heap out of memory (Refocus.fillMasked) on the Pixel 9 Pro emulator.
 *
 * The preview here is deliberately slow and IGNORES cancellation (a CPU-bound render does not check
 * for it), on its own real thread, as is the export. Before the fix the export started while the
 * preview was still running; now it may only begin preparing after the preview has exited.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SaveCopyPreviewExclusionTest {
    private val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private val previewThread = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private val exportThread = Executors.newSingleThreadExecutor().asCoroutineDispatcher()

    @AfterTest
    fun tearDown() {
        Dispatchers.resetMain()
        main.close(); previewThread.close(); exportThread.close()
    }

    private fun image(w: Int, h: Int) = Rgba8Image(w, h, ByteArray(w * h * 4) { i -> if (i % 4 == 3) -1 else ((i * 7) % 251).toByte() })

    private fun waitUntil(what: String, timeoutMillis: Long = 10_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (!condition()) {
            check(System.currentTimeMillis() < deadline) { "timed out waiting for $what" }
            Thread.sleep(10)
        }
    }

    @Test
    fun `export preparation waits until a slow, cancellation-ignoring preview has exited`() {
        val slowPreviews = AtomicBoolean(false)
        val previewStarted = CountDownLatch(1)
        val previewExitedAt = AtomicLong(0)
        val previewsAfterArming = AtomicLong(0)
        val exportBeganAt = AtomicLong(0)
        val exportBeganDuringPreview = AtomicBoolean(false)

        val gateway = object : MediaStoreGateway<String> {
            val files = mutableMapOf<String, ByteArrayOutputStream>()
            override fun insertPending(spec: NewImageSpec): String {
                if (exportBeganAt.compareAndSet(0, System.nanoTime())) {
                    exportBeganDuringPreview.set(previewStarted.count == 0L && previewExitedAt.get() == 0L)
                }
                return "content://new/${files.size + 1}"
            }
            override fun openForWrite(handle: String): OutputStream = ByteArrayOutputStream().also { files[handle] = it }
            override fun publish(handle: String) = true
            override fun delete(handle: String) { files.remove(handle) }
        }
        val env = EditorEnvironment(
            photoLoader = PhotoLoader { asset ->
                LoadedPhoto(SourceRef(asset, SourceFingerprint("ab".repeat(32), 1000, 48, 32), 1), image(24, 16), image(48, 32), FullResolutionSource { image(96, 64) })
            },
            photoAccess = object : PhotoAccessGrants {
                override fun retain(assetId: String) = true
                override fun release(assetId: String) = Unit
            },
            autoDeveloper = AutoDeveloper { _, _ -> DevelopResult.NoModelInThisBuild },
            personDetector = PendingPersonDetector,
            library = CompletableDeferred(BundledPack.library),
            previewRenderer = DevelopRenderer(),
            renderDispatcher = previewThread,
            prefetchDispatcher = previewThread,
            exporter = ExportCoordinator(SaveCopyExporter(gateway, JpegEncoder<Rgba8ExportFrame> { f, _, sink -> sink.write(f.pixels) }), Rgba8ExportFrame.factory, exportThread, maxTileEdge = 32),
            favourites = object : FavouritesStore {
                override val favourites: StateFlow<List<String>> = MutableStateFlow(emptyList())
                override fun update(change: (List<String>) -> List<String>) = Unit
            },
            debugBuild = true,
            beforePreviewRender = {
                if (slowPreviews.get()) {
                    previewsAfterArming.incrementAndGet()
                    previewStarted.countDown()
                    // Busy, and deaf to cancellation, like a CPU-bound Background render.
                    val until = System.nanoTime() + 600_000_000L
                    while (System.nanoTime() < until) { /* spin */ }
                    previewExitedAt.compareAndSet(0, System.nanoTime())
                }
            },
        )
        Dispatchers.setMain(main)
        val vm = EditorViewModel(SavedStateHandle(), env, CoroutineScope(SupervisorJob() + main))
        vm.openPhoto("content://photo/1")
        waitUntil("the editor to be ready") { vm.uiState.value.phase == EditorPhase.Ready }

        slowPreviews.set(true)
        vm.chooseBorder(BorderType.SOLID) // an edit, so a preview starts
        assertTrue(previewStarted.await(5, TimeUnit.SECONDS), "the slow preview never started")
        vm.saveCopy() // while that preview is still running

        waitUntil("the copy to be saved") { vm.uiState.value.overlay == EditorOverlay.SAVED }
        assertTrue(!exportBeganDuringPreview.get(), "the export began while the preview was still running")
        assertTrue(previewExitedAt.get() > 0, "the preview never exited")
        assertTrue(exportBeganAt.get() > previewExitedAt.get(), "the export began before the preview exited")

        // After the save only the latest valid preview resumes: exactly one more render, not a backlog.
        slowPreviews.set(false)
        waitUntil("the held preview to render") { vm.uiState.value.preview != null }
        assertEquals(1, vm.exportPreparationsStarted)
    }
}
