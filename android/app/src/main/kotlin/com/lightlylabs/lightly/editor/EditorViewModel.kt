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
import com.lightlylabs.lightly.session.SavedEdits
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
import kotlin.math.roundToInt

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
    /**
     * The selected category's opaque pack id (never its label, which may change between packs);
     * `null` only when the build has no Looks.
     */
    val selectedCategory: String? = null,
    val autoStatus: AutoStatus = AutoStatus.NoSession,
    /** Latest preview the scheduler published for the current photo (latest-wins). */
    val preview: Rgba8Image? = null,
    /**
     * Set while the COMMITTED Look is unavailable or changed (spec §4.5): the photo renders without
     * it and the notice stays until the edit no longer holds that Look.
     */
    val lookIssue: LookIssue? = null,
    val save: SaveStatus = SaveStatus.Idle,
) {
    /** What the photo area shows: the transient preview if any, else the committed state. */
    val displayed: EditState? get() = transientPreview ?: session?.current
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

    /** The build has no Auto model ([DevelopResult.NoModelInThisBuild]); wording matches iOS. */
    data object NoModelInThisBuild : AutoStatus {
        const val NOTICE = "Auto is unavailable: this build has no Auto model. Looks apply to your original photo."
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
            selectedCategory = initialCategory(savedState.get<String>(KEY_CATEGORY), env.lookBook),
        ),
    )
    val uiState: StateFlow<EditorUiState> = state.asStateFlow()

    /** The O1 LUT the renderer must use, or `null` meaning "Auto off" (identity). */
    val autoLutForRendering: Lut3D?
        get() = (resolvedAuto?.second as? AutoLutResolution.Ready)?.lut

    /** In pack order; labels are display text only. Empty when the build has no Looks. */
    val categories: List<LookCategory> get() = env.lookBook.categories

    /** Shown beside the Look controls while any Look on offer is not a validated Lightroom render. */
    val lookApproximationNotice: String? get() = LookBook.APPROXIMATE_NOTICE.takeIf { env.lookBook.hasApproximateLooks }

    /** Stop labels 1..n of [categoryId]: each preset's name from the pack, verbatim. */
    fun stopNames(categoryId: String): List<String> = env.lookBook.stops(categoryId).map { it.name }

    /**
     * Name of slider stop 0 (no creative Look). It reads "Auto" only while an Auto correction is
     * actually applied; with no model, an unavailable model, "Use original" or Auto strength 0 the
     * stop shows the untouched photo, and calling it "Auto" would promise an enhancement that is
     * not there.
     */
    val baseStopName: String
        get() {
            val autoApplied = state.value.autoStatus is AutoStatus.Applied && (state.value.displayed?.auto?.strength ?: 0f) > 0f
            return if (autoApplied) AUTO_STOP_NAME else ORIGINAL_STOP_NAME
        }

    /** Every slider stop's label: stop 0, then the category's presets. */
    fun sliderStopNames(categoryId: String): List<String> = listOf(baseStopName) + stopNames(categoryId)

    /** Slider position (0 = no Look) of the displayed Look within the selected category. */
    val stopIndex: Int
        get() = state.value.selectedCategory?.let { env.lookBook.stopIndexOf(it, state.value.displayed?.look) } ?: 0

    /** "Film look Portra at 80 percent", for the photo's accessibility label (spec §6). */
    fun describeLook(look: LookRef): String {
        val definition = env.lookBook.find(look) ?: return "unavailable look"
        val category = env.lookBook.categoryOf(look)?.label
        val percent = (look.strength * 100).roundToInt()
        return listOfNotNull(category, "look", definition.name, "at $percent percent").joinToString(" ")
    }

    init {
        scope.launch { env.exporter.state.collect { exportState -> state.update { it.copy(save = saveStatusOf(exportState)) } } }
        val assetId = savedState.get<String>(KEY_ASSET)
        if (assetId != null) {
            val restored = savedState.get<String>(KEY_SESSION)?.let { json ->
                // A snapshot that no longer decodes (schema change across an update) is dropped
                // rather than crashing; the photo is then developed again.
                // SavedEdits migrates schema 1 entries (spec §4.5) instead of dropping the edit.
                runCatching { SavedEdits.decodeEditSession(json) }.getOrNull()
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
        startWithAutoOff(loaded, USE_ORIGINAL_MODEL_VERSION)
    }

    /**
     * Ready with Auto strength 0. [markerVersion] records why Auto is off in the saved session, so a
     * restore reports the same notice without re-running the model (spec §4.6). It is never resolved
     * against a basis.
     */
    private fun startWithAutoOff(loaded: LoadedPhoto, markerVersion: String) {
        val autoOff = AutoResult(
            modelId = AutoResult.MODEL_ID_IA3DLUT,
            modelVersion = markerVersion,
            weights = listOf(0f, 0f, 0f),
            guardrail = null,
            strength = 0f,
        )
        commit(EditSession.start(loaded.source, autoOff))
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
            // Not a failure: Retry could never succeed, so go straight to editing with Auto off.
            DevelopResult.NoModelInThisBuild -> startWithAutoOff(loaded, NO_MODEL_IN_BUILD_MODEL_VERSION)
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
    fun selectCategory(categoryId: String) {
        if (env.lookBook.category(categoryId) == null) return
        savedState[KEY_CATEGORY] = categoryId
        state.update { it.copy(selectedCategory = categoryId) }
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

    /**
     * "Use current version" on a changed Look: one new, undoable step that keeps the Look and its
     * strength and takes the pack's current version. Does nothing for an unavailable Look.
     */
    fun useCurrentLookVersion() {
        val saved = state.value.session?.current?.look ?: return
        val changed = env.lookBook.resolve(saved) as? LookResolution.Changed ?: return
        updateSession { it.selectLook(saved.copy(lookVersion = changed.current.lookVersion)) }
    }

    /** Strength is secondary and exists only for a committed Look that actually renders. */
    val showsStrength: Boolean
        get() = state.value.session?.current?.look?.let { env.lookBook.resolve(it) is LookResolution.Available } ?: false

    fun undo() = updateSession { it.undo() }

    fun redo() = updateSession { it.redo() }

    fun setCompare(on: Boolean) {
        savedState[KEY_COMPARE] = on
        state.update { it.copy(compareOn = on) }
        requestPreview()
    }

    /**
     * The Look at slider stop [index] (0 = Auto). The slider picks a preset; it is not an intensity
     * control (spec D6), so the committed Look's strength carries over to the new preset unchanged.
     * Strength starts at 100% only when there was no Look before (Auto, or a fresh session).
     */
    private fun lookAtStop(index: Int): LookRef? {
        if (index == 0) return null
        val categoryId = state.value.selectedCategory ?: return null
        val stop = env.lookBook.stops(categoryId).getOrNull(index - 1) ?: error("Stop $index out of range for $categoryId")
        val carriedStrength = state.value.session?.current?.look?.strength ?: 1f
        return stop.ref(carriedStrength)
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
        savedState[KEY_SESSION] = SavedEdits.encodeEditSession(session)
        val lookIssue = LookIssue.of(session.current.look?.let(env.lookBook::resolve))
        state.update { it.copy(session = session, transientPreview = null, autoStatus = autoStatusFor(session), lookIssue = lookIssue) }
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
        // Exact (id, version) only: an unavailable or changed Look is left out, never replaced, so
        // preview and Save copy both show the photo without it (P=E holds for these edits too).
        val lookDefinition = (editState.look?.let(env.lookBook::resolve) as? LookResolution.Available)?.definition
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
        if (auto.strength == 0f && auto.modelVersion == NO_MODEL_IN_BUILD_MODEL_VERSION) {
            resolvedAuto = null
            return AutoStatus.NoModelInThisBuild
        }
        val resolution = resolvedAuto?.takeIf { it.first == auto }?.second
            ?: env.autoResolver.resolve(auto).also { resolvedAuto = auto to it }
        return when (resolution) {
            is AutoLutResolution.Ready -> AutoStatus.Applied(auto.modelId, auto.modelVersion)
            is AutoLutResolution.AutoUnavailable -> AutoStatus.Unavailable(resolution.modelId, resolution.modelVersion, resolution.reason)
        }
    }

    companion object {
        const val AUTO_STOP_NAME = "Auto"
        const val ORIGINAL_STOP_NAME = "Original"

        const val KEY_ASSET = "editor.asset"
        const val KEY_SESSION = "editor.session.json"
        const val KEY_COMPARE = "editor.compare"
        const val KEY_CATEGORY = "editor.category"

        /** Marks the "Use original" Auto result; never resolved against a basis. */
        const val USE_ORIGINAL_MODEL_VERSION = "use-original"

        /**
         * Marks an edit made in a build with no Auto model; never resolved against a basis. A session
         * restored into a later build that has a model keeps Auto off: the edit is replayed as the
         * user made it, not re-developed (spec §4.6).
         */
        const val NO_MODEL_IN_BUILD_MODEL_VERSION = "no-model-in-build"

        /** The saved category if this build's pack still has it, else the pack's first category. */
        internal fun initialCategory(saved: String?, lookBook: LookBook): String? =
            saved?.takeIf { lookBook.category(it) != null } ?: lookBook.categories.firstOrNull()?.id

        fun factory(env: EditorEnvironment): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                EditorViewModel(createSavedStateHandle(), env, CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate))
            }
        }
    }
}
