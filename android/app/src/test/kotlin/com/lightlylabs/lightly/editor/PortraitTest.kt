package com.lightlylabs.lightly.editor

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
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
import com.lightlylabs.lightly.session.NormalisedRect
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef
import com.lightlylabs.lightly.shell.LightlyTheme
import com.lightlylabs.lightly.shell.ShellLayout
import com.lightlylabs.lightly.vision.DetectedFace
import com.lightlylabs.lightly.vision.FaceMeshRegions
import com.lightlylabs.lightly.vision.PeopleAnalysis
import com.lightlylabs.lightly.vision.Point
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.OutputStream
import java.util.concurrent.Executors
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Portrait on Robolectric (phone layout): visibility from the people analysis (prototype `toolsFor`),
 * the approved face strip, tabs, sliders and notes, per-face settings with change counts, and one undo
 * step per release. Rendering of the operators is covered in core-vision; pixels on emulators.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w427dp-h952dp")
class PortraitTest {
    @get:Rule
    val compose = createComposeRule()

    private val render = Executors.newSingleThreadExecutor().asCoroutineDispatcher()

    private fun image(w: Int, h: Int) = Rgba8Image(w, h, ByteArray(w * h * 4) { if (it % 4 == 3) -1 else (it % 200).toByte() })

    private fun face(x: Double, presence: Float = 1f) =
        DetectedFace(NormalisedRect(x, 0.2, 0.2, 0.3), 0.9f, presence, if (presence >= 0.5f) List(FaceMeshRegions.LANDMARK_COUNT) { Point(x + 0.1, 0.35) } else emptyList())

    private fun editor(people: PeopleAnalysis?, debugBuild: Boolean = false): EditorViewModel {
        val favourites = object : FavouritesStore {
            private val state = MutableStateFlow<List<String>>(emptyList())
            override val favourites: StateFlow<List<String>> = state
            override fun update(change: (List<String>) -> List<String>) { state.value = change(state.value) }
        }
        val gateway = object : MediaStoreGateway<String> {
            override fun insertPending(spec: NewImageSpec) = "content://new/1"
            override fun openForWrite(handle: String): OutputStream = OutputStream.nullOutputStream()
            override fun publish(handle: String) = true
            override fun delete(handle: String) = Unit
        }
        val env = EditorEnvironment(
            photoLoader = PhotoLoader { asset ->
                LoadedPhoto(SourceRef(asset, SourceFingerprint("ab".repeat(32), 10, 30, 45), 1), image(20, 30), image(30, 45), FullResolutionSource { image(30, 45) })
            },
            photoAccess = object : PhotoAccessGrants {
                override fun retain(assetId: String) = true
                override fun release(assetId: String) = Unit
            },
            autoDeveloper = AutoDeveloper { _, _, _ -> DevelopResult.NoModelInThisBuild },
            personDetector = PersonDetector { people },
            library = CompletableDeferred(BundledPack.library),
            previewRenderer = DevelopRenderer(),
            renderDispatcher = render,
            prefetchDispatcher = render,
            exporter = ExportCoordinator(SaveCopyExporter(gateway, JpegEncoder<Rgba8ExportFrame> { _, _, _ -> }), Rgba8ExportFrame.factory, render),
            favourites = favourites,
            debugBuild = debugBuild,
        )
        return EditorViewModel(SavedStateHandle(), env, CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate))
    }

    private fun show(vm: EditorViewModel) {
        compose.setContent {
            LightlyTheme(dark = false) { EditorScreen(vm, ShellLayout.Compact, EditorActions({}, {}, {})) }
        }
        vm.openPhoto("content://photo/1")
        compose.waitUntil(10_000) { vm.uiState.value.phase == EditorPhase.Ready }
        compose.waitForIdle()
    }

    @Test
    fun `Portrait appears only when a person or face is found`() {
        val nobody = editor(PeopleAnalysis.NONE, debugBuild = true)
        show(nobody)
        assertFalse(EditorTool.PORTRAIT in nobody.uiState.value.tools, "no person: hidden, even in debug builds")
        compose.onNodeWithTag(EditorTags.tool(EditorTool.PORTRAIT)).assertDoesNotExist()
    }

    @Test
    fun `with no usable face, the faces get the dim rings and a pose detection only when no face was found`() {
        // The bar photo (2026-10-05): an unusable face at the bar, and the pose detector's false "person" on the lamp.
        val atTheBar = face(0.45, presence = 0f)
        val lamp = NormalisedRect(0.29, 0.0, 0.3, 0.18)
        assertEquals(listOf(atTheBar.box), unusableMarks(PeopleAnalysis(listOf(atTheBar), listOf(lamp))))
        assertEquals(listOf(lamp), unusableMarks(PeopleAnalysis(emptyList(), listOf(lamp))), "someone seen from behind")
        assertEquals(emptyList(), unusableMarks(PeopleAnalysis(listOf(face(0.4)), listOf(lamp))), "a usable face: no dim rings")
    }

    @Test
    fun `people without a usable face get the approved notice`() {
        val vm = editor(PeopleAnalysis(listOf(face(0.4, presence = 0f)), listOf(NormalisedRect(0.1, 0.1, 0.1, 0.1))))
        show(vm)
        assertTrue(EditorTool.PORTRAIT in vm.uiState.value.tools)
        compose.onNodeWithTag(EditorTags.tool(EditorTool.PORTRAIT)).performClick()
        compose.waitForIdle()
        compose.onNodeWithText("No face can be edited in this photo.", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Faces are too small, turned away or too dark. Portrait controls need a clear face.", substring = true).assertIsDisplayed()
    }

    @Test
    fun `one face shows no face strip, and the approved tabs, sliders and notes`() {
        val vm = editor(PeopleAnalysis(listOf(face(0.4)), emptyList()))
        show(vm)
        compose.onNodeWithTag(EditorTags.tool(EditorTool.PORTRAIT)).performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Each face keeps its own settings.").assertDoesNotExist()
        listOf("Skin", "Under-eye", "Eyes", "Teeth", "Hair & Beard", "Smoothing", "Blemishes", "Even tone", "Keep texture",
            "Blemish reduction is temporary marks only. Pores, freckles, moles and skin tone colour stay.").forEach { compose.onNodeWithText(it).assertExists() }
        compose.onNodeWithText("85").assertExists()
        compose.onNodeWithText("Eyes").performClick()
        compose.waitForIdle()
        listOf("Brighten", "Clarity", "Eye colour and shape are never changed.").forEach { compose.onNodeWithText(it).assertExists() }
        compose.onNodeWithText("Teeth").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Stays within a natural range. There is no automatic whitening.").assertExists()
        compose.onNodeWithText("Hair & Beard").performClick()
        compose.waitForIdle()
        listOf("Definition", "Flyaways", "Shine").forEach { compose.onNodeWithText(it).assertExists() }
        compose.onNodeWithText("Under-eye").performClick()
        compose.waitForIdle()
        listOf("Brighten", "Soften lines").forEach { compose.onNodeWithText(it).assertExists() }
    }

    @Test
    fun `several faces keep their own settings, with change counts on their chips`() {
        val vm = editor(PeopleAnalysis(listOf(face(0.6), face(0.1)), emptyList()))
        show(vm)
        compose.onNodeWithTag(EditorTags.tool(EditorTool.PORTRAIT)).performClick()
        compose.waitForIdle()
        // Ordered left to right whatever order the detector returned.
        assertTrue(vm.usableFaces[0].box.x < vm.usableFaces[1].box.x)
        compose.onNodeWithText("Each face keeps its own settings.").assertIsDisplayed()
        compose.onNodeWithTag(PortraitTags.slider("skin.smoothing")).performSemanticsAction(SemanticsActions.SetProgress) { it(30f) }
        compose.waitForIdle()
        compose.onNodeWithTag(PortraitTags.face(0)).assert(hasText("Face 1 · 1"))
        compose.onNodeWithTag(PortraitTags.face(1)).assert(hasText("Face 2"))
        // Each face's ring is a button named for its face, with its tag under it.
        compose.onNodeWithTag(PortraitTags.ring(1)).assert(hasText("Face 2"))
        assertEquals(2, vm.uiState.value.session!!.history.entries.size, "one undo step per release")
        compose.onNodeWithTag(PortraitTags.face(1)).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(PortraitTags.slider("skin.blemishes")).performSemanticsAction(SemanticsActions.SetProgress) { it(10f) }
        compose.onNodeWithTag(PortraitTags.slider("skin.keepTexture")).performSemanticsAction(SemanticsActions.SetProgress) { it(50f) }
        compose.waitForIdle()
        compose.onNodeWithTag(PortraitTags.face(1)).assert(hasText("Face 2 · 2"))
        val faces = vm.uiState.value.session!!.current.tools.portrait.faces
        assertEquals(2, faces.size)
        assertEquals(30.0, faces.first { it.face.box == vm.usableFaces[0].box }.skin.smoothing)
        assertEquals(0.0, faces.first { it.face.box == vm.usableFaces[1].box }.skin.smoothing)
        // The dock marks Portrait as used.
        compose.onNodeWithTag(EditorTags.tool(EditorTool.PORTRAIT)).assertExists()
    }
}
