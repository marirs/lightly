package com.lightlylabs.lightly.editor

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.lightlylabs.lightly.model.AutoLutResolution
import com.lightlylabs.lightly.model.AutoLutResolver
import com.lightlylabs.lightly.model.BasisUnavailableReason
import com.lightlylabs.lightly.render.lut.Lut3D
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
    val autoStatus: AutoStatus = AutoStatus.NoSession,
) {
    /** What the photo area shows: the transient preview if any, else the committed state. */
    val displayed: EditState? get() = transientPreview ?: session?.current

    companion object {
        const val DEFAULT_CATEGORY = "Natural"
    }
}

/** Whether the O1 Auto stage can render for the current session (Codex M2 finding 4). */
sealed interface AutoStatus {
    data object NoSession : AutoStatus

    data class Applied(val modelId: String, val modelVersion: String) : AutoStatus

    /**
     * The saved edit names a model version whose basis is not installed or fails verification.
     * Auto renders as identity ("off") and the screen shows [notice]. The stored AutoResult is kept
     * untouched, so the edit renders correctly again once that version is available.
     */
    data class Unavailable(val modelId: String, val modelVersion: String, val reason: BasisUnavailableReason) : AutoStatus {
        val notice: String get() = "Auto enhancement unavailable for this edit (model $modelId $modelVersion is not installed on this device)."
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
class EditorViewModel(
    private val savedState: SavedStateHandle,
    private val autoResolver: AutoLutResolver,
) : ViewModel() {

    // Resolved O1 LUT for the session's AutoResult; null while there is no session or Auto is unavailable.
    // Memoised per AutoResult because every entry of a session shares one Auto result.
    private var resolvedAuto: Pair<AutoResult, AutoLutResolution>? = null

    private val state = MutableStateFlow(restore())

    /**
     * The O1 LUT the renderer must use, or `null` meaning "Auto off" (identity). Never a LUT from a
     * different model version than the one stored in the edit.
     */
    val autoLutForRendering: Lut3D?
        get() = (resolvedAuto?.second as? AutoLutResolution.Ready)?.lut

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
        state.value = state.value.copy(session = session, transientPreview = null, autoStatus = autoStatusFor(session))
    }

    private fun autoStatusFor(session: EditSession?): AutoStatus {
        val auto = session?.current?.auto ?: run {
            resolvedAuto = null
            return AutoStatus.NoSession
        }
        val resolution = resolvedAuto?.takeIf { it.first == auto }?.second
            ?: autoResolver.resolve(auto).also { resolvedAuto = auto to it }
        return when (resolution) {
            is AutoLutResolution.Ready -> AutoStatus.Applied(auto.modelId, auto.modelVersion)
            is AutoLutResolution.AutoUnavailable -> AutoStatus.Unavailable(resolution.modelId, resolution.modelVersion, resolution.reason)
        }
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
            autoStatus = autoStatusFor(session),
        )
    }

    companion object {
        const val KEY_SESSION = "editor.session.json"
        const val KEY_COMPARE = "editor.compare"
        const val KEY_CATEGORY = "editor.category"

        fun factory(autoResolver: AutoLutResolver): ViewModelProvider.Factory = viewModelFactory {
            initializer { EditorViewModel(createSavedStateHandle(), autoResolver) }
        }
    }
}
