package com.lightlylabs.lightly.editor

import androidx.lifecycle.SavedStateHandle
import com.lightlylabs.lightly.develop.DevelopRenderer
import com.lightlylabs.lightly.editor.enhance.EnhanceEngine
import com.lightlylabs.lightly.editor.enhance.EnhanceOutput
import com.lightlylabs.lightly.editor.enhance.EnhanceResultStore
import com.lightlylabs.lightly.editor.enhance.Enhancer
import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.FullResolutionSource
import com.lightlylabs.lightly.export.JpegEncoder
import com.lightlylabs.lightly.export.MediaStoreGateway
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.export.Rgba8ExportFrame
import com.lightlylabs.lightly.export.SaveCopyExporter
import com.lightlylabs.lightly.render.image.Rgba8Image
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
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Edit › Enhance (owner-approved design 2026-11-18, `ed-enhance*`; rendering-v2 §7.6): one undo step holding a stored
 * result that replaces the source under every other edit; Cancel and failure leave the edit as it was; Save copy starts
 * from the full-size result. As iOS EnhanceSessionTests.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EnhanceViewModelTest {
    private val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private val worker = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private val exportThread = Executors.newSingleThreadExecutor().asCoroutineDispatcher()

    @AfterTest
    fun tearDown() {
        Dispatchers.resetMain()
        main.close(); worker.close(); exportThread.close()
    }

    private fun image(w: Int, h: Int) = Rgba8Image(w, h, ByteArray(w * h * 4) { i -> if (i % 4 == 3) -1 else ((i * 7) % 251).toByte() })

    /** The photo at twice its size, nearest neighbour. */
    private fun doubled(photo: Rgba8Image): Rgba8Image {
        val w = photo.width * 2; val h = photo.height * 2
        val out = ByteArray(w * h * 4)
        for (y in 0 until h) for (x in 0 until w) System.arraycopy(photo.pixels, ((y / 2) * photo.width + x / 2) * 4, out, (y * w + x) * 4, 4)
        return Rgba8Image(w, h, out)
    }

    private fun waitUntil(what: String, timeoutMillis: Long = 10_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (!condition()) {
            check(System.currentTimeMillis() < deadline) { "timed out waiting for $what" }
            Thread.sleep(10)
        }
    }

    private val runs = AtomicInteger(0)
    private val exportedSize = AtomicReference<Pair<Int, Int>?>(null)

    private fun editor(enhancer: Enhancer?): EditorViewModel {
        val gateway = object : MediaStoreGateway<String> {
            override fun insertPending(spec: NewImageSpec) = "content://new/1"
            override fun openForWrite(handle: String): OutputStream = ByteArrayOutputStream()
            override fun publish(handle: String) = true
            override fun delete(handle: String) = Unit
        }
        val env = EditorEnvironment(
            photoLoader = PhotoLoader { asset ->
                LoadedPhoto(SourceRef(asset, SourceFingerprint("ab".repeat(32), 1000, 96, 64), 1), image(24, 16), image(48, 32), FullResolutionSource { image(96, 64) })
            },
            photoAccess = object : PhotoAccessGrants {
                override fun retain(assetId: String) = true
                override fun release(assetId: String) = Unit
            },
            autoDeveloper = AutoDeveloper { _, _, _ -> DevelopResult.NoModelInThisBuild },
            personDetector = PendingPersonDetector,
            library = CompletableDeferred(BundledPack.library),
            previewRenderer = DevelopRenderer(),
            renderDispatcher = worker,
            prefetchDispatcher = worker,
            exporter = ExportCoordinator(SaveCopyExporter(gateway, JpegEncoder<Rgba8ExportFrame> { f, _, sink ->
                exportedSize.set(f.width to f.height); sink.write(f.pixels)
            }), Rgba8ExportFrame.factory, exportThread, maxTileEdge = 64),
            favourites = object : FavouritesStore {
                override val favourites: StateFlow<List<String>> = MutableStateFlow(emptyList())
                override fun update(change: (List<String>) -> List<String>) = Unit
            },
            debugBuild = true,
            enhancer = enhancer,
        )
        Dispatchers.setMain(main)
        val vm = EditorViewModel(SavedStateHandle(), env, CoroutineScope(SupervisorJob() + main))
        vm.openPhoto("content://photo/1")
        waitUntil("the editor to be ready") { vm.uiState.value.phase == EditorPhase.Ready }
        return vm
    }

    private val succeeding = Enhancer { photo, _, progress ->
        runs.incrementAndGet(); progress(0.5); progress(1.0); EnhanceOutput(doubled(photo), painting = false)
    }

    private fun EditorViewModel.enhanced() = uiState.value.session?.current?.tools?.edit?.enhance

    @Test
    fun `enhance is one undo step holding the stored result, and Reset undoes it`() {
        val vm = editor(succeeding)
        val before = vm.uiState.value.session!!.current.tools
        vm.enhancePhoto()
        waitUntil("the result") { vm.enhanced() != null }
        val enhance = vm.enhanced()!!
        assertEquals(192, enhance.result.width)
        assertEquals(128, enhance.result.height)
        assertEquals(EditorViewModel.ENHANCE_MODEL, enhance.result.model)
        assertFalse(enhance.painting)
        assertEquals(EnhanceOp.IDLE, vm.uiState.value.edit.enhanceOp)
        assertEquals("Enhanced", vm.uiState.value.toast)
        assertTrue(vm.canReset("edit", "enhance"))

        vm.undo()
        waitUntil("undo") { vm.enhanced() == null }
        vm.redo()
        waitUntil("redo") { vm.enhanced() != null }
        assertEquals(enhance, vm.enhanced(), "Redo brings the same result back, not a new run")
        assertEquals(1, runs.get())

        vm.resetEdits("edit", "enhance")
        waitUntil("reset") { vm.enhanced() == null }
        assertEquals(before, vm.uiState.value.session!!.current.tools, "Reset leaves every other edit as it was")
    }

    @Test
    fun `Save copy starts from the full-size result`() {
        val vm = editor(succeeding)
        vm.enhancePhoto()
        waitUntil("the result") { vm.enhanced() != null }
        vm.saveCopy()
        waitUntil("the copy to be saved") { vm.uiState.value.overlay == EditorOverlay.SAVED }
        assertEquals(192 to 128, exportedSize.get(), "the saved copy is twice the photo")
    }

    @Test
    fun `failure keeps the edit and Try again runs again`() {
        val failures = AtomicInteger(0)
        val vm = editor(Enhancer { _, _, _ -> failures.incrementAndGet(); throw EnhanceEngine.Failure.ModelFailed("test failure") })
        val before = vm.uiState.value.session!!.current
        vm.enhancePhoto()
        waitUntil("the failure") { vm.uiState.value.edit.enhanceOp == EnhanceOp.FAILED }
        assertEquals(before, vm.uiState.value.session!!.current, "Your other edits are kept")
        vm.enhancePhoto()   // Try again
        waitUntil("the second run") { failures.get() == 2 && vm.uiState.value.edit.enhanceOp == EnhanceOp.FAILED }
        vm.resetEdits("edit", "enhance")
        assertEquals(EnhanceOp.IDLE, vm.uiState.value.edit.enhanceOp, "Reset clears the failure notice")
    }

    @Test
    fun `Cancel changes nothing`() {
        val vm = editor(Enhancer { _, isCancelled, _ ->
            while (!isCancelled()) Thread.sleep(5)
            throw EnhanceEngine.Failure.Cancelled()
        })
        val before = vm.uiState.value.session!!.current
        vm.enhancePhoto()
        waitUntil("enhancing") { vm.uiState.value.edit.enhanceOp == EnhanceOp.ENHANCING }
        vm.cancelEnhance()
        assertEquals(EnhanceOp.IDLE, vm.uiState.value.edit.enhanceOp)
        assertEquals(EditorViewModel.OPERATION_CANCELLED, vm.uiState.value.toast)
        Thread.sleep(100)
        assertEquals(before, vm.uiState.value.session!!.current)
    }

    @Test
    fun `the Enhance tab shows only when the build carries the engine`() {
        assertFalse(EditSub.ENHANCE in editor(null).editTabs)
        assertEquals(EditSub.entries.toList(), editor(succeeding).editTabs)
    }

    @Test
    fun `stored results come back bit for bit and a corrupt one is refused`() {
        val directory = kotlin.io.path.createTempDirectory("enhance-results").toFile()
        try {
            val photo = doubled(image(30, 20))
            val digest = EnhanceResultStore(directory).put(photo)
            val restored = assertNotNull(EnhanceResultStore(directory)[digest], "read back by a new store (a restored session)")
            assertTrue(restored.pixels.contentEquals(photo.pixels))
            val file = directory.listFiles()!!.single()
            file.writeBytes(java.io.ByteArrayOutputStream().also { out ->
                java.util.zip.DeflaterOutputStream(out).use { d -> java.io.DataOutputStream(d).apply { writeInt(0x4C454E31); writeInt(60); writeInt(40); write(ByteArray(60 * 40 * 4)) } }
            }.toByteArray())
            assertNull(EnhanceResultStore(directory)[digest], "pixels that no longer match the digest")
        } finally { directory.deleteRecursively() }
    }
}
