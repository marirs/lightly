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
import com.lightlylabs.lightly.session.SavedEdits
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
    private val lookBook = FixtureLookPack.standardBook()

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
        val grants = RecordingGrants()
    }

    /** Records grant calls in order; [persistable] = false models a non-persistable picker URI. */
    private class RecordingGrants(var persistable: Boolean = true) : PhotoAccessGrants {
        val events = mutableListOf<String>()
        override fun retain(assetId: String): Boolean { events += "retain $assetId"; return persistable }
        override fun release(assetId: String) { events += "release $assetId" }
    }

    private fun TestScope.environment(
        fakes: Fakes,
        withBasis: Boolean = true,
        photoLoader: PhotoLoader? = null,
        autoDeveloper: AutoDeveloper? = null,
        lookBook: LookBook = this@EditorViewModelTest.lookBook,
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
            photoAccess = fakes.grants,
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

    private fun render(image: Rgba8Image, autoLut: Lut3D?, autoStrength: Float, look: LookRef?, book: LookBook = lookBook) =
        CpuLutPassRenderer.render(image, LutPassPlan.of(autoLut, autoStrength, look?.let { book.find(it)!!.lut }, look?.strength ?: 0f)).pixels

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

        vm.selectCategory("cat-film")
        vm.onStopSettled(1)
        advanceUntilIdle()
        assertContentEquals(render(display, null, 0f, lookBook.stops("cat-film")[0].ref()), vm.previewPixels())
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

    @Test
    fun `a build without an Auto model goes straight to editing with Auto unavailable, not a failure`() = runTest {
        // Retry can never succeed when the build has no model, so offering it would be a dead end.
        val fakes = Fakes(DevelopResult.NoModelInThisBuild)
        val vm = readyViewModel(fakes)
        assertEquals(EditorPhase.Ready, vm.uiState.value.phase)
        assertEquals(AutoStatus.NoModelInThisBuild, vm.uiState.value.autoStatus)
        assertEquals(0f, vm.uiState.value.session!!.current.auto.strength)
        assertNull(vm.autoLutForRendering)
        assertContentEquals(display.pixels, vm.previewPixels())

        vm.retryDevelop()
        advanceUntilIdle()
        assertEquals(1, fakes.developedWith.size, "nothing to retry: the model was asked once")

        vm.selectCategory("cat-film")
        vm.onStopSettled(1)
        advanceUntilIdle()
        assertContentEquals(render(display, null, 0f, lookBook.stops("cat-film")[0].ref()), vm.previewPixels())
    }

    @Test
    fun `a restored no-model session keeps reporting Auto unavailable without re-running the model`() = runTest {
        val handle = SavedStateHandle()
        val first = readyViewModel(Fakes(DevelopResult.NoModelInThisBuild), handle)
        first.selectCategory("cat-film")
        first.onStopSettled(1)
        advanceUntilIdle()

        val fakes = Fakes(DevelopResult.NoModelInThisBuild)
        val restored = viewModel(handle, environment(fakes))
        advanceUntilIdle()
        assertEquals(EditorPhase.Ready, restored.uiState.value.phase)
        assertEquals(AutoStatus.NoModelInThisBuild, restored.uiState.value.autoStatus)
        assertEquals(lookBook.stops("cat-film")[0].ref(), restored.uiState.value.session!!.current.look)
        assertEquals(0, fakes.developedWith.size)
    }

    // --- Stepped slider and latest-wins ----------------------------------------------------------

    @Test
    fun `moving the stepped slider previews, settling commits once, and category alone is not a step`() = runTest {
        val vm = readyViewModel()
        val film = lookBook.stops("cat-film")
        vm.selectCategory("cat-film")

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

        vm.selectCategory("cat-warm")
        assertEquals(2, vm.uiState.value.session!!.history.entries.size, "changing category does not change the Look")
        assertEquals(0, vm.stopIndex, "the Film Look is not a Warm stop")
        assertContentEquals(render(display, expectedAutoLut, 0.8f, film[1].ref()), vm.previewPixels())
    }

    @Test
    fun `rapid slider changes render at most twice and the last state wins`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val vm = readyViewModel(fakes)
        vm.selectCategory("cat-film")
        val rendersBefore = fakes.previewRenders

        repeat(30) { step -> vm.onStopChanged(step % 4) }
        vm.onStopSettled(3)
        advanceUntilIdle()

        assertTrue(fakes.previewRenders - rendersBefore <= 2, "rendered ${fakes.previewRenders - rendersBefore} times for 31 requests")
        assertContentEquals(render(display, expectedAutoLut, 0.8f, lookBook.stops("cat-film")[2].ref()), vm.previewPixels())
    }

    @Test
    fun `strength previews while dragging and commits on release`() = runTest {
        val vm = readyViewModel()
        val warm = lookBook.stops("cat-warm")[0].ref()
        vm.commitLook(warm)
        vm.previewLookStrength(0.2f)
        advanceUntilIdle()
        assertContentEquals(render(display, expectedAutoLut, 0.8f, warm.copy(strength = 0.2f)), vm.previewPixels())
        assertEquals(1f, vm.uiState.value.session!!.current.look!!.strength)

        vm.commitLookStrength(0.2f)
        assertEquals(0.2f, vm.uiState.value.session!!.current.look!!.strength)
    }

    // --- Agreed Strength rule (both platforms) ---------------------------------------------------

    @Test
    fun `review repro - preset A at 40 percent, preview B, settle back on A keeps 40 percent and adds no step`() = runTest {
        val vm = readyViewModel()
        val film = lookBook.stops("cat-film")
        vm.selectCategory("cat-film")
        vm.onStopSettled(1)
        vm.commitLookStrength(0.4f)
        advanceUntilIdle()
        val before = vm.uiState.value.session!!

        vm.onStopChanged(2)
        assertEquals(film[1].ref(1f), vm.uiState.value.displayed!!.look, "previewing a different preset shows it at 100%")
        vm.onStopChanged(1)
        assertEquals(film[0].ref(0.4f), vm.uiState.value.displayed!!.look, "dragging back over the committed stop previews it as committed")
        vm.onStopSettled(1)
        advanceUntilIdle()

        assertEquals(film[0].ref(0.4f), vm.uiState.value.session!!.current.look, "Strength unchanged")
        assertEquals(before, vm.uiState.value.session, "history unchanged: same entries, same cursor, same revision")
        assertNull(vm.uiState.value.transientPreview, "only the transient preview ends")
        assertContentEquals(render(display, expectedAutoLut, 0.8f, film[0].ref(0.4f)), vm.previewPixels())
    }

    @Test
    fun `tapping the committed stop again is a no-op that keeps redo`() = runTest {
        val vm = readyViewModel()
        val film = lookBook.stops("cat-film")
        vm.selectCategory("cat-film")
        vm.onStopSettled(1)
        vm.commitLookStrength(0.4f)
        vm.commitLookStrength(0.7f)
        vm.undo()
        val before = vm.uiState.value.session!!
        assertTrue(before.canRedo)

        vm.onStopSettled(1)

        assertEquals(before, vm.uiState.value.session, "a no-op does not clear redo")
        assertEquals(film[0].ref(0.4f), vm.uiState.value.session!!.current.look)
    }

    @Test
    fun `committing a different preset applies it at 100 percent as one undo step, and undo restores the old strength`() = runTest {
        val vm = readyViewModel()
        val film = lookBook.stops("cat-film")
        vm.selectCategory("cat-film")
        vm.onStopSettled(1)
        vm.commitLookStrength(0.4f)
        val entriesBefore = vm.uiState.value.session!!.history.entries.size

        vm.onStopChanged(2)
        vm.onStopChanged(3)
        vm.onStopSettled(3)
        assertEquals(film[2].ref(1f), vm.uiState.value.session!!.current.look, "the designed look, not the carried 40%")
        assertEquals(entriesBefore + 1, vm.uiState.value.session!!.history.entries.size, "one step for the drag")

        vm.undo()
        assertEquals(film[0].ref(0.4f), vm.uiState.value.session!!.current.look, "undo restores Strength exactly as committed")
        vm.redo()
        assertEquals(film[2].ref(1f), vm.uiState.value.session!!.current.look)
    }

    @Test
    fun `a preset from another category also starts at 100 percent`() = runTest {
        val vm = readyViewModel()
        vm.selectCategory("cat-film")
        vm.onStopSettled(1)
        vm.commitLookStrength(0.25f)
        vm.selectCategory("cat-warm")
        vm.onStopSettled(1)
        assertEquals(lookBook.stops("cat-warm")[0].ref(1f), vm.uiState.value.session!!.current.look)
    }

    @Test
    fun `reset is one undoable step and undo brings back the committed strength`() = runTest {
        val vm = readyViewModel()
        val film = lookBook.stops("cat-film")
        vm.selectCategory("cat-film")
        vm.onStopSettled(2)
        vm.commitLookStrength(0.4f)
        val entriesBefore = vm.uiState.value.session!!.history.entries.size

        vm.resetToAuto()
        assertNull(vm.uiState.value.session!!.current.look)
        assertEquals(entriesBefore + 1, vm.uiState.value.session!!.history.entries.size)

        vm.undo()
        assertEquals(film[1].ref(0.4f), vm.uiState.value.session!!.current.look)
    }

    @Test
    fun `strength previews do not commit, only the release does`() = runTest {
        val vm = readyViewModel()
        vm.selectCategory("cat-film")
        vm.onStopSettled(1)
        val entries = vm.uiState.value.session!!.history.entries.size
        repeat(10) { vm.previewLookStrength(it / 10f) }
        assertEquals(entries, vm.uiState.value.session!!.history.entries.size)
        vm.commitLookStrength(0.9f)
        assertEquals(entries + 1, vm.uiState.value.session!!.history.entries.size)
    }

    @Test
    fun `settling on the stop of a changed Look applies the pack's current version at 100 percent`() = runTest {
        // The committed Look is an older version of this stop's preset: it is not the stop that is
        // committed (the photo renders without it and the slider shows stop 0), so picking the stop
        // is an explicit choice of the current preset, not a no-op.
        val current = lookBook.stops("cat-warm")[1]
        val older = current.ref(0.6f).copy(lookVersion = "000000000000")
        val vm = viewModel(handleWith(EditSession.start(source, auto).selectLook(older)), environment(Fakes(DevelopResult.Developed(auto))))
        advanceUntilIdle()
        vm.selectCategory("cat-warm")

        vm.onStopSettled(2)

        assertEquals(current.ref(1f), vm.uiState.value.session!!.current.look)
        assertNull(vm.uiState.value.lookIssue)
    }

    @Test
    fun `a saved category that no longer exists falls back to the first category`() = runTest {
        val vm = viewModel(SavedStateHandle(mapOf(EditorViewModel.KEY_CATEGORY to "Removed")), environment(Fakes(DevelopResult.Developed(auto))))
        assertEquals(lookBook.categories.first().id, vm.uiState.value.selectedCategory)
    }

    // --- Categories and stops come from the Look pack --------------------------------------------

    private val alphaBetaPack = listOf(
        FixtureLookPack.Category("c-beta", "Beta", listOf(FixtureLookPack.Stop("z-1", "Zeta Tone (11)", 1), FixtureLookPack.Stop("a-2", "Alpha (3)", 2))),
        FixtureLookPack.Category("c-alpha", "Alpha", listOf(FixtureLookPack.Stop("m-3", "Mid", 3))),
    )

    @Test
    fun `categories, their order and stop names are the pack's, and the first category is the default`() = runTest {
        val vm = viewModel(SavedStateHandle(), environment(Fakes(DevelopResult.Developed(auto)), lookBook = FixtureLookPack.book(alphaBetaPack)))

        assertEquals(listOf("Beta", "Alpha"), vm.categories.map { it.label })
        assertEquals("c-beta", vm.uiState.value.selectedCategory)
        assertEquals(listOf("Zeta Tone (11)", "Alpha (3)"), vm.stopNames("c-beta"))
        assertEquals(listOf("Mid"), vm.stopNames("c-alpha"))
    }

    // Stop 0 promises what the photo shows: "Auto" only while an Auto correction is applied.

    @Test
    fun `stop 0 reads Auto while an Auto correction is applied`() = runTest {
        val vm = readyViewModel()
        assertEquals(listOf("Auto", "Earthy Wedding Tone (6)", "Nordic Tone (10)"), vm.sliderStopNames("cat-warm"))
    }

    @Test
    fun `stop 0 reads Original when the build has no Auto model`() = runTest {
        val vm = readyViewModel(Fakes(DevelopResult.NoModelInThisBuild))
        assertEquals(listOf("Original", "Earthy Wedding Tone (6)", "Nordic Tone (10)"), vm.sliderStopNames("cat-warm"))
    }

    @Test
    fun `stop 0 reads Original after Use original`() = runTest {
        val vm = readyViewModel(Fakes(DevelopResult.Failed("no inference engine")))
        vm.useOriginal()
        advanceUntilIdle()
        assertEquals("Original", vm.baseStopName)
    }

    @Test
    fun `stop 0 reads Original when the edit's Auto model is unavailable`() = runTest {
        val vm = readyViewModel(withBasis = false)
        assertIs<AutoStatus.Unavailable>(vm.uiState.value.autoStatus)
        assertEquals("Original", vm.baseStopName)
    }

    @Test
    fun `stop 0 reads Original when Auto strength is zero`() = runTest {
        val vm = readyViewModel(Fakes(DevelopResult.Developed(auto.copy(strength = 0f))))
        assertIs<AutoStatus.Applied>(vm.uiState.value.autoStatus)
        assertEquals("Original", vm.baseStopName)
    }

    @Test
    fun `stop 0 reads Original before any photo is developed`() = runTest {
        val vm = viewModel(SavedStateHandle(), environment(Fakes(DevelopResult.Developed(auto))))
        assertEquals("Original", vm.baseStopName)
    }

    @Test
    fun `an unknown category is ignored rather than selected`() = runTest {
        val vm = readyViewModel()
        vm.selectCategory("Natural")
        assertEquals("cat-film", vm.uiState.value.selectedCategory)
    }

    @Test
    fun `approximate Looks are labelled, validated Lightroom renders are not`() = runTest {
        val approximate = viewModel(SavedStateHandle(), environment(Fakes(DevelopResult.Developed(auto))))
        assertEquals(LookBook.APPROXIMATE_NOTICE, approximate.lookApproximationNotice)

        val validatedOnly = FixtureLookPack.book(listOf(FixtureLookPack.Category("c", "C", listOf(FixtureLookPack.validatedStop("v-1", "Checked", 1)))))
        val validated = viewModel(SavedStateHandle(), environment(Fakes(DevelopResult.Developed(auto)), lookBook = validatedOnly))
        assertNull(validated.lookApproximationNotice)
    }

    @Test
    fun `a build without a Look pack edits with Auto only`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val vm = viewModel(SavedStateHandle(), environment(fakes, lookBook = LookBook.unavailable(LookPackLoader.NO_PACK_REASON)))
        vm.openPhoto(assetId)
        advanceUntilIdle()

        assertEquals(EditorPhase.Ready, vm.uiState.value.phase)
        assertTrue(vm.categories.isEmpty())
        assertNull(vm.uiState.value.selectedCategory)
        assertNull(vm.lookApproximationNotice)
        assertEquals(0, vm.stopIndex)
        assertContentEquals(render(display, expectedAutoLut, 0.8f, null), vm.previewPixels())
    }

    @Test
    fun `a saved edit survives a pack that relabels, reorders and regroups its categories`() = runTest {
        val before = listOf(
            FixtureLookPack.Category("cat-warm", "Warm", listOf(FixtureLookPack.Stop("earthy-1", "Earthy", 1), FixtureLookPack.Stop("nordic-2", "Nordic", 2))),
            FixtureLookPack.Category("cat-film", "Film", listOf(FixtureLookPack.Stop("rainy-3", "Rainy", 3))),
        )
        // Same presets (same IDs and LUTs): categories renamed and swapped, Nordic moved to another
        // category and to the front, Warm's id gone.
        val after = listOf(
            FixtureLookPack.Category("cat-film", "Cinema", listOf(FixtureLookPack.Stop("nordic-2", "Nordic", 2), FixtureLookPack.Stop("rainy-3", "Rainy", 3))),
            FixtureLookPack.Category("cat-earth", "Earth", listOf(FixtureLookPack.Stop("earthy-1", "Earthy", 1))),
        )
        val fakes = Fakes(DevelopResult.Developed(auto))
        val handle = SavedStateHandle()
        val first = viewModel(handle, environment(fakes, lookBook = FixtureLookPack.book(before)))
        first.openPhoto(assetId)
        advanceUntilIdle()
        first.selectCategory("cat-warm")
        first.onStopSettled(2)
        first.commitLookStrength(0.6f)
        advanceUntilIdle()
        val savedLook = assertNotNull(first.uiState.value.session!!.current.look)

        val afterBook = FixtureLookPack.book(after)
        val restored = viewModel(afterProcessDeath(handle), environment(fakes, lookBook = afterBook))
        advanceUntilIdle()

        assertEquals(savedLook, restored.uiState.value.session!!.current.look, "the edit names the preset, not its category or stop")
        assertNull(restored.uiState.value.lookIssue)
        assertEquals("cat-film", restored.uiState.value.selectedCategory, "the saved category 'cat-warm' is gone: first category")
        assertEquals(1, restored.stopIndex, "Nordic is now stop 1 of the first category")
        assertContentEquals(render(display, expectedAutoLut, 0.8f, savedLook, afterBook), restored.previewPixels())
    }

    // --- Compare, Undo, Reset --------------------------------------------------------------------

    @Test
    fun `compare shows the original, and undo and reset update the preview`() = runTest {
        val vm = readyViewModel()
        val mono = lookBook.stops("cat-mono")[0].ref()
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

    @Test
    fun `holding the photo shows the original and releasing returns to the Compare toggle's state`() = runTest {
        val vm = readyViewModel()
        val mono = lookBook.stops("cat-mono")[0].ref()
        vm.commitLook(mono)
        advanceUntilIdle()
        val edited = render(display, expectedAutoLut, 0.8f, mono)

        vm.holdCompare(true)
        advanceUntilIdle()
        assertTrue(vm.uiState.value.showsOriginal)
        assertContentEquals(display.pixels, vm.previewPixels())
        vm.holdCompare(false)
        advanceUntilIdle()
        assertFalse(vm.uiState.value.showsOriginal)
        assertContentEquals(edited, vm.previewPixels())

        vm.setCompare(true)
        vm.holdCompare(true)
        vm.holdCompare(false)
        advanceUntilIdle()
        assertTrue(vm.uiState.value.compareOn, "releasing a hold does not switch the toggle off")
        assertTrue(vm.uiState.value.showsOriginal)
        assertContentEquals(display.pixels, vm.previewPixels())
    }

    @Test
    fun `a held compare is not persisted, the toggle is`() = runTest {
        val handle = SavedStateHandle()
        val vm = readyViewModel(handle = handle)
        vm.holdCompare(true)
        assertEquals(false, handle.get<Boolean>(EditorViewModel.KEY_COMPARE) ?: false, "a finger on the photo is transient")
        vm.holdCompare(false)
        vm.setCompare(true)
        assertEquals(true, handle.get<Boolean>(EditorViewModel.KEY_COMPARE))
    }

    @Test
    fun `the selected stop reads its name and its position among all stops`() = runTest {
        val vm = readyViewModel()
        vm.selectCategory("cat-warm")
        assertEquals("Auto · 1 of 3", vm.stopCaption("cat-warm"))

        vm.onStopSettled(2)
        assertEquals("Nordic Tone (10) · 3 of 3", vm.stopCaption("cat-warm"))

        vm.onStopChanged(1) // finger still down: the caption follows what the photo shows
        assertEquals("Earthy Wedding Tone (6) · 2 of 3", vm.stopCaption("cat-warm"))
    }

    @Test
    fun `reset is one undoable step and redo applies it again`() = runTest {
        val vm = readyViewModel()
        val warm = lookBook.stops("cat-warm")[0].ref()
        vm.commitLook(warm)
        vm.resetToAuto()
        assertNull(vm.uiState.value.session!!.current.look)
        assertEquals(3, vm.uiState.value.session!!.history.entries.size)

        vm.undo()
        assertEquals(warm, vm.uiState.value.session!!.current.look)
        vm.redo()
        assertNull(vm.uiState.value.session!!.current.look)
        assertFalse(vm.canReset, "nothing left to reset")
    }

    // --- Save copy -------------------------------------------------------------------------------

    @Test
    fun `save copy exports the committed state once, never the transient preview`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val vm = readyViewModel(fakes)
        val committed = lookBook.stops("cat-warm")[1].ref()
        vm.commitLook(committed)
        vm.previewLook(lookBook.stops("cat-mono")[0].ref()) // finger still on the slider

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
        val film = lookBook.stops("cat-film")
        val original = readyViewModel(fakes, handle).apply {
            selectCategory("cat-film")
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
        assertEquals("cat-film", restored.uiState.value.selectedCategory)
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
        val portra = lookBook.stops("cat-film")[0].ref()
        val mono = lookBook.stops("cat-mono")[0].ref()
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
        val oldEdit = EditSession.start(source, auto.copy(modelVersion = "test-0")).selectLook(lookBook.stops("cat-mono")[0].ref())
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
        assertContentEquals(render(display, null, 0f, lookBook.stops("cat-mono")[0].ref()), vm.previewPixels(), "Looks still work on the Original")
    }

    // --- Resolving a saved Look against this build's pack (shared/fixtures/edit-state/README.md) --

    private fun handleWith(session: EditSession) = SavedStateHandle(
        mapOf(EditorViewModel.KEY_ASSET to assetId, EditorViewModel.KEY_SESSION to SavedEdits.encodeEditSession(session)),
    )

    @Test
    fun `a Look missing from the pack is unavailable - kept in the edit, not rendered, never substituted`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val missing = LookRef("film.discontinued", "0123456789ab", 0.7f)
        val edit = EditSession.start(source, auto).selectLook(missing)

        val vm = viewModel(handleWith(edit), environment(fakes))
        advanceUntilIdle()

        assertEquals(LookIssue.Unavailable(missing), vm.uiState.value.lookIssue)
        assertEquals(edit, vm.uiState.value.session, "LookRef and history are kept unchanged")
        assertContentEquals(render(display, expectedAutoLut, 0.8f, null), vm.previewPixels(), "rendered with Auto only")
        assertFalse(vm.showsStrength, "no Strength for a Look that is not rendered")
        assertFalse(vm.uiState.value.lookIssue!!.offersCurrentVersion)
    }

    @Test
    fun `a Look whose version differs is changed - not rendered until the user accepts the current version`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val current = lookBook.stops("cat-warm")[1]
        val older = current.ref(0.6f).copy(lookVersion = "000000000000")
        val edit = EditSession.start(source, auto).selectLook(older)

        val vm = viewModel(handleWith(edit), environment(fakes))
        advanceUntilIdle()

        val issue = assertIs<LookIssue.Changed>(vm.uiState.value.lookIssue)
        assertEquals(older, issue.saved)
        assertTrue(issue.offersCurrentVersion)
        assertEquals(edit, vm.uiState.value.session, "nothing is applied until the user accepts")
        assertContentEquals(render(display, expectedAutoLut, 0.8f, null), vm.previewPixels(), "rendered without the Look")
        assertEquals(0, vm.stopIndex, "the slider shows what the photo shows")

        vm.useCurrentLookVersion()
        advanceUntilIdle()
        assertEquals(current.ref(0.6f), vm.uiState.value.session!!.current.look, "same Look and strength, current version")
        assertEquals(edit.history.entries.size + 1, vm.uiState.value.session!!.history.entries.size, "accepting is one new step")
        assertNull(vm.uiState.value.lookIssue)
        assertContentEquals(render(display, expectedAutoLut, 0.8f, current.ref(0.6f)), vm.previewPixels())

        vm.undo()
        advanceUntilIdle()
        assertEquals(older, vm.uiState.value.session!!.current.look, "undo returns to the saved version")
        assertIs<LookIssue.Changed>(vm.uiState.value.lookIssue)
        assertContentEquals(render(display, expectedAutoLut, 0.8f, null), vm.previewPixels())
    }

    @Test
    fun `save copy of an edit with a changed or unavailable Look writes what is displayed and keeps the notice`() = runTest {
        listOf(
            LookRef("film.discontinued", "0123456789ab", 1f),
            lookBook.stops("cat-film")[0].ref().copy(lookVersion = "legacy-v1-3"),
        ).forEach { saved ->
            val fakes = Fakes(DevelopResult.Developed(auto))
            val vm = viewModel(handleWith(EditSession.start(source, auto).selectLook(saved)), environment(fakes))
            advanceUntilIdle()

            assertTrue(vm.saveCopy())
            advanceUntilIdle()

            val savedAsset = assertIs<SaveStatus.Saved>(vm.uiState.value.save).newAssetId
            assertContentEquals(render(fullResolution, expectedAutoLut, 0.8f, null), fakes.written.getValue(savedAsset).toByteArray(), saved.lookId)
            assertNotNull(vm.uiState.value.lookIssue, "the notice stays visible after saving")
        }
    }

    @Test
    fun `an unavailable or changed Look is never dropped - re-saving writes the original LookRef back unchanged`() = runTest {
        listOf(
            LookRef("film.discontinued", "0123456789ab", 0.7f),
            lookBook.stops("cat-warm")[1].ref(0.6f).copy(lookVersion = "legacy-v1-2"),
        ).forEach { saved ->
            val fakes = Fakes(DevelopResult.Developed(auto))
            val edit = EditSession.start(source, auto).selectLook(saved)
            val handle = handleWith(edit)
            val vm = viewModel(handle, environment(fakes))
            advanceUntilIdle()

            // Everything that re-writes the saved session or touches the edit without changing it.
            vm.setCompare(true); vm.setCompare(false)
            vm.selectCategory("cat-mono")
            assertTrue(vm.saveCopy())
            advanceUntilIdle()
            assertEquals(edit, SavedEdits.decodeEditSession(handle.get<String>(EditorViewModel.KEY_SESSION)!!), "${saved.lookId}: saved JSON keeps the LookRef")

            // A new Look over it, then Undo: the original LookRef comes back, still reported.
            vm.selectCategory("cat-film")
            vm.onStopSettled(1)
            vm.undo()
            advanceUntilIdle()
            assertEquals(saved, vm.uiState.value.session!!.current.look)
            assertNotNull(vm.uiState.value.lookIssue)

            // Process death and restore: still there, still not applied, still reported.
            val restored = viewModel(afterProcessDeath(handle), environment(fakes))
            advanceUntilIdle()
            assertEquals(saved, restored.uiState.value.session!!.current.look, "${saved.lookId}: survives process death")
            assertEquals(edit.history.entries, restored.uiState.value.session!!.history.entries.take(edit.history.entries.size), "history unchanged")
            assertEquals(saved, restored.uiState.value.lookIssue?.saved)
        }
    }

    @Test
    fun `undo after Use current version returns to the changed, unrendered state with the original version recorded`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val older = lookBook.stops("cat-film")[1].ref(0.9f).copy(lookVersion = "legacy-v1-4")
        val handle = handleWith(EditSession.start(source, auto).selectLook(older))
        val vm = viewModel(handle, environment(fakes))
        advanceUntilIdle()

        vm.useCurrentLookVersion()
        vm.undo()
        advanceUntilIdle()

        assertEquals(older, vm.uiState.value.session!!.current.look)
        assertEquals("legacy-v1-4", SavedEdits.decodeEditSession(handle.get<String>(EditorViewModel.KEY_SESSION)!!).current.look!!.lookVersion)
        assertEquals(LookIssue.Changed(older, lookBook.stops("cat-film")[1].lookVersion), vm.uiState.value.lookIssue)
        assertContentEquals(render(display, expectedAutoLut, 0.8f, null), vm.previewPixels())
        assertTrue(vm.uiState.value.session!!.canRedo, "Redo re-applies the accepted version")
    }

    @Test
    fun `a schema 1 saved session is restored through migration and its Look shows as changed`() = runTest {
        // The shared v1 fixture as SavedStateHandle would hold it after updating from a schema 1 build.
        val v1State = SharedEditStateFixtureFiles.read(SharedEditStateFixtureFiles.V1_NUMERIC_LOOK_VERSION)
        val v1Session = """{"history":{"entries":[$v1State],"cursor":0,"capacity":50},"lastIssuedRevision":7}"""
        val fixtureSource = SourceRef("content://media/picker/0/42", SourceFingerprint("ab".repeat(32), 1_048_576, 4032, 3024), orientation = 6)
        val portraPack = FixtureLookPack.book(listOf(FixtureLookPack.Category("cat-film", "Film", listOf(FixtureLookPack.Stop("film.portra", "Portra", 7)))))
        val fakes = Fakes(DevelopResult.Developed(auto))
        val loader = PhotoLoader { LoadedPhoto(fixtureSource, analysis, display, FullResolutionSource { fullResolution }) }
        val handle = SavedStateHandle(mapOf(EditorViewModel.KEY_ASSET to fixtureSource.assetId, EditorViewModel.KEY_SESSION to v1Session))

        val vm = viewModel(handle, environment(fakes, photoLoader = loader, lookBook = portraPack))
        advanceUntilIdle()

        assertEquals(EditorPhase.Ready, vm.uiState.value.phase)
        assertTrue(fakes.developedWith.isEmpty(), "the migrated edit is restored, not re-developed")
        val look = assertNotNull(vm.uiState.value.session!!.current.look)
        assertEquals(LookRef("film.portra", "legacy-v1-2", 0.8f), look)
        assertIs<LookIssue.Changed>(vm.uiState.value.lookIssue)

        vm.useCurrentLookVersion()
        advanceUntilIdle()
        assertEquals(portraPack.stops("cat-film")[0].ref(0.8f), vm.uiState.value.session!!.current.look)
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

    // --- Read access to the picked photo across restarts (Codex finding 4) ------------------------

    private fun savedEdit(): Map<String, Any> = mapOf(
        EditorViewModel.KEY_ASSET to assetId,
        EditorViewModel.KEY_SESSION to SessionJson.encodeToString(EditSession.serializer(), EditSession.start(source, auto).selectLook(lookBook.stops("cat-film")[0].ref())),
    )

    @Test
    fun `picking a photo persists read access to it`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        readyViewModel(fakes)

        assertEquals(listOf("retain $assetId"), fakes.grants.events)
    }

    @Test
    fun `a photo whose grant cannot be persisted still opens for this process`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto)).apply { grants.persistable = false }
        val vm = readyViewModel(fakes)

        assertEquals(EditorPhase.Ready, vm.uiState.value.phase)
    }

    @Test
    fun `switching photos releases the previous photo's grant, re-picking the same photo keeps it`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val vm = viewModel(SavedStateHandle(), environment(fakes, photoLoader = twoPhotoLoader(), autoDeveloper = twoPhotoDeveloper { DevelopResult.Developed(auto) }))

        vm.openPhoto(assetId)
        vm.openPhoto(assetId)
        vm.openPhoto(assetB)
        advanceUntilIdle()

        // The new grant is taken before the old one is given back, so B is never unreadable.
        assertEquals(listOf("retain $assetId", "retain $assetId", "retain $assetB", "release $assetId"), fakes.grants.events)
    }

    @Test
    fun `restore with retained access reopens the photo and restores the session`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val handle = SavedStateHandle(savedEdit())

        val vm = viewModel(handle, environment(fakes))
        advanceUntilIdle()

        assertEquals(EditorPhase.Ready, vm.uiState.value.phase)
        assertEquals(lookBook.stops("cat-film")[0].ref(), vm.uiState.value.session!!.current.look)
        assertTrue(fakes.grants.events.isEmpty(), "restore uses the grant persisted at pick time; it takes or drops nothing")
    }

    @Test
    fun `restore after the grant was lost offers to choose the photo again`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val handle = SavedStateHandle(savedEdit())
        val revoked = PhotoLoader { id ->
            when (id) {
                assetId -> throw PhotoAccessLostException(SecurityException("Permission Denial: reading $id requires a grant"))
                else -> twoPhotoLoader().load(id)
            }
        }

        val vm = viewModel(handle, environment(fakes, photoLoader = revoked, autoDeveloper = twoPhotoDeveloper { DevelopResult.Developed(auto) }))
        advanceUntilIdle()

        assertEquals(EditorPhase.PhotoAccessLost, vm.uiState.value.phase)
        assertNull(vm.uiState.value.session, "the edit of an unreadable photo is not shown")
        assertNull(handle[EditorViewModel.KEY_ASSET], "a later restart must not retry the dead URI")
        assertNull(handle.get<String>(EditorViewModel.KEY_SESSION))
        assertEquals(listOf("release $assetId"), fakes.grants.events, "the dead grant is given back")

        // "Choose the photo again" → picker → openPhoto.
        vm.openPhoto(assetB)
        advanceUntilIdle()
        assertEquals(EditorPhase.Ready, vm.uiState.value.phase)
        assertEquals(sourceB, vm.uiState.value.session!!.current.source)
    }

    @Test
    fun `any other load failure is still LoadFailed`() = runTest {
        val fakes = Fakes(DevelopResult.Developed(auto))
        val vm = viewModel(SavedStateHandle(savedEdit()), environment(fakes, photoLoader = PhotoLoader { throw java.io.IOException("Unsupported image format") }))
        advanceUntilIdle()

        assertEquals(EditorPhase.LoadFailed("Unsupported image format"), vm.uiState.value.phase)
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
