package com.lightlylabs.lightly.editor

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import com.lightlylabs.lightly.session.AutoResult
import com.lightlylabs.lightly.session.EditSession
import com.lightlylabs.lightly.session.EditState
import com.lightlylabs.lightly.session.LookRef
import com.lightlylabs.lightly.session.SessionJson
import com.lightlylabs.lightly.session.SourceRef
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Everything the editor screen renders from. */
data class EditorUiState(
    /** Committed history; `null` before a photo is developed. */
    val session: EditSession? = null,
    /** Transient preview while a slider moves (spec §3). Never in history, never persisted. */
    val transientPreview: EditState? = null,
    val compareOn: Boolean = false,
    val selectedCategory: String = DEFAULT_CATEGORY,
) {
    /** What the photo area shows: the transient preview if any, else the committed state. */
    val displayed: EditState? get() = transientPreview ?: session?.current

    companion object {
        const val DEFAULT_CATEGORY = "Natural"
    }
}

/**
 * Editor state holder (spec §8: ViewModel + SavedStateHandle).
 *
 * Configuration changes keep this instance. Process death keeps only [SavedStateHandle], so every
 * committed change writes the session there as JSON (a String, which a Bundle stores natively and
 * which is tiny: no pixels). The proxy is re-decoded on restore (M3). The transient preview is
 * deliberately not saved: after a restore the screen shows the last committed state.
 *
 * State changes are synchronous; rendering is driven from [uiState] by the render scheduler (M3).
 */
class EditorViewModel(private val savedState: SavedStateHandle) : ViewModel() {

    private val state = MutableStateFlow(restore())
    val uiState: StateFlow<EditorUiState> = state.asStateFlow()

    fun startSession(source: SourceRef, auto: AutoResult) {
        commit(EditSession.start(source, auto))
    }

    /** Slider is moving: preview only (Invariant R: candidate replaces the committed Look). */
    fun previewLook(candidate: LookRef?) {
        val session = state.value.session ?: return
        state.value = state.value.copy(transientPreview = session.previewOf(candidate))
    }

    /** Slider settled (pointer up or accessibility increment): one undo step. */
    fun commitLook(look: LookRef?) = updateSession { it.selectLook(look) }

    /** Strength released. */
    fun commitLookStrength(strength: Float) = updateSession { it.setLookStrength(strength) }

    fun resetToAuto() = updateSession { it.resetToAuto() }

    fun undo() = updateSession { it.undo() }

    fun redo() = updateSession { it.redo() }

    fun setCompare(on: Boolean) {
        savedState[KEY_COMPARE] = on
        state.value = state.value.copy(compareOn = on)
    }

    /** Changing category alone does not change the Look (spec §2.4), so it is not an undo step. */
    fun selectCategory(category: String) {
        savedState[KEY_CATEGORY] = category
        state.value = state.value.copy(selectedCategory = category)
    }

    private inline fun updateSession(change: (EditSession) -> EditSession) {
        val session = state.value.session ?: return
        commit(change(session))
    }

    private fun commit(session: EditSession) {
        savedState[KEY_SESSION] = SessionJson.encodeToString(EditSession.serializer(), session)
        state.value = state.value.copy(session = session, transientPreview = null)
    }

    private fun restore(): EditorUiState {
        val session = savedState.get<String>(KEY_SESSION)?.let { json ->
            // A snapshot that no longer decodes (schema change across an app update) starts empty
            // rather than crashing on launch; the recovery snapshot path handles real recovery.
            runCatching { SessionJson.decodeFromString(EditSession.serializer(), json) }.getOrNull()
        }
        return EditorUiState(
            session = session,
            compareOn = savedState.get<Boolean>(KEY_COMPARE) ?: false,
            selectedCategory = savedState.get<String>(KEY_CATEGORY) ?: EditorUiState.DEFAULT_CATEGORY,
        )
    }

    companion object {
        const val KEY_SESSION = "editor.session.json"
        const val KEY_COMPARE = "editor.compare"
        const val KEY_CATEGORY = "editor.category"
    }
}
