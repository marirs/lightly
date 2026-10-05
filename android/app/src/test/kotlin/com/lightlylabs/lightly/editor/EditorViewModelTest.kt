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
import com.lightlylabs.lightly.session.LookRef
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The slice-2 session: one photo, one recipe history, latest-wins previews, Save copy of the committed recipe. */
@OptIn(ExperimentalCoroutinesApi::class)
class EditorViewModelTest {
    private val library = BundledPack.library
    private val hiking = BundledPack.preset("landscape", 37)

    private fun image(width: Int, height: Int, seed: Int) = Rgba8Image(width, height, ByteArray(width * height * 4) { i -> if (i % 4 == 3) -1 else ((i * 37 + seed * 11) % 251).toByte() })

    private class MemoryGateway : MediaStoreGateway<String> {
        val files = mutableMapOf<String, ByteArrayOutputStream>()
        override fun insertPending(spec: NewImageSpec) = "content://media/new/${files.size + 1}"
        override fun openForWrite(handle: String): OutputStream = ByteArrayOutputStream().also { files[handle] = it }
        override fun publish(handle: String) = true
        override fun delete(handle: String) { files.remove(handle) }
    }

    private class Favourites : FavouritesStore {
        private val state = MutableStateFlow<List<String>>(emptyList())
        override val favourites: StateFlow<List<String>> = state
        override fun update(change: (List<String>) -> List<String>) { state.value = change(state.value) }
    }

    private class Harness(test: TestScope, private val loadDelays: Map<String, Long> = emptyMap()) {
        val dispatcher = StandardTestDispatcher(test.testScheduler)
        val gateway = MemoryGateway()
        val favourites = Favourites()
        val released = mutableListOf<String>()
        val full = mutableMapOf<String, Rgba8Image>()

        fun env(o: EditorViewModelTest) = EditorEnvironment(
            photoLoader = PhotoLoader { asset ->
                delay(loadDelays[asset] ?: 0)
                val fingerprint = SourceFingerprint("ab".repeat(32), 1000, 96, 64)
                val fullImage = o.image(96, 64, asset.hashCode()).also { full[asset] = it }
                LoadedPhoto(SourceRef(asset, fingerprint, 1), o.image(24, 16, 1), o.image(48, 32, asset.hashCode()), FullResolutionSource { fullImage })
            },
            photoAccess = object : PhotoAccessGrants {
                override fun retain(assetId: String) = true
                override fun release(assetId: String) { released += assetId }
            },
            autoDeveloper = AutoDeveloper { _, _ -> DevelopResult.NoModelInThisBuild },
            personDetector = PendingPersonDetector,
            library = CompletableDeferred(o.library),
            previewRenderer = DevelopRenderer(),
            renderDispatcher = dispatcher,
            prefetchDispatcher = dispatcher,
            exporter = ExportCoordinator(
                SaveCopyExporter(gateway, JpegEncoder<Rgba8ExportFrame> { frame, _, sink -> sink.write(frame.pixels) }),
                Rgba8ExportFrame.factory, dispatcher, maxTileEdge = 32,
            ),
            favourites = favourites,
            debugBuild = true,
        )

        fun vm(o: EditorViewModelTest) = EditorViewModel(SavedStateHandle(), env(o), CoroutineScope(SupervisorJob() + dispatcher))
    }

    @AfterTest
    fun tearDown() = Dispatchers.resetMain()

    private fun TestScope.ready(harness: Harness = Harness(this)): Pair<EditorViewModel, Harness> {
        Dispatchers.setMain(harness.dispatcher)
        val vm = harness.vm(this@EditorViewModelTest)
        vm.openPhoto("content://photo/1")
        advanceUntilIdle()
        return vm to harness
    }

    @Test
    fun `a photo opens to the editor with the approved unavailable Auto state and a neutral recipe`() = runTest {
        val (vm, _) = ready()
        val ui = vm.uiState.value
        assertEquals(EditorPhase.Ready, ui.phase)
        assertEquals(AutoState.UNAVAILABLE, ui.auto)
        assertNull(ui.session!!.current.look)
        assertFalse(ui.canUndo)
        assertNotNull(ui.preview)
        assertEquals("Original", vm.panelModel()!!.name)
    }

    @Test
    fun `dragging the ruler previews without committing, and release is one undo step`() = runTest {
        val (vm, _) = ready()
        (1..20).forEach { vm.onRulerDrag(it) }
        advanceUntilIdle()
        assertNull(vm.uiState.value.session!!.current.look, "dragging never commits")
        assertEquals(1, vm.uiState.value.session!!.history.entries.size)

        vm.onRulerRelease(37)
        advanceUntilIdle()
        val session = vm.uiState.value.session!!
        assertEquals(hiking.id, session.current.look?.lookId)
        assertEquals(2, session.history.entries.size)
        assertNull(vm.uiState.value.develop.dragStop)
    }

    @Test
    fun `changing category alone never changes the Look`() = runTest {
        val (vm, _) = ready()
        vm.onRulerDrag(37); vm.onRulerRelease(37); advanceUntilIdle()
        vm.selectCategory("cinematic")
        advanceUntilIdle()
        assertEquals(hiking.id, vm.uiState.value.session!!.current.look?.lookId)
        assertEquals("Applied from Landscape", vm.panelModel()!!.context)
        assertEquals(2, vm.uiState.value.session!!.history.entries.size)
    }

    @Test
    fun `re-selecting the applied preset keeps its Amount and adds no step`() = runTest {
        val (vm, _) = ready()
        vm.onRulerDrag(37); vm.onRulerRelease(37); advanceUntilIdle()
        vm.openAmount(); vm.onAmountDrag(50); vm.onAmountRelease(70); vm.amountDone(); advanceUntilIdle()
        val before = vm.uiState.value.session!!
        assertEquals(0.7f, before.current.look?.strength)
        vm.onRulerDrag(40); vm.onRulerDrag(37); vm.onRulerRelease(37); advanceUntilIdle()
        assertEquals(before, vm.uiState.value.session)
    }

    @Test
    fun `a new Look replaces only the Develop Look and undo or redo restore whole recipes`() = runTest {
        val (vm, _) = ready()
        vm.onRulerDrag(37); vm.onRulerRelease(37); advanceUntilIdle()
        val first = vm.uiState.value.session!!.current
        vm.onRulerDrag(38); vm.onRulerRelease(38); advanceUntilIdle()
        val second = vm.uiState.value.session!!.current
        assertEquals(first.tools, second.tools)
        vm.undo(); advanceUntilIdle()
        assertEquals(first.copy(revision = 0), vm.uiState.value.session!!.current.copy(revision = 0))
        vm.redo(); advanceUntilIdle()
        assertEquals(second, vm.uiState.value.session!!.current)
    }

    /** Owner feedback 2026-10-05: apply Landscape -> browse Portrait -> apply Portrait -> Undo -> Redo, all consistent. */
    @Test
    fun `browsing and applying across categories with undo and redo keep photo, underline, dot and name in agreement`() = runTest {
        val (vm, _) = ready()
        fun model() = vm.panelModel()!!
        fun dotted() = model().categories.filter { it.dotted && !it.isFavourites }.map { it.id }
        vm.selectCategory("landscape"); vm.onRulerDrag(3); vm.onRulerRelease(3); advanceUntilIdle()
        val landscape = BundledPack.preset("landscape", 3)
        assertEquals(landscape.id, vm.uiState.value.session!!.current.look?.lookId)
        assertEquals("landscape", model().categoryId); assertEquals(listOf("landscape"), dotted()); assertEquals(landscape.displayName, model().name)

        vm.selectCategory("portrait"); advanceUntilIdle()
        assertEquals(landscape.id, vm.uiState.value.session!!.current.look?.lookId, "browsing changes nothing")
        assertEquals("portrait", model().categoryId); assertEquals(listOf("landscape"), dotted())
        assertEquals(landscape.displayName, model().name); assertEquals("Applied from Landscape", model().context)

        vm.onRulerDrag(2); vm.onRulerRelease(2); advanceUntilIdle()
        val portrait = BundledPack.preset("portrait", 2)
        assertEquals(portrait.id, vm.uiState.value.session!!.current.look?.lookId)
        assertEquals("portrait", model().categoryId); assertEquals(listOf("portrait"), dotted()); assertEquals(portrait.displayName, model().name)

        vm.undo(); advanceUntilIdle()
        assertEquals(landscape.id, vm.uiState.value.session!!.current.look?.lookId)
        assertEquals("landscape", model().categoryId, "after Undo the underline returns to the applied category")
        assertEquals(listOf("landscape"), dotted()); assertEquals(landscape.displayName, model().name); assertEquals(3, model().stop)

        vm.redo(); advanceUntilIdle()
        assertEquals(portrait.id, vm.uiState.value.session!!.current.look?.lookId)
        assertEquals("portrait", model().categoryId); assertEquals(listOf("portrait"), dotted()); assertEquals(2, model().stop)
    }

    @Test
    fun `unavailable Auto explains itself only when tapped`() = runTest {
        val (vm, _) = ready()
        assertNull(vm.panelModel()!!.notice)
        vm.toggleAuto()
        assertEquals(EditorViewModel.AUTO_UNAVAILABLE, vm.uiState.value.toast)
    }

    @Test
    fun `favourites hold five, a sixth star shows the full notice, and Replace swaps one`() = runTest {
        val (vm, harness) = ready()
        val five = (1..5).map { BundledPack.preset("film", it).id }
        harness.favourites.update { five }
        vm.onRulerDrag(37); vm.onRulerRelease(37); advanceUntilIdle()
        vm.toggleStar()
        assertEquals(five, harness.favourites.favourites.value)
        assertEquals(DevelopNotice.FavouritesFull, vm.panelModel()!!.notice)
        vm.openFavouriteReplace()
        assertEquals(EditorOverlay.FAVOURITE_REPLACE, vm.uiState.value.overlay)
        vm.replaceFavourite(five[2])
        assertEquals(five.take(2) + hiking.id + five.drop(3), harness.favourites.favourites.value)
        assertNull(vm.uiState.value.overlay)
        assertNull(vm.panelModel()!!.notice)
        vm.toggleStar() // unstar
        assertFalse(hiking.id in harness.favourites.favourites.value)
    }

    @Test
    fun `switching photos invalidates the previous photo's late load`() = runTest {
        val harness = Harness(this, loadDelays = mapOf("content://photo/slow" to 1000))
        Dispatchers.setMain(harness.dispatcher)
        val vm = harness.vm(this@EditorViewModelTest)
        vm.openPhoto("content://photo/slow")
        advanceTimeBy(10)
        vm.openPhoto("content://photo/fast")
        advanceUntilIdle()
        assertEquals("content://photo/fast", vm.uiState.value.session!!.current.source.assetId)
        assertEquals(listOf("content://photo/slow"), harness.released)
    }

    @Test
    fun `Save copy writes the committed recipe at full resolution, the same render the preview uses`() = runTest {
        val (vm, harness) = ready()
        vm.onRulerDrag(37); vm.onRulerRelease(37); advanceUntilIdle()
        vm.onRulerDrag(80) // a transient preview must never be exported
        vm.saveCopy()
        advanceUntilIdle()
        assertEquals(EditorOverlay.SAVED, vm.uiState.value.overlay)
        val written = harness.gateway.files.values.single().toByteArray()
        val committed = vm.uiState.value.session!!.current
        val expected = DevelopRenderer().render(harness.full.getValue("content://photo/1"), library.planFor(committed))
        assertEquals(hiking.id, committed.look?.lookId)
        assertContentEquals(expected.pixels, written)
    }

    /** Free crop (owner amendment 2026-10-05): the crop editor previews the whole frame; Save copy writes the crop; Undo/Redo. */
    @Test
    fun `the crop editor previews the whole frame while Save copy, Undo and Redo use the crop`() = runTest {
        val (vm, harness) = ready()
        val full = vm.uiState.value.preview!!.let { it.width to it.height }
        vm.commitCrop(com.lightlylabs.lightly.session.NormalisedRect(0.25, 0.0, 0.5, 1.0)); advanceUntilIdle()
        assertEquals(com.lightlylabs.lightly.session.CropAspect.FREE, vm.uiState.value.session!!.current.tools.edit.geometry.crop.aspect)
        assertEquals(full.first / 2, vm.uiState.value.preview!!.width, "outside Crop the preview is cropped")

        vm.selectTool(EditorTool.EDIT); vm.selectEditSub(EditSub.CROP); advanceUntilIdle()
        assertTrue(vm.isCropEditing())
        assertEquals(full, vm.uiState.value.preview!!.let { it.width to it.height }, "the crop editor shows the whole frame")

        vm.saveCopy(); advanceUntilIdle()
        val written = harness.gateway.files.values.single().toByteArray()
        assertEquals(48 * 64 * 4, written.size, "Save copy writes the crop (48 x 64 of the 96 x 64 photo), not the crop editor's view")

        vm.commitCrop(com.lightlylabs.lightly.session.NormalisedRect(0.0, 0.0, 0.8, 0.8)); advanceUntilIdle()
        vm.undo(); advanceUntilIdle()
        assertEquals(com.lightlylabs.lightly.session.NormalisedRect(0.25, 0.0, 0.5, 1.0), vm.uiState.value.session!!.current.tools.edit.geometry.crop.rect)
        vm.redo(); advanceUntilIdle()
        assertEquals(com.lightlylabs.lightly.session.NormalisedRect(0.0, 0.0, 0.8, 0.8), vm.uiState.value.session!!.current.tools.edit.geometry.crop.rect)
    }

    @Test
    fun `leaving asks first only when there are unsaved changes`() = runTest {
        val (vm, _) = ready()
        var left = 0
        vm.onLeave = { left++ }
        vm.close()
        assertEquals(1, left, "nothing changed: leave at once")
        vm.onRulerDrag(37); vm.onRulerRelease(37); advanceUntilIdle()
        vm.close()
        assertEquals(EditorOverlay.LEAVE, vm.uiState.value.overlay)
        assertEquals(1, left)
        vm.discardAndLeave()
        assertEquals(2, left)
    }

    @Test
    fun `compare shows the original while held and as an accessible toggle`() = runTest {
        val (vm, _) = ready()
        vm.holdCompare(true)
        assertTrue(vm.uiState.value.showsOriginal)
        vm.holdCompare(false)
        assertFalse(vm.uiState.value.showsOriginal)
        vm.toggleCompare()
        assertTrue(vm.uiState.value.showsOriginal)
    }

    @Test
    fun `a stored Look the pack does not have is never rendered or substituted`() = runTest {
        val (vm, _) = ready()
        val unknown = vm.uiState.value.session!!.current.copy(look = LookRef("look-not-in-pack", "000000000000", 1f))
        assertTrue(library.planFor(unknown).isIdentity)
    }
}
