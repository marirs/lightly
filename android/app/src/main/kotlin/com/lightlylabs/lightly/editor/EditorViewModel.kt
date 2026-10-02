package com.lightlylabs.lightly.editor

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.lightlylabs.lightly.export.ExportJob
import com.lightlylabs.lightly.export.ExportStart
import com.lightlylabs.lightly.export.ExportState
import com.lightlylabs.lightly.model.AutoLutResolution
import com.lightlylabs.lightly.model.BasisUnavailableReason
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.render.lut.LutPassPlan
import com.lightlylabs.lightly.render.schedule.PreviewRenderer
import com.lightlylabs.lightly.render.schedule.RenderOutcome
import com.lightlylabs.lightly.render.schedule.RenderScheduler
import com.lightlylabs.lightly.session.AutoResult
import com.lightlylabs.lightly.session.EditSession
import com.lightlylabs.lightly.session.EditState
import com.lightlylabs.lightly.session.LookRef
import com.lightlylabs.lightly.session.SessionJson
import com.lightlylabs.lightly.session.SourceRef
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Session state machine (spec §5.1). */
sealed interface EditorPhase {
    data object Empty : EditorPhase
    data object Loading : EditorPhase
    data class LoadFailed(val message: String) : EditorPhase

    /**
     * The saved photo can no longer be read, typically after a restart without a persisted grant or
     * after the grant was revoked (Codex finding 4). Recoverable: the screen offers "Choose the
     * photo again", which goes through the picker and [EditorViewModel.openPhoto].
     */
    data object PhotoAccessLost : EditorPhase
    data object Developing : EditorPhase
    data class DevelopFailed(val message: String) : EditorPhase
    data object Ready : EditorPhase
}

sealed interface SaveStatus {
    data object Idle : SaveStatus
    data object Saving : SaveStatus
    data class Saved(val newAssetId: String) : SaveStatus
    data class Failed(val message: String) : SaveStatus
    data object Cancelled : SaveStatus
}

/** Everything the editor screen renders from. */
data class EditorUiState(
    val phase: EditorPhase = EditorPhase.Empty,
    /** Committed history; `null` until a photo is developed (or "Use original" is chosen). */
    val session: EditSession? = null,
    /** Transient preview while a slider moves (spec §3). Never in history, never persisted. */
    val transientPreview: EditState? = null,
    val compareOn: Boolean = false,
    val selectedCategory: String = DEFAULT_CATEGORY,
    val autoStatus: AutoStatus = AutoStatus.NoSession,
    /** Latest preview the scheduler published for the current photo (latest-wins). */
    val preview: Rgba8Image? = null,
    /** Shown when the displayed Look is not in this build's look-book (spec §4.5). */
    val lookNotice: String? = null,
    val save: SaveStatus = SaveStatus.Idle,
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
     * The edit names a model version whose basis is not installed or fails verification. Auto
     * renders as identity ("off") and the screen shows [notice]. The stored AutoResult is kept
     * untouched, so the edit renders correctly again once that version is available.
     */
    data class Unavailable(val modelId: String, val modelVersion: String, val reason: BasisUnavailableReason) : AutoStatus {
        val notice: String get() = "Auto enhancement unavailable for this edit (model $modelId $modelVersion is not installed on this device)."
    }

    /** "Use original" after DevelopFailed (spec §5.1): Auto strength 0, Looks still work. */
    data object UsingOriginal : AutoStatus {
        const val NOTICE = "Auto enhancement unavailable. Looks are applied to the original."
    }
}

/**
 * Editor state holder (spec §8: ViewModel + SavedStateHandle), wiring the M2 modules end to end:
 * pick → analysis decode + display proxy → Auto → Looks (stepped slider) → latest-wins preview
 * through [RenderScheduler] with a two-pass [LutPassPlan] → Compare / Undo / Reset → Save copy via
 * the [ExportCoordinator][com.lightlylabs.lightly.export.ExportCoordinator].
 *
 * Configuration changes keep this instance. Process death keeps only [SavedStateHandle]: the asset
 * ID, the session JSON, compare and category. On restore the photo is decoded again but the model is
 * NOT re-run: the saved AutoResult is used as-is (spec §4.6). The transient preview is not saved.
 */
class EditorViewModel(
    private val savedState: SavedStateHandle,
    private val env: EditorEnvironment,
    private val scope: CoroutineScope,
) : ViewModel(scope) {

    // Resolved O1 LUT for the session's AutoResult (memoised: every entry shares one Auto result).
    private var resolvedAuto: Pair<AutoResult, AutoLutResolution>? = null

    /**
     * The photo on screen, tagged with the [photoGeneration] that loaded it. Every async step for a
     * photo carries its generation and re-checks it after each suspension point (Codex finding 1):
     * cancelling the job is not enough, because a model runtime or decoder may ignore cancellation
     * and still return, and its result must not land in the next photo's session.
     */
    private class CurrentPhoto(val generation: Long, val loaded: LoadedPhoto)

    private var photo: CurrentPhoto? = null
    private var scheduler: RenderScheduler<LutPassPlan, Rgba8Image>? = null
    private var schedulerCollector: Job? = null
    private var loadJob: Job? = null
    private var photoGeneration = 0L

    private val state = MutableStateFlow(
        EditorUiState(
            compareOn = savedState.get<Boolean>(KEY_COMPARE) ?: false,
            selectedCategory = savedState.get<String>(KEY_CATEGORY) ?: env.lookBook.categories.firstOrNull() ?: EditorUiState.DEFAULT_CATEGORY,
        ),
    )
    val uiState: StateFlow<EditorUiState> = state.asStateFlow()

    /** The O1 LUT the renderer must use, or `null` meaning "Auto off" (identity). */
    val autoLutForRendering: Lut3D?
        get() = (resolvedAuto?.second as? AutoLutResolution.Ready)?.lut

    val categories: List<String> get() = env.lookBook.categories

    /** Non-null when this build's Looks are provisional placeholders (debug builds). */
    val lookProvisionalNotice: String? get() = env.lookBook.provisionalNotice

    fun stopNames(category: String): List<String> = env.lookBook.stops(category).map { it.displayName }

    /** Slider position (0 = Auto) of the displayed Look within the selected category. */
    val stopIndex: Int get() = env.lookBook.stopIndexOf(state.value.selectedCategory, state.value.displayed?.look)

    init {
        scope.launch { env.exporter.state.collect { exportState -> state.update { it.copy(save = saveStatusOf(exportState)) } } }
        val assetId = savedState.get<String>(KEY_ASSET)
        if (assetId != null) {
            val restored = savedState.get<String>(KEY_SESSION)?.let { json ->
                // A snapshot that no longer decodes (schema change across an update) is dropped
                // rather than crashing; the photo is then developed again.
                runCatching { SessionJson.decodeFromString(EditSession.serializer(), json) }.getOrNull()
            }?.takeIf { it.current.source.assetId == assetId }
            loadPhoto(assetId, restored)
        }
        addCloseable { scheduler?.close() }
    }

    // --- Photo lifecycle -------------------------------------------------------------------------

    /**
     * Photo Picker result. Leaving a dirty session must be confirmed by the UI first (spec §5.5).
     *
     * Persists read access to the new photo while the picker's temporary grant is still valid, so a
     * restore after process death can reopen it, then gives back the previous photo's grant so
     * grants do not pile up against the per-app cap (Codex finding 4). The new grant is taken first.
     */
    fun openPhoto(assetId: String) {
        val previousAsset = savedState.get<String>(KEY_ASSET)
        env.photoAccess.retain(assetId)
        if (previousAsset != null && previousAsset != assetId) env.photoAccess.release(previousAsset)
        savedState[KEY_ASSET] = assetId
        savedState.remove<String>(KEY_SESSION)
        loadPhoto(assetId, restoredSession = null)
    }

    /** DevelopFailed → [Retry]: one user-initiated model run (spec §5.6). */
    fun retryDevelop() {
        val current = photo?.takeIf { isCurrent(it.generation) } ?: return
        if (state.value.phase !is EditorPhase.DevelopFailed) return
        loadJob = scope.launch { develop(current.loaded, current.generation) }
    }

    /** DevelopFailed → [Use original]: Ready with Auto strength 0 (spec §5.1). */
    fun useOriginal() {
        // Bound to the photo on screen: the DevelopFailed phase can only belong to it, because
        // stale failures are dropped before they reach the phase.
        val loaded = photo?.takeIf { isCurrent(it.generation) }?.loaded ?: return
        if (state.value.phase !is EditorPhase.DevelopFailed) return
        val original = AutoResult(
            modelId = AutoResult.MODEL_ID_IA3DLUT,
            modelVersion = USE_ORIGINAL_MODEL_VERSION,
            weights = listOf(0f, 0f, 0f),
            guardrail = null,
            strength = 0f,
        )
        commit(EditSession.start(loaded.source, original))
        state.update { it.copy(phase = EditorPhase.Ready) }
    }

    private fun loadPhoto(assetId: String, restoredSession: EditSession?) {
        loadJob?.cancel()
        scheduler?.close()
        schedulerCollector?.cancel()
        photo = null
        resolvedAuto = null
        val generation = ++photoGeneration
        state.update { it.copy(phase = EditorPhase.Loading, session = restoredSession, transientPreview = null, preview = null, autoStatus = AutoStatus.NoSession, save = SaveStatus.Idle) }
        loadJob = scope.launch {
            val loaded = try {
                env.photoLoader.load(assetId)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (accessLost: PhotoAccessLostException) {
                if (isCurrent(generation)) enterPhotoAccessLost(assetId)
                return@launch
            } catch (failure: Exception) {
                // A failure for a photo the user has already left must not replace the current phase.
                if (isCurrent(generation)) state.update { it.copy(phase = EditorPhase.LoadFailed(failure.message ?: "Couldn't open this photo")) }
                return@launch
            }
            if (!isCurrent(generation)) return@launch
            photo = CurrentPhoto(generation, loaded)
            startPreviewScheduler(loaded, generation)
            if (restoredSession != null && restoredSession.current.source.fingerprint == loaded.source.fingerprint) {
                // Restore: keep the saved AutoResult; do not re-run the model.
                commit(restoredSession)
                state.update { it.copy(phase = EditorPhase.Ready) }
            } else {
                develop(loaded, generation)
            }
        }
    }

    private fun isCurrent(generation: Long): Boolean = generation == photoGeneration

    /**
     * The saved photo cannot be read any more. Its URI and session are dropped from the saved state
     * so a later restart does not retry a dead URI, and its grant (if any) is given back. The screen
     * offers "Choose the photo again", which is a normal [openPhoto].
     *
     * DEFERRED (M3): re-attaching the dropped edit when the user picks the same photo again (match by
     * SourceFingerprint and rebase the session onto the new URI). Until then the photo develops anew.
     */
    private fun enterPhotoAccessLost(lostAsset: String) {
        savedState.remove<String>(KEY_ASSET)
        savedState.remove<String>(KEY_SESSION)
        env.photoAccess.release(lostAsset)
        state.update { it.copy(phase = EditorPhase.PhotoAccessLost, session = null, transientPreview = null, preview = null, autoStatus = AutoStatus.NoSession) }
    }

    /** Runs Auto for [loaded]; every state change is dropped once [generation] is no longer current. */
    private suspend fun develop(loaded: LoadedPhoto, generation: Long) {
        if (!isCurrent(generation)) return
        state.update { it.copy(phase = EditorPhase.Developing) }
        val result = env.autoDeveloper.develop(loaded.source.fingerprint, loaded.analysis)
        // The developer may ignore cancellation and return after the user picked another photo.
        if (!isCurrent(generation)) return
        when (result) {
            is DevelopResult.Developed -> {
                commit(EditSession.start(loaded.source, result.auto))
                state.update { it.copy(phase = EditorPhase.Ready) }
            }
            is DevelopResult.Failed -> state.update { it.copy(phase = EditorPhase.DevelopFailed(result.message)) }
        }
    }

    private fun startPreviewScheduler(loaded: LoadedPhoto, generation: Long) {
        val display = loaded.display
        val newScheduler = RenderScheduler(
            sessionId = "photo-$generation",
            renderer = PreviewRenderer<LutPassPlan, Rgba8Image> { request -> env.previewRenderer.render(display, request.payload) },
            parentScope = scope,
            renderDispatcher = env.renderDispatcher,
        )
        scheduler = newScheduler
        schedulerCollector = scope.launch {
            newScheduler.published.collect { result ->
                val rendered = (result?.outcome as? RenderOutcome.Rendered)?.value ?: return@collect
                // Session check on top of the scheduler's own: a result for a previous photo is dropped.
                if (result.sessionId == "photo-$photoGeneration") state.update { it.copy(preview = rendered) }
            }
        }
        // Show the Original immediately while Auto develops.
        newScheduler.submit(LutPassPlan.of(null, 0f, null, 0f))
    }

    // --- Looks: stepped slider, strength ---------------------------------------------------------

    /** Changing category alone does not change the Look (spec §2.4), so it is not an undo step. */
    fun selectCategory(category: String) {
        savedState[KEY_CATEGORY] = category
        state.update { it.copy(selectedCategory = category) }
    }

    /** Slider moving over stop [index] (0 = Auto): transient preview only. */
    fun onStopChanged(index: Int) = previewLook(lookAtStop(index))

    /** Slider settled on stop [index] (pointer up / accessibility increment): one undo step. */
    fun onStopSettled(index: Int) = commitLook(lookAtStop(index))

    fun previewLook(candidate: LookRef?) {
        val session = state.value.session ?: return
        state.update { it.copy(transientPreview = session.previewOf(candidate)) }
        requestPreview()
    }

    fun commitLook(look: LookRef?) = updateSession { it.selectLook(look) }

    fun previewLookStrength(strength: Float) {
        val look = state.value.session?.current?.look ?: return
        previewLook(look.copy(strength = strength))
    }

    fun commitLookStrength(strength: Float) = updateSession { it.setLookStrength(strength) }

    fun resetToAuto() = updateSession { it.resetToAuto() }

    fun undo() = updateSession { it.undo() }

    fun redo() = updateSession { it.redo() }

    fun setCompare(on: Boolean) {
        savedState[KEY_COMPARE] = on
        state.update { it.copy(compareOn = on) }
        requestPreview()
    }

    private fun lookAtStop(index: Int): LookRef? {
        if (index == 0) return null
        val stops = env.lookBook.stops(state.value.selectedCategory)
        return stops.getOrNull(index - 1)?.ref() ?: error("Stop $index out of range for ${state.value.selectedCategory}")
    }

    // --- Save copy -------------------------------------------------------------------------------

    /**
     * Exports the COMMITTED state (a transient preview is never exported, spec §5.4 step 1).
     * Returns false if the editor is not ready or an export is already running.
     */
    fun saveCopy(): Boolean {
        val loaded = photo?.takeIf { isCurrent(it.generation) }?.loaded ?: return false
        val session = state.value.session ?: return false
        if (state.value.phase != EditorPhase.Ready) return false
        val job = ExportJob(
            sourceHandle = loaded.source.assetId,
            original = loaded.fullResolution,
            plan = planFor(session.current, compare = false),
            spec = env.newImageSpec(loaded.source),
        )
        return env.exporter.start(job) is ExportStart.Started
    }

    fun cancelSave() = env.exporter.cancel()

    private fun saveStatusOf(exportState: ExportState<*>): SaveStatus = when (exportState) {
        ExportState.Idle -> SaveStatus.Idle
        is ExportState.Running -> SaveStatus.Saving
        is ExportState.Saved<*> -> SaveStatus.Saved(exportState.newAsset.toString())
        is ExportState.Failed -> SaveStatus.Failed(exportState.error.message ?: "Couldn't save")
        is ExportState.Cancelled -> SaveStatus.Cancelled
    }

    // --- Commit, preview, persistence ------------------------------------------------------------

    private inline fun updateSession(change: (EditSession) -> EditSession) {
        val session = state.value.session ?: return
        commit(change(session))
    }

    private fun commit(session: EditSession) {
        savedState[KEY_SESSION] = SessionJson.encodeToString(EditSession.serializer(), session)
        state.update { it.copy(session = session, transientPreview = null, autoStatus = autoStatusFor(session)) }
        requestPreview()
    }

    /** Latest-wins: every call replaces the pending request; at most one render is in flight. */
    private fun requestPreview() {
        val current = state.value
        val displayed = current.displayed ?: return
        val plan = planFor(displayed, current.compareOn)
        scheduler?.submit(plan)
    }

    /** Two LUT passes (spec §4.1): Auto (if available and on), then the Look (if any and known). */
    private fun planFor(editState: EditState, compare: Boolean): LutPassPlan {
        // Compare always shows the Original, not the Auto result (spec §2.6).
        if (compare) return LutPassPlan.of(null, 0f, null, 0f)
        val lookDefinition = editState.look?.let { env.lookBook.find(it) }
        val lookNotice = if (editState.look != null && lookDefinition == null) "Look unavailable; showing Auto." else null
        if (state.value.lookNotice != lookNotice) state.update { it.copy(lookNotice = lookNotice) }
        return LutPassPlan.of(
            autoLut = autoLutForRendering,
            autoStrength = editState.auto.strength,
            lookLut = lookDefinition?.lut,
            lookStrength = editState.look?.strength ?: 0f,
        )
    }

    private fun autoStatusFor(session: EditSession): AutoStatus {
        val auto = session.current.auto
        if (auto.strength == 0f && auto.modelVersion == USE_ORIGINAL_MODEL_VERSION) {
            resolvedAuto = null
            return AutoStatus.UsingOriginal
        }
        val resolution = resolvedAuto?.takeIf { it.first == auto }?.second
            ?: env.autoResolver.resolve(auto).also { resolvedAuto = auto to it }
        return when (resolution) {
            is AutoLutResolution.Ready -> AutoStatus.Applied(auto.modelId, auto.modelVersion)
            is AutoLutResolution.AutoUnavailable -> AutoStatus.Unavailable(resolution.modelId, resolution.modelVersion, resolution.reason)
        }
    }

    companion object {
        const val KEY_ASSET = "editor.asset"
        const val KEY_SESSION = "editor.session.json"
        const val KEY_COMPARE = "editor.compare"
        const val KEY_CATEGORY = "editor.category"

        /** Marks the "Use original" Auto result; never resolved against a basis. */
        const val USE_ORIGINAL_MODEL_VERSION = "use-original"

        fun factory(env: EditorEnvironment): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                EditorViewModel(createSavedStateHandle(), env, CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate))
            }
        }
    }
}
