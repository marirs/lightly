package com.lightlylabs.lightly.editor

import androidx.lifecycle.SavedStateHandle
import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.FullResolutionSource
import com.lightlylabs.lightly.export.JpegEncoder
import com.lightlylabs.lightly.export.MediaStoreGateway
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.export.Rgba8ExportFrame
import com.lightlylabs.lightly.export.SaveCopyExporter
import com.lightlylabs.lightly.model.BasisLuts
import com.lightlylabs.lightly.model.BasisRegistry
import com.lightlylabs.lightly.model.InstalledBasis
import com.lightlylabs.lightly.model.ModelKey
import com.lightlylabs.lightly.model.RegistryAutoLutResolver
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.CpuLutPassRenderer
import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.render.lut.LutPassPlan
import com.lightlylabs.lightly.render.lut.LutPassRenderer
import com.lightlylabs.lightly.session.AutoResult
import com.lightlylabs.lightly.session.EditSession
import com.lightlylabs.lightly.session.LookRef
import com.lightlylabs.lightly.session.SessionJson
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * The editor flow end to end on the JVM with fakes and virtual time: picker → decode → Auto →
 * stepped Looks → latest-wins preview (two-pass plan) → Compare / Undo / Reset → Save copy, plus
 * configuration change / process death (spec §2, §5).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EditorViewModelTest {

    private val assetId = "content://media/picker/0/42"
    private val source = SourceRef(assetId, SourceFingerprint("ab".repeat(32), 2_000_000, 80, 60), orientation = 1)
    private val analysis = image(64, 48, seed = 1)
    private val display = image(40, 30, seed = 2)
    private val fullResolution = image(80, 60, seed = 3)
    private val lookBook = PlaceholderLookBook.create()

    // Test basis for model version "test-1": injected, never bundled (the research basis must not ship).
    private val basis = BasisLuts(List(3) { index -> scaledIdentity(1f + 0.15f * index, -0.05f * index) })
    private val auto = AutoResult(AutoResult.MODEL_ID_IA3DLUT, "test-1", listOf(0.6f, 0.3f, 0.1f), guardrail = null, strength = 0.8f)
    private val expectedAutoLut = basis.fuse(floatArrayOf(0.6f, 0.3f, 0.1f))

    private class Fakes(var developResult: DevelopResult) {
        var loads = 0
        val developedWith = mutableListOf<Rgba8Image>()
        var previewRenders = 0
        val published = mutableListOf<String>()
        val written = mutableMapOf<String, ByteArrayOutputStream>()
    }

    private fun TestScope.environment(
        fakes: Fakes,
        withBasis: Boolean = true,
        photoLoader: PhotoLoader? = null,
        autoDeveloper: AutoDeveloper? = null,
    ): EditorEnvironment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val bytes = bytesOf(basis)
        val registry = BasisRegistry(
            if (withBasis) listOf(InstalledBasis(ModelKey("ia3dlut", "test-1"), BasisRegistry.sha256Hex(bytes)) { bytes }) else emptyList(),
        )
        val gateway = object : MediaStoreGateway<String> {
            override fun insertPending(spec: NewImageSpec) = "content://media/new/${fakes.written.size + 1}"
            override fun openForWrite(handle: String): OutputStream = ByteArrayOutputStream().also { fakes.written[handle] = it }
            override fun publish(handle: String) = fakes.published.add(handle)
            override fun delete(handle: String) { fakes.written.remove(handle) }
        }
        val countingPreview = object : LutPassRenderer {
            override fun render(source: Rgba8Image, plan: LutPassPlan): Rgba8Image {
                fakes.previewRenders++
                return CpuLutPassRenderer.render(source, plan)
            }
        }
        return EditorEnvironment(
            photoLoader = photoLoader ?: PhotoLoader { id ->
                fakes.loads++
                check(id == assetId)
                LoadedPhoto(source, analysis, display, FullResolutionSource { fullResolution })
            },
            autoDeveloper = autoDeveloper ?: AutoDeveloper { _, analysisImage -> fakes.developedWith += analysisImage; fakes.developResult },
            autoResolver = RegistryAutoLutResolver(registry),
            lookBook = lookBook,
            previewRenderer = countingPreview,
            renderDispatcher = dispatcher,
            exporter = ExportCoordinator(
                CpuLutPassRenderer,
                SaveCopyExporter(gateway, JpegEncoder<Rgba8ExportFrame> { frame, _, sink -> sink.write(frame.pixels) }),
                Rgba8ExportFrame.factory,
                dispatcher,
            ),
        )
    }

    private fun TestScope.viewModel(handle: SavedStateHandle, env: EditorEnvironment) =
        EditorViewModel(handle, env, CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)))

    private fun TestScope.readyViewModel(fakes: Fakes = Fakes(DevelopResult.Developed(auto)), handle: SavedStateHandle = SavedStateHandle(), withBasis: Boolean = true): EditorViewModel =
        viewModel(handle, environment(fakes, withBasis)).also {
            it.openPhoto(assetId)
            advanceUntilIdle()
        }

    private fun render(image: Rgba8Image, autoLut: Lut3D?, autoStrength: Float, look: LookRef?) =
        CpuLutPassRenderer.render(image, LutPassPlan.of(autoLut, autoStrength, look?.let { lookBook.find(it)!!.lut }, look?.strength ?: 0f)).pixels

    private fun EditorViewModel.previewPixels() = assertNotNull(uiState.value.preview).pixels

    // --- Pick → develop → preview ----------------------------------------------------------------

    @Test
    fun `picking a photo develops from the analysis decode and previews Auto on the display proxy`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val vm = readyViewModel(fakes)

        assertEquals(EditorPhase.Ready, vm.uiState.value.phase)
        assertSame(analysis, fakes.developedWith.single(), "the model input is the analysis decode, never the display proxy")
        assertEquals(AutoStatus.Applied("ia3dlut", "test-1"), vm.uiState.value.autoStatus)
        assertContentEquals(render(display, expectedAutoLut, 0.8f, null), vm.previewPixels())
    }

    @Test
    fun `without a matching basis Auto shows unavailable, previews the original, and Looks still apply`() = runTest {
        val vm = readyViewModel(withBasis = false)

        assertIs<AutoStatus.Unavailable>(vm.uiState.value.autoStatus)
        assertNull(vm.autoLutForRendering)
        assertContentEquals(display.pixels, vm.previewPixels())

        vm.selectCategory("Film")
        vm.onStopSettled(1)
        advanceUntilIdle()
        assertContentEquals(render(display, null, 0f, lookBook.stops("Film")[0].ref()), vm.previewPixels())
    }

    @Test
    fun `develop failure offers retry and use original`() = runTest {
        val fakes = Fakes(DevelopResult.Failed("no inference engine"))
        val vm = readyViewModel(fakes)
        assertEquals(EditorPhase.DevelopFailed("no inference engine"), vm.uiState.value.phase)

        vm.retryDevelop()
        advanceUntilIdle()
        assertEquals(2, fakes.developedWith.size, "retry runs the model once more, user-initiated")

        vm.useOriginal()
        advanceUntilIdle()
        assertEquals(EditorPhase.Ready, vm.uiState.value.phase)
        assertEquals(AutoStatus.UsingOriginal, vm.uiState.value.autoStatus)
        assertEquals(0f, vm.uiState.value.session!!.current.auto.strength)
        assertContentEquals(display.pixels, vm.previewPixels())
    }

    // --- Stepped slider and latest-wins ----------------------------------------------------------

    @Test
    fun `moving the stepped slider previews, settling commits once, and category alone is not a step`() = runTest {
        val vm = readyViewModel()
        val film = lookBook.stops("Film")
        vm.selectCategory("Film")

        vm.onStopChanged(1); vm.onStopChanged(2); vm.onStopChanged(3)
        assertEquals(1, vm.uiState.value.session!!.history.entries.size, "dragging commits nothing")
        assertEquals(film[2].ref(), vm.uiState.value.displayed!!.look)
        assertEquals(3, vm.stopIndex)

        vm.onStopSettled(2)
        advanceUntilIdle()
        assertEquals(2, vm.uiState.value.session!!.history.entries.size)
        assertEquals(film[1].ref(), vm.uiState.value.session!!.current.look)
        assertNull(vm.uiState.value.transientPreview)
        assertEquals(2, vm.stopIndex)

        vm.selectCategory("Warm")
        assertEquals(2, vm.uiState.value.session!!.history.entries.size, "changing category does not change the Look")
        assertEquals(0, vm.stopIndex, "the Film Look is not a Warm stop")
        assertContentEquals(render(display, expectedAutoLut, 0.8f, film[1].ref()), vm.previewPixels())
    }

    @Test
    fun `rapid slider changes render at most twice and the last state wins`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val vm = readyViewModel(fakes)
        vm.selectCategory("Film")
        val rendersBefore = fakes.previewRenders

        repeat(30) { step -> vm.onStopChanged(step % 4) }
        vm.onStopSettled(3)
        advanceUntilIdle()

        assertTrue(fakes.previewRenders - rendersBefore <= 2, "rendered ${fakes.previewRenders - rendersBefore} times for 31 requests")
        assertContentEquals(render(display, expectedAutoLut, 0.8f, lookBook.stops("Film")[2].ref()), vm.previewPixels())
    }

    @Test
    fun `strength previews while dragging and commits on release`() = runTest {
        val vm = readyViewModel()
        val warm = lookBook.stops("Warm")[0].ref()
        vm.commitLook(warm)
        vm.previewLookStrength(0.2f)
        advanceUntilIdle()
        assertContentEquals(render(display, expectedAutoLut, 0.8f, warm.copy(strength = 0.2f)), vm.previewPixels())
        assertEquals(1f, vm.uiState.value.session!!.current.look!!.strength)

        vm.commitLookStrength(0.2f)
        assertEquals(0.2f, vm.uiState.value.session!!.current.look!!.strength)
    }

    // --- Compare, Undo, Reset --------------------------------------------------------------------

    @Test
    fun `compare shows the original, and undo and reset update the preview`() = runTest {
        val vm = readyViewModel()
        val mono = lookBook.stops("Mono")[0].ref()
        vm.commitLook(mono)
        advanceUntilIdle()
        assertContentEquals(render(display, expectedAutoLut, 0.8f, mono), vm.previewPixels())

        vm.setCompare(true)
        advanceUntilIdle()
        assertContentEquals(display.pixels, vm.previewPixels(), "Compare is the Original, not Auto")
        vm.setCompare(false)

        vm.resetToAuto()
        advanceUntilIdle()
        assertContentEquals(render(display, expectedAutoLut, 0.8f, null), vm.previewPixels())

        vm.undo()
        advanceUntilIdle()
        assertContentEquals(render(display, expectedAutoLut, 0.8f, mono), vm.previewPixels())
    }

    // --- Save copy -------------------------------------------------------------------------------

    @Test
    fun `save copy exports the committed state once, never the transient preview`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val vm = readyViewModel(fakes)
        val committed = lookBook.stops("Warm")[1].ref()
        vm.commitLook(committed)
        vm.previewLook(lookBook.stops("Mono")[0].ref()) // finger still on the slider

        assertTrue(vm.saveCopy())
        assertFalse(vm.saveCopy(), "one export at a time")
        advanceUntilIdle()

        val saved = assertIs<SaveStatus.Saved>(vm.uiState.value.save)
        assertEquals(listOf(saved.newAssetId), fakes.published)
        assertContentEquals(render(fullResolution, expectedAutoLut, 0.8f, committed), fakes.written.getValue(saved.newAssetId).toByteArray())
    }

    // --- Configuration change / process death ----------------------------------------------------

    /** Copies only Bundle-compatible values, as Android does across process death. */
    private fun afterProcessDeath(handle: SavedStateHandle): SavedStateHandle {
        val values = handle.keys().associateWith { key -> handle.get<Any>(key) }
        assertTrue(values.values.all { it is String || it is Boolean }, "SavedStateHandle holds non-Bundle types: $values")
        return SavedStateHandle(values)
    }

    @Test
    fun `recreated ViewModel restores the session and reloads the photo without re-running the model`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val handle = SavedStateHandle()
        val film = lookBook.stops("Film")
        val original = readyViewModel(fakes, handle).apply {
            selectCategory("Film")
            onStopSettled(1)
            onStopSettled(3)
            undo()
            setCompare(true)
        }
        advanceUntilIdle()

        val restored = viewModel(afterProcessDeath(handle), environment(fakes))
        advanceUntilIdle()

        assertEquals(2, fakes.loads, "the proxy is decoded again")
        assertEquals(1, fakes.developedWith.size, "the saved AutoResult is reused; the model is not re-run")
        assertEquals(original.uiState.value.session, restored.uiState.value.session)
        assertEquals(film[0].ref(), restored.uiState.value.session!!.current.look)
        assertTrue(restored.uiState.value.session!!.canRedo)
        assertTrue(restored.uiState.value.compareOn)
        assertEquals("Film", restored.uiState.value.selectedCategory)
        assertEquals(EditorPhase.Ready, restored.uiState.value.phase)
        assertContentEquals(display.pixels, restored.previewPixels(), "compare state restored")

        restored.setCompare(false)
        restored.redo()
        advanceUntilIdle()
        assertEquals(film[2].ref(), restored.uiState.value.session!!.current.look)
        assertContentEquals(render(display, expectedAutoLut, 0.8f, film[2].ref()), restored.previewPixels())
    }

    @Test
    fun `transient preview is shown but neither committed nor persisted`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val handle = SavedStateHandle()
        val vm = readyViewModel(fakes, handle)
        val portra = lookBook.stops("Film")[0].ref()
        val mono = lookBook.stops("Mono")[0].ref()
        vm.commitLook(portra)
        vm.previewLook(mono)

        assertEquals(mono, vm.uiState.value.displayed?.look)
        assertEquals(portra, vm.uiState.value.session?.current?.look)

        val restored = viewModel(afterProcessDeath(handle), environment(fakes))
        advanceUntilIdle()
        assertNull(restored.uiState.value.transientPreview)
        assertEquals(portra, restored.uiState.value.displayed?.look)
    }

    @Test
    fun `restoring an edit from an unavailable model version turns Auto off with a notice`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val oldEdit = EditSession.start(source, auto.copy(modelVersion = "test-0")).selectLook(lookBook.stops("Mono")[0].ref())
        val handle = SavedStateHandle(
            mapOf(EditorViewModel.KEY_ASSET to assetId, EditorViewModel.KEY_SESSION to SessionJson.encodeToString(EditSession.serializer(), oldEdit)),
        )

        val vm = viewModel(handle, environment(fakes))
        advanceUntilIdle()

        val status = assertIs<AutoStatus.Unavailable>(vm.uiState.value.autoStatus)
        assertEquals("test-0", status.modelVersion)
        assertTrue(status.notice.isNotBlank())
        assertNull(vm.autoLutForRendering, "never the installed test-1 basis")
        assertEquals(oldEdit, vm.uiState.value.session, "the stored AutoResult is kept untouched")
        assertTrue(fakes.developedWith.isEmpty())
        assertContentEquals(render(display, null, 0f, lookBook.stops("Mono")[0].ref()), vm.previewPixels(), "Looks still work on the Original")
    }

    @Test
    fun `a Look missing from this build's look-book is reported and not rendered`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val edit = EditSession.start(source, auto).selectLook(LookRef("film.discontinued", 7, 1f))
        val handle = SavedStateHandle(
            mapOf(EditorViewModel.KEY_ASSET to assetId, EditorViewModel.KEY_SESSION to SessionJson.encodeToString(EditSession.serializer(), edit)),
        )

        val vm = viewModel(handle, environment(fakes))
        advanceUntilIdle()

        assertNotNull(vm.uiState.value.lookNotice)
        assertContentEquals(render(display, expectedAutoLut, 0.8f, null), vm.previewPixels())
    }

    @Test
    fun `an undecodable saved session develops the photo again instead of crashing`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val handle = SavedStateHandle(mapOf(EditorViewModel.KEY_ASSET to assetId, EditorViewModel.KEY_SESSION to "{\"schema\":99}"))

        val vm = viewModel(handle, environment(fakes))
        advanceUntilIdle()

        assertEquals(EditorPhase.Ready, vm.uiState.value.phase)
        assertEquals(1, fakes.developedWith.size)
    }

    @Test
    fun `an empty handle starts empty`() = runTest {
        val vm = viewModel(SavedStateHandle(), environment(Fakes(DevelopResult.Developed(auto))))
        advanceUntilIdle()
        assertEquals(EditorPhase.Empty, vm.uiState.value.phase)
        assertNull(vm.uiState.value.session)
    }

    // --- Stale work for a previous photo (Codex finding 1) ---------------------------------------
    //
    // Each case opens photo A, leaves one of A's async steps suspended in a developer/loader that
    // IGNORES cancellation, switches to photo B, waits until B is Ready, then lets A's step finish.
    // B's session, preview, saved state and phase must be exactly what they were before.

    private val assetB = "content://media/picker/0/43"
    private val sourceB = SourceRef(assetB, SourceFingerprint("cd".repeat(32), 1_000_000, 80, 60), orientation = 1)
    private val analysisB = image(64, 48, seed = 4)
    private val displayB = image(40, 30, seed = 5)
    private val autoA = auto.copy(weights = listOf(0.1f, 0.2f, 0.7f), strength = 1f)

    /**
     * A suspension that does not react to cancellation: [suspendCoroutine] is not cancellable, so the
     * caller keeps running after [release] even though its Job was cancelled. Models a third-party
     * model runtime (or blocking native call) that finishes its work regardless.
     */
    private class NonCooperativeGate<T> {
        private var continuation: Continuation<T>? = null
        val isWaiting: Boolean get() = continuation != null
        suspend fun await(): T = suspendCoroutine { continuation = it }
        fun release(value: T) = checkNotNull(continuation).also { continuation = null }.resume(value)
        fun fail(error: Throwable) = checkNotNull(continuation).also { continuation = null }.resumeWithException(error)
    }

    /** Everything the user can observe for the current photo, plus what survives process death. */
    private data class Observable(
        val phase: EditorPhase,
        val session: EditSession?,
        val autoStatus: AutoStatus,
        /** Content hash of the preview pixels, so a failure message stays readable. */
        val previewHash: Int?,
        val savedAsset: String?,
        val savedSession: String?,
    )

    private fun observe(vm: EditorViewModel, handle: SavedStateHandle) = Observable(
        phase = vm.uiState.value.phase,
        session = vm.uiState.value.session,
        autoStatus = vm.uiState.value.autoStatus,
        previewHash = vm.uiState.value.preview?.pixels?.contentHashCode(),
        savedAsset = handle[EditorViewModel.KEY_ASSET],
        savedSession = handle[EditorViewModel.KEY_SESSION],
    )

    /** Photo A loads through [loadA] (immediate by default); photo B always loads immediately. */
    private fun twoPhotoLoader(loadA: suspend () -> LoadedPhoto = { LoadedPhoto(source, analysis, display, FullResolutionSource { fullResolution }) }) =
        PhotoLoader { id ->
            when (id) {
                assetId -> loadA()
                assetB -> LoadedPhoto(sourceB, analysisB, displayB, FullResolutionSource { fullResolution })
                else -> error("unexpected asset $id")
            }
        }

    /** Photo A develops through [developA]; photo B always develops to [auto] immediately. */
    private fun twoPhotoDeveloper(developA: suspend () -> DevelopResult) = AutoDeveloper { fingerprint, _ ->
        if (fingerprint == source.fingerprint) developA() else DevelopResult.Developed(auto)
    }

    /** Opens B after A has started, and returns B's observable state once it is Ready. */
    private fun TestScope.switchToReadyPhotoB(vm: EditorViewModel, handle: SavedStateHandle): Observable {
        vm.openPhoto(assetB)
        advanceUntilIdle()
        val ready = observe(vm, handle)
        assertEquals(EditorPhase.Ready, ready.phase)
        assertEquals(sourceB, ready.session!!.current.source)
        assertEquals(assetB, ready.savedAsset)
        assertNotNull(ready.previewHash)
        return ready
    }

    @Test
    fun `a stale Auto success for the previous photo does not replace the current session`() = runTest {
        val handle = SavedStateHandle()
        val developA = NonCooperativeGate<DevelopResult>()
        val vm = viewModel(handle, environment(Fakes(DevelopResult.Developed(auto)), photoLoader = twoPhotoLoader(), autoDeveloper = twoPhotoDeveloper { developA.await() }))
        vm.openPhoto(assetId)
        advanceUntilIdle()
        assertEquals(EditorPhase.Developing, vm.uiState.value.phase)
        assertTrue(developA.isWaiting)

        val photoBReady = switchToReadyPhotoB(vm, handle)
        developA.release(DevelopResult.Developed(autoA))
        advanceUntilIdle()

        assertEquals(photoBReady, observe(vm, handle))
    }

    @Test
    fun `a stale Auto failure for the previous photo does not change the current phase`() = runTest {
        val handle = SavedStateHandle()
        val developA = NonCooperativeGate<DevelopResult>()
        val vm = viewModel(handle, environment(Fakes(DevelopResult.Developed(auto)), photoLoader = twoPhotoLoader(), autoDeveloper = twoPhotoDeveloper { developA.await() }))
        vm.openPhoto(assetId)
        advanceUntilIdle()

        val photoBReady = switchToReadyPhotoB(vm, handle)
        developA.release(DevelopResult.Failed("model crashed on A"))
        advanceUntilIdle()

        assertEquals(photoBReady, observe(vm, handle))
    }

    @Test
    fun `a stale load failure for the previous photo does not change the current phase`() = runTest {
        val handle = SavedStateHandle()
        val loadA = NonCooperativeGate<LoadedPhoto>()
        val vm = viewModel(handle, environment(Fakes(DevelopResult.Developed(auto)), photoLoader = twoPhotoLoader { loadA.await() }, autoDeveloper = twoPhotoDeveloper { DevelopResult.Developed(autoA) }))
        vm.openPhoto(assetId)
        advanceUntilIdle()
        assertEquals(EditorPhase.Loading, vm.uiState.value.phase)

        val photoBReady = switchToReadyPhotoB(vm, handle)
        loadA.fail(java.io.IOException("A was deleted"))
        advanceUntilIdle()

        assertEquals(photoBReady, observe(vm, handle))
    }

    @Test
    fun `a stale retry for the previous photo does not replace the current session`() = runTest {
        val handle = SavedStateHandle()
        val retryA = NonCooperativeGate<DevelopResult>()
        var developCallsForA = 0
        val developer = twoPhotoDeveloper {
            // The first run fails (DevelopFailed offers Retry); the retry hangs non-cooperatively.
            if (++developCallsForA == 1) DevelopResult.Failed("first run failed") else retryA.await()
        }
        val vm = viewModel(handle, environment(Fakes(DevelopResult.Developed(auto)), photoLoader = twoPhotoLoader(), autoDeveloper = developer))
        vm.openPhoto(assetId)
        advanceUntilIdle()
        assertIs<EditorPhase.DevelopFailed>(vm.uiState.value.phase)
        vm.retryDevelop()
        advanceUntilIdle()
        assertTrue(retryA.isWaiting)

        val photoBReady = switchToReadyPhotoB(vm, handle)
        retryA.release(DevelopResult.Developed(autoA))
        advanceUntilIdle()

        assertEquals(photoBReady, observe(vm, handle))
    }

    // --- fixtures --------------------------------------------------------------------------------

    private fun image(width: Int, height: Int, seed: Int) =
        Rgba8Image(width, height, ByteArray(width * height * 4).also { Random(seed).nextBytes(it) }.also { bytes ->
            for (i in 3 until bytes.size step 4) bytes[i] = 0xff.toByte()
        })

    private fun scaledIdentity(scale: Float, offset: Float): Lut3D {
        val identity = Lut3D.identity()
        return Lut3D(33, FloatArray(identity.rgba.size) { i -> if (i % 4 == 3) 1f else identity.rgba[i] * scale + offset })
    }

    private fun bytesOf(basis: BasisLuts): ByteArray {
        val buffer = ByteBuffer.allocate(basis.luts.size * Lut3D.floatCount(basis.dimension) * 4).order(ByteOrder.LITTLE_ENDIAN)
        basis.luts.forEach { lut -> lut.rgba.forEach(buffer::putFloat) }
        return buffer.array()
    }
}
