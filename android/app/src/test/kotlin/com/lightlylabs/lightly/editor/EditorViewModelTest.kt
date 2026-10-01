package com.lightlylabs.lightly.editor

import androidx.lifecycle.SavedStateHandle
import com.lightlylabs.lightly.session.AutoGuardrail
import com.lightlylabs.lightly.session.AutoResult
import com.lightlylabs.lightly.session.LookRef
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Spec §5.5: the session must survive configuration change and process death. A ViewModel
 * survives configuration change by itself; what has to be proven is that a NEW ViewModel built
 * from the same SavedStateHandle contents (what Android hands back after process death) restores
 * the committed history, cursor, compare state and category exactly.
 */
class EditorViewModelTest {

    private val source = SourceRef(
        assetId = "content://media/picker/0/42",
        fingerprint = SourceFingerprint("ab".repeat(32), 2_000_000, 4032, 3024),
        orientation = 6,
    )
    private val auto = AutoResult("ia3dlut", "research-fivek-1", listOf(1.9f, -0.4f, -0.9f), AutoGuardrail.ENDPOINT_V1, 0.75f)
    private val portra = LookRef("film.portra", 1, 1f)
    private val mono = LookRef("mono.silver", 1, 1f)

    /**
     * Copies only what a Bundle would carry. Asserting the value types catches a future change that
     * puts a non-parcelable object in the handle (which would crash only on a real process death).
     */
    private fun afterProcessDeath(handle: SavedStateHandle): SavedStateHandle {
        val values = handle.keys().associateWith { key -> handle.get<Any>(key) }
        assertTrue(values.values.all { it is String || it is Boolean }, "SavedStateHandle holds non-Bundle types: $values")
        return SavedStateHandle(values)
    }

    @Test
    fun `recreated ViewModel restores history, cursor, compare and category`() {
        val handle = SavedStateHandle()
        val original = EditorViewModel(handle).apply {
            startSession(source, auto)
            commitLook(portra)
            commitLookStrength(0.6f)
            commitLook(mono)
            undo()
            setCompare(true)
            selectCategory("Film")
        }

        val restored = EditorViewModel(afterProcessDeath(handle))

        val before = original.uiState.value
        val after = restored.uiState.value
        assertEquals(before.session, after.session)
        assertEquals(portra.copy(strength = 0.6f), after.session?.current?.look)
        assertTrue(after.session!!.canRedo, "redo of the mono step must survive")
        assertEquals(true, after.compareOn)
        assertEquals("Film", after.selectedCategory)

        // The restored session keeps working, including the revision counter.
        restored.redo()
        assertEquals(mono, restored.uiState.value.session?.current?.look)
        restored.resetToAuto()
        assertEquals(4, restored.uiState.value.session?.current?.revision)
    }

    @Test
    fun `transient preview is shown but neither committed nor persisted`() {
        val handle = SavedStateHandle()
        val viewModel = EditorViewModel(handle).apply {
            startSession(source, auto)
            commitLook(portra)
            previewLook(mono)
        }

        assertEquals(mono, viewModel.uiState.value.displayed?.look, "preview replaces the Look on screen")
        assertEquals(portra, viewModel.uiState.value.session?.current?.look, "but is not committed")

        val restored = EditorViewModel(afterProcessDeath(handle))
        assertNull(restored.uiState.value.transientPreview)
        assertEquals(portra, restored.uiState.value.displayed?.look)
    }

    @Test
    fun `a commit clears the transient preview`() {
        val viewModel = EditorViewModel(SavedStateHandle()).apply {
            startSession(source, auto)
            commitLook(portra)
            previewLook(portra.copy(strength = 0.3f))
            commitLookStrength(0.3f)
        }
        assertNull(viewModel.uiState.value.transientPreview)
        assertEquals(0.3f, viewModel.uiState.value.session?.current?.look?.strength)
    }

    @Test
    fun `an empty handle starts with no session`() {
        val state = EditorViewModel(SavedStateHandle()).uiState.value
        assertNull(state.session)
        assertEquals(EditorUiState.DEFAULT_CATEGORY, state.selectedCategory)
    }

    @Test
    fun `an undecodable saved session starts empty instead of crashing`() {
        val handle = SavedStateHandle(mapOf(EditorViewModel.KEY_SESSION to "{\"schema\":99}"))
        assertNull(EditorViewModel(handle).uiState.value.session)
    }
}
