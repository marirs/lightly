package com.lightlylabs.lightly.editor

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.lightlylabs.lightly.develop.DevelopRenderer
import com.lightlylabs.lightly.develop.LookPreset
import com.lightlylabs.lightly.develop.PixelRect
import com.lightlylabs.lightly.export.ExportJob
import com.lightlylabs.lightly.export.ExportRenderPlan
import com.lightlylabs.lightly.export.ExportStart
import com.lightlylabs.lightly.export.ExportState
import com.lightlylabs.lightly.export.ExportTileRenderer
import com.lightlylabs.lightly.export.SaveCopyFailure
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.schedule.PreviewRenderer
import com.lightlylabs.lightly.render.schedule.RenderOutcome
import com.lightlylabs.lightly.render.schedule.RenderScheduler
import com.lightlylabs.lightly.session.AutoResult
import com.lightlylabs.lightly.session.EditSession
import com.lightlylabs.lightly.session.EditState
import com.lightlylabs.lightly.session.LookRef
import com.lightlylabs.lightly.session.SavedEdits
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** The session's lifecycle (prototype screens loading → editor; recovery states from slice 1). */
sealed interface EditorPhase {
    data object Empty : EditorPhase

    /** Decoding; once the display proxy exists it is shown under the approved "Opening photo…" box. */
    data object Loading : EditorPhase

    /** A real Auto model runs (approved "Developing…"); never shown in this build, which has none (D1). */
    data object Developing : EditorPhase
    data class LoadFailed(val message: String) : EditorPhase

    /** The saved photo can no longer be read; the shell offers to choose it again. */
    data object PhotoAccessLost : EditorPhase
    data object Ready : EditorPhase
}

/** Sheets and dialogs over the editor (prototype `overlayHTML`). */
enum class EditorOverlay { FAVOURITE_REPLACE, SAVING, SAVED, LEAVE, EXPORT_FAILED, STORAGE_FULL }

/** What the preview shows: an exact render of a recipe, the transient drag render, or the original. */
private data class PreviewRequest(val state: EditState?, val globalOnly: Boolean)

data class EditorUiState(
    val phase: EditorPhase = EditorPhase.Empty,
    val session: EditSession? = null,
    val auto: AutoState = AutoState.UNAVAILABLE,
    val tool: EditorTool = EditorTool.DEVELOP,
    val tools: List<EditorTool> = EditorTool.entries.toList(),
    val develop: DevelopUi = DevelopUi(),
    /** Session-scoped Amount per preset id (prototype `s.dev.amount`); the applied one is in the recipe. */
    val rememberedAmounts: Map<String, Int> = emptyMap(),
    val overlay: EditorOverlay? = null,
    val toast: String? = null,
    /** Hold-to-compare finger, and the accessible Compare toggle. Both show the original. */
    val compareHeld: Boolean = false,
    val compareToggled: Boolean = false,
    /** The decoded display proxy (the original) and the latest published render of the edit. */
    val original: Rgba8Image? = null,
    val preview: Rgba8Image? = null,
    /** The saved copy's content URI, for Share in the Saved sheet. */
    val savedAsset: String? = null,
    /** Background tool UI and the photo's subject separation / depth (slice 3). */
    val background: BackgroundUi = BackgroundUi(),
    val separation: SeparationState = SeparationState.NotStarted,
) {
    val showsOriginal: Boolean get() = compareHeld || compareToggled
    val canUndo: Boolean get() = session?.canUndo == true
    val canRedo: Boolean get() = session?.canRedo == true
}

/**
 * One continuous session per photo (slice 2): Loading with the photo visible → automatic Develop →
 * the editor, one EditState schema 3 history with whole-recipe undo/redo, latest-request-wins
 * previews, Save copy of the committed recipe.
 *
 * Every async step carries the photo generation and re-checks it after each suspension point, so
 * nothing from a previous photo can land in the current photo's session (Codex finding 1).
 */
class EditorViewModel(
    private val savedState: SavedStateHandle,
    private val env: EditorEnvironment,
    private val scope: CoroutineScope,
) : ViewModel(scope) {

    private class CurrentPhoto(val generation: Long, val loaded: LoadedPhoto)

    private var photo: CurrentPhoto? = null
    private var scheduler: RenderScheduler<PreviewRequest, Rgba8Image>? = null
    private var schedulerCollector: Job? = null
    private var loadJob: Job? = null
    private var prefetchJob: Job? = null
    private var toastJob: Job? = null
    private var photoGeneration = 0L

    private val backgroundSession = BackgroundSession(env)
    private var separationJob: Job? = null

    /** Notified when Change background › "+" asks for a photo (the Activity launches the picker). */
    var onChooseBackgroundPhoto: () -> Unit = {}

    /** The recipe as last saved (or as first developed): "dirty" means the edit differs from it. */
    private var cleanState: EditState? = null

    private val state = MutableStateFlow(EditorUiState())
    val uiState: StateFlow<EditorUiState> = state.asStateFlow()

    /** Null until the bundled pack has been parsed (off the main thread, at app start). */
    val library: DevelopLibrary?
        @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
        get() = if (env.library.isCompleted && !env.library.isCancelled) runCatching { env.library.getCompleted() }.getOrNull() else null

    val favourites: StateFlow<List<String>> get() = env.favourites.favourites

    /** Notified when the session should leave the editor (Close without changes, Discard edits). */
    var onLeave: () -> Unit = {}

    init {
        scope.launch { env.exporter.state.collect(::onExportState) }
        val assetId = savedState.get<String>(KEY_ASSET)
        if (assetId != null) {
            val restored = savedState.get<String>(KEY_SESSION)?.let { json -> runCatching { SavedEdits.decodeEditSession(json) }.getOrNull() }
                ?.takeIf { it.current.source.assetId == assetId }
            loadPhoto(assetId, restored)
        }
        addCloseable { scheduler?.close() }
    }

    // --- photo lifecycle ------------------------------------------------------------------------

    /**
     * A picked or captured photo. Persists read access to it while the picker's grant is valid, then
     * gives back the previous photo's grant. All work for the previous photo is invalidated.
     */
    fun openPhoto(assetId: String) {
        val previousAsset = savedState.get<String>(KEY_ASSET)
        env.photoAccess.retain(assetId)
        if (previousAsset != null && previousAsset != assetId) env.photoAccess.release(previousAsset)
        savedState[KEY_ASSET] = assetId
        savedState.remove<String>(KEY_SESSION)
        loadPhoto(assetId, restoredSession = null)
    }

    val currentAssetId: String? get() = savedState.get<String>(KEY_ASSET)

    private fun isCurrent(generation: Long) = generation == photoGeneration

    private fun loadPhoto(assetId: String, restoredSession: EditSession?) {
        loadJob?.cancel()
        prefetchJob?.cancel()
        scheduler?.close()
        schedulerCollector?.cancel()
        photo = null
        cleanState = null
        separationJob?.cancel()
        backgroundSession.reset()
        val generation = ++photoGeneration
        state.value = EditorUiState(phase = EditorPhase.Loading)
        loadJob = scope.launch {
            val loaded = try {
                env.photoLoader.load(assetId)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (accessLost: PhotoAccessLostException) {
                if (isCurrent(generation)) enterPhotoAccessLost(assetId)
                return@launch
            } catch (failure: Exception) {
                if (isCurrent(generation)) state.update { it.copy(phase = EditorPhase.LoadFailed(failure.message ?: "Couldn't open this photo")) }
                return@launch
            }
            if (!isCurrent(generation)) return@launch
            photo = CurrentPhoto(generation, loaded)
            // The photo is visible under "Opening photo…" while the pack and Develop finish.
            state.update { it.copy(original = loaded.display) }
            startPreviewScheduler(loaded, generation)
            if (debugHoldLoading) return@launch // capture of the approved loading screen (debug builds only)
            val library = env.library.await()
            if (!isCurrent(generation)) return@launch
            val presence = env.personDetector.detect(loaded.analysis)
            if (!isCurrent(generation)) return@launch
            state.update { it.copy(tools = EditorTools.visible(debugPresence ?: presence, env.debugBuild)) }
            if (restoredSession != null && restoredSession.current.source.fingerprint == loaded.source.fingerprint) {
                // Restore: replay the saved recipe; Auto is not re-run (spec §4.6).
                cleanState = restoredSession.history.entries.first()
                commit(restoredSession, autoStateOf(restoredSession.current.auto))
                state.update { it.copy(phase = EditorPhase.Ready) }
            } else {
                develop(loaded, generation, retry = false)
            }
        }
    }

    private fun enterPhotoAccessLost(lostAsset: String) {
        savedState.remove<String>(KEY_ASSET)
        savedState.remove<String>(KEY_SESSION)
        env.photoAccess.release(lostAsset)
        state.value = EditorUiState(phase = EditorPhase.PhotoAccessLost)
    }

    /** Automatic Develop. Without a model the photo opens unchanged with the approved "isn't available" notice. */
    private suspend fun develop(loaded: LoadedPhoto, generation: Long, retry: Boolean) {
        if (!isCurrent(generation)) return
        val result = env.autoDeveloper.develop(loaded.source.fingerprint, loaded.analysis)
        if (!isCurrent(generation)) return
        val (auto, autoState) = when (result) {
            // DEFERRED(D1): no model ships, so no Auto LUT can be resolved and a "Developed" result
            // cannot render. It would be shown as unavailable rather than presented as Auto.
            is DevelopResult.Developed -> noModelAuto() to AutoState.UNAVAILABLE
            is DevelopResult.Failed -> autoOff(DEVELOP_FAILED_MODEL_VERSION) to AutoState.FAILED
            DevelopResult.NoModelInThisBuild -> noModelAuto() to AutoState.UNAVAILABLE
        }
        val existing = state.value.session
        if (retry && existing != null) {
            commit(existing.commit { it.copy(auto = auto) }, autoState)
        } else {
            val session = EditSession.start(loaded.source, auto)
            cleanState = session.current
            commit(session, autoState)
        }
        state.update { it.copy(phase = EditorPhase.Ready) }
    }

    private fun noModelAuto() = autoOff(NO_MODEL_IN_BUILD_MODEL_VERSION)

    private fun autoOff(markerVersion: String) =
        AutoResult(modelId = AutoResult.MODEL_ID_IA3DLUT, modelVersion = markerVersion, weights = listOf(0f, 0f, 0f), guardrail = null, strength = 0f)

    private fun autoStateOf(auto: AutoResult): AutoState = when {
        auto.modelVersion == NO_MODEL_IN_BUILD_MODEL_VERSION -> AutoState.UNAVAILABLE
        auto.modelVersion == DEVELOP_FAILED_MODEL_VERSION -> AutoState.FAILED
        auto.strength == 0f -> AutoState.OFF
        else -> AutoState.UNAVAILABLE // a stored Auto from another build cannot render here (D1)
    }

    /** Approved failure state › Retry: one user-initiated run. */
    fun retryAuto() {
        val current = photo?.takeIf { isCurrent(it.generation) } ?: return
        if (state.value.auto != AutoState.FAILED) return
        state.update { it.copy(phase = EditorPhase.Developing) }
        loadJob = scope.launch { develop(current.loaded, current.generation, retry = true) }
    }

    /** Approved failure state › Continue with original: Auto is off, presets still work. One undo step. */
    fun continueWithOriginal() {
        if (state.value.auto != AutoState.FAILED) return
        val session = state.value.session ?: return
        commit(session.commit { it.copy(auto = autoOff(USE_ORIGINAL_MODEL_VERSION)) }, AutoState.OFF)
    }

    /** The Auto switch toggles only a real, applied correction; unavailable or failed Auto does nothing. */
    fun toggleAuto() {
        // DEFERRED(D1): with no model the switch is always in its unavailable state.
    }

    // --- tools ----------------------------------------------------------------------------------

    fun selectTool(tool: EditorTool) {
        if (tool !in state.value.tools) return
        if (!EditorTools.isImplemented(tool) && !env.debugBuild) return // release: unimplemented tools stay put
        state.update { it.copy(tool = tool, develop = DevelopUi(), background = BackgroundUi()) }
        if (tool == EditorTool.BACKGROUND && state.value.separation == SeparationState.NotStarted) startSeparation()
    }

    // --- Background (slice 3) -------------------------------------------------------------------

    /** Depth and subject separation, once per photo, behind the approved cancellable "Finding the subject…". */
    private fun startSeparation() {
        val current = photo?.takeIf { isCurrent(it.generation) } ?: return
        separationJob?.cancel()
        state.update { it.copy(separation = SeparationState.Separating) }
        separationJob = scope.launch(env.prefetchDispatcher) {
            val finished = backgroundSession.analyse(current.loaded)
            if (!isCurrent(current.generation)) return@launch
            state.update { it.copy(separation = finished) }
            state.value.session?.let { requestPreview(it.current, globalOnly = false) }
        }
    }

    fun cancelSeparation() {
        separationJob?.cancel()
        state.update { it.copy(separation = SeparationState.NotStarted) }
        showToast(OPERATION_CANCELLED)
    }

    fun retrySeparation() = startSeparation()

    fun selectBackgroundSub(sub: BackgroundSub) {
        state.update { it.copy(background = it.background.copy(sub = sub, sliderDrag = null)) }
        if (state.value.separation == SeparationState.NotStarted) startSeparation()
    }

    fun selectReplacementKind(kind: ReplacementKind) = state.update { it.copy(background = it.background.copy(kind = kind)) }

    fun setBrushMode(mode: BrushMode) = state.update { it.copy(background = it.background.copy(brush = mode)) }

    fun setBrushSize(size: Int) = state.update { it.copy(background = it.background.copy(brushSize = size.coerceIn(0, 100))) }

    private fun commitBackground(change: (com.lightlylabs.lightly.session.BackgroundTool) -> com.lightlylabs.lightly.session.BackgroundTool) {
        val session = state.value.session ?: return
        commit(session.commit { s -> s.copy(tools = s.tools.copy(background = backgroundSession.withDerivedRefs(change(s.tools.background)))) }, state.value.auto)
    }

    private fun withSlider(tool: com.lightlylabs.lightly.session.BackgroundTool, field: String, value: Double) = when (field) {
        "blur" -> tool.copy(focus = tool.focus.copy(blur = value.coerceIn(0.0, 100.0)))
        "depthOfField" -> tool.copy(focus = tool.focus.copy(depthOfField = value.coerceIn(0.0, 100.0)))
        "styleAmount" -> tool.copy(focus = tool.focus.copy(styleAmount = value.coerceIn(0.0, 100.0)))
        "scale" -> tool.copy(replacement = (tool.replacement as? com.lightlylabs.lightly.session.Replacement.Image)?.copy(scale = value.coerceIn(100.0, 200.0)) ?: tool.replacement)
        else -> tool
    }

    /** A Background slider moving: transient preview only. */
    fun onBackgroundSlider(field: String, value: Double) {
        val session = state.value.session ?: return
        state.update { it.copy(background = it.background.copy(sliderDrag = field to value)) }
        val edited = session.current.copy(tools = session.current.tools.copy(background = withSlider(session.current.tools.background, field, value)))
        requestPreview(edited, globalOnly = true)
    }

    /** Slider release: one undo step. */
    fun onBackgroundSliderRelease(field: String, value: Double) {
        state.update { it.copy(background = it.background.copy(sliderDrag = null)) }
        commitBackground { withSlider(it, field, value) }
    }

    fun setFocusStyle(style: com.lightlylabs.lightly.session.FocusStyle) = commitBackground { it.copy(focus = it.focus.copy(style = style)) }

    fun setBokeh(bokeh: com.lightlylabs.lightly.session.Bokeh) = commitBackground { it.copy(focus = it.focus.copy(bokeh = bokeh)) }

    /** Tap on the photo in Focus & Blur: the target and the depth under it, resolved now and stored (one step). */
    fun setFocusTarget(x: Double, y: Double) {
        val nearness = backgroundSession.focalNearnessAt(x, y) ?: return
        commitBackground {
            it.copy(focus = it.focus.copy(target = com.lightlylabs.lightly.session.NormalisedPoint(x.coerceIn(0.0, 1.0), y.coerceIn(0.0, 1.0)),
                depth = it.focus.depth.copy(focusDepth = (1.0 - nearness).coerceIn(0.0, 1.0))))
        }
    }

    /** Where the focus ring is drawn: the stored target, else the default (subject centroid or centre). */
    val focusTarget: Pair<Double, Double>
        get() = state.value.session?.current?.tools?.background?.focus?.target?.let { it.x to it.y } ?: backgroundSession.defaultTarget()

    fun chooseBackgroundColour(hex: String) = commitBackground { it.copy(replacement = com.lightlylabs.lightly.session.Replacement.Colour(hex)) }

    fun chooseBackgroundGradient(index: Int) {
        val (angle, stops) = BackgroundOptions.GRADIENTS[index]
        commitBackground {
            it.copy(replacement = com.lightlylabs.lightly.session.Replacement.Gradient(angle, listOf(
                com.lightlylabs.lightly.session.GradientStop(stops[0], 0.0), com.lightlylabs.lightly.session.GradientStop(stops[1], 1.0))))
        }
    }

    fun chooseBackgroundImage(id: String) = commitBackground {
        val previous = it.replacement as? com.lightlylabs.lightly.session.Replacement.Image
        it.copy(replacement = com.lightlylabs.lightly.session.Replacement.Image(com.lightlylabs.lightly.session.AssetRef.Bundled(id), previous?.x ?: 50.0, previous?.y ?: 50.0, previous?.scale ?: 100.0))
    }

    fun chooseBackgroundPhoto() = onChooseBackgroundPhoto()

    /** The photo picked for Change background › "+": decoded once, referenced by its fingerprint. */
    fun useBackgroundPhoto(assetId: String) {
        val current = photo?.takeIf { isCurrent(it.generation) } ?: return
        scope.launch {
            val picked = runCatching { env.photoLoader.load(assetId) }.getOrNull() ?: return@launch
            if (!isCurrent(current.generation)) return@launch
            val asset = com.lightlylabs.lightly.session.AssetRef.Photo(assetId, picked.source.fingerprint)
            backgroundSession.rememberReplacementPhoto(asset, picked.display)
            env.photoAccess.retain(assetId)
            commitBackground { it.copy(replacement = com.lightlylabs.lightly.session.Replacement.Image(asset, 50.0, 50.0, 100.0)) }
        }
    }

    fun removeBackgroundChange() = commitBackground { it.copy(replacement = null) }

    /**
     * Refine edges: one brushed stroke (normalised photo points), one undo step. The radius follows the
     * Brush size control (0–100 → up to 5 % of the long edge).
     */
    fun addRefineStroke(points: List<Pair<Double, Double>>) {
        if (points.isEmpty() || state.value.background.sub != BackgroundSub.REFINE) return
        val radius = (state.value.background.brushSize / 100.0 * 0.05).coerceIn(0.002, 0.5)
        val mode = if (state.value.background.brush == BrushMode.ADD) com.lightlylabs.lightly.session.RefineMode.ADD else com.lightlylabs.lightly.session.RefineMode.ERASE
        val stroke = com.lightlylabs.lightly.session.RefineStroke(mode, radius, points.map { (x, y) -> com.lightlylabs.lightly.session.NormalisedPoint(x.coerceIn(0.0, 1.0), y.coerceIn(0.0, 1.0)) })
        commitBackground { it.copy(subject = it.subject.copy(refinements = it.subject.refinements + stroke)) }
    }

    /** The refined matte at the analysis size, for the Refine edges tint (null without a matte). */
    fun refinedMatte(): com.lightlylabs.lightly.background.FloatPlane? =
        state.value.session?.current?.tools?.background?.let { backgroundSession.refined(it)?.matte }

    // --- Develop --------------------------------------------------------------------------------

    fun panelModel(ui: EditorUiState = state.value, favourites: List<String> = this.favourites.value): DevelopPanelModel? {
        val library = library ?: return null
        val session = ui.session ?: return null
        return DevelopPanelModel.derive(library.pack, session.current.look, ui.auto, favourites, ui.develop, ui.rememberedAmounts)
    }

    /** Browsing another category never changes the applied Look (not an undo step). */
    fun selectCategory(categoryId: String) {
        state.update { it.copy(develop = it.develop.copy(category = categoryId, dragStop = null, amountOpen = false)) }
    }

    /** The needle crossed [stop] while dragging: preview only (the drag render is develop.global). */
    fun onRulerDrag(stop: Int) {
        val model = panelModel() ?: return
        val clamped = stop.coerceIn(0, model.presets.size)
        if (state.value.develop.dragStop == clamped) return
        state.update { it.copy(develop = it.develop.copy(dragStop = clamped)) }
        val session = state.value.session ?: return
        requestPreview(session.current.copy(look = lookAt(model, clamped)), globalOnly = true)
        prefetchAround(model, clamped)
    }

    fun onRulerFine(fine: Boolean) {
        if (state.value.develop.fine != fine) state.update { it.copy(develop = it.develop.copy(fine = fine)) }
    }

    /** Release: ONE undo step, and only when the Look actually changes. No interpolation between stops. */
    fun onRulerRelease(stop: Int) {
        val model = panelModel()
        state.update { it.copy(develop = it.develop.copy(dragStop = null, fine = false)) }
        val session = state.value.session ?: return
        if (model == null) return
        val look = lookAt(model, stop.coerceIn(0, model.presets.size))
        if (look?.lookId == session.current.look?.lookId) {
            requestPreview(session.current, globalOnly = false)
            return
        }
        commit(session.selectLook(look), state.value.auto)
    }

    /**
     * The Look at [stop] of the browsed list. Re-selecting the applied preset keeps its Amount; any
     * other preset takes the Amount last set for it in this session (prototype `s.dev.amount`), else 100.
     */
    private fun lookAt(model: DevelopPanelModel, stop: Int): LookRef? {
        if (stop == 0) return null
        val preset = model.presets[stop - 1]
        val applied = state.value.session?.current?.look
        if (applied != null && applied.lookId == preset.id && applied.lookVersion == preset.lookVersion) return applied
        val amount = state.value.rememberedAmounts[preset.id] ?: 100
        return LookRef(preset.id, preset.lookVersion, amount / 100f)
    }

    /** Bakes the neighbouring stops ahead of the needle, on the prefetch thread, latest drag wins. */
    private fun prefetchAround(model: DevelopPanelModel, stop: Int) {
        val library = library ?: return
        val neighbours = listOf(stop + 1, stop - 1, stop + 2, stop - 2).filter { it in 1..model.presets.size }.map { model.presets[it - 1] }
        prefetchJob?.cancel()
        prefetchJob = scope.launch(env.prefetchDispatcher) {
            for (preset in neighbours) {
                if (!library.isCached(preset, DevelopLibrary.DRAG_DIMENSION)) library.lutFor(preset, DevelopLibrary.DRAG_DIMENSION)
            }
        }
    }

    fun toggleStar() {
        val library = library ?: return
        val applied = library.preset(state.value.session?.current?.look) ?: return
        val favourites = favourites.value
        when {
            applied.id in favourites -> env.favourites.update { it - applied.id }
            favourites.size >= DevelopPanelModel.MAX_FAVOURITES -> state.update { it.copy(develop = it.develop.copy(favouritesFull = true)) }
            else -> env.favourites.update { it + applied.id }
        }
    }

    fun openFavouriteReplace() = state.update { it.copy(overlay = EditorOverlay.FAVOURITE_REPLACE) }

    fun replaceFavourite(replacedId: String) {
        val applied = library?.preset(state.value.session?.current?.look) ?: return
        env.favourites.update { list -> list.map { if (it == replacedId) applied.id else it } }
        state.update { it.copy(overlay = null, develop = it.develop.copy(favouritesFull = false)) }
    }

    /** "Not now", Cancel, Keep editing: closes the overlay and the favourites notice. */
    fun dismiss() {
        state.update { it.copy(overlay = null, develop = it.develop.copy(favouritesFull = false)) }
    }

    fun openAmount() = state.update { it.copy(develop = it.develop.copy(amountOpen = true)) }

    fun amountDone() = state.update { it.copy(develop = it.develop.copy(amountOpen = false, amountDrag = null)) }

    fun onAmountDrag(amount: Int) {
        val session = state.value.session ?: return
        val look = session.current.look ?: return
        val value = amount.coerceIn(0, 100)
        state.update { it.copy(develop = it.develop.copy(amountDrag = value)) }
        requestPreview(session.current.copy(look = look.copy(strength = value / 100f)), globalOnly = true)
    }

    /** Slider release: one undo step. */
    fun onAmountRelease(amount: Int) {
        val session = state.value.session ?: return
        val look = session.current.look ?: return
        val value = amount.coerceIn(0, 100)
        state.update { it.copy(develop = it.develop.copy(amountDrag = null), rememberedAmounts = it.rememberedAmounts + (look.lookId to value)) }
        commit(session.setLookStrength(value / 100f), state.value.auto)
    }

    // --- history and compare --------------------------------------------------------------------

    /** Undo and Redo restore the whole recipe (every tool, and Auto), and drop any transient Develop UI. */
    fun undo() {
        val session = state.value.session?.takeIf { it.canUndo }?.undo() ?: return
        state.update { it.copy(develop = it.develop.copy(dragStop = null, amountDrag = null)) }
        commit(session, autoStateOf(session.current.auto))
    }

    fun redo() {
        val session = state.value.session?.takeIf { it.canRedo }?.redo() ?: return
        state.update { it.copy(develop = it.develop.copy(dragStop = null, amountDrag = null)) }
        commit(session, autoStateOf(session.current.auto))
    }

    fun holdCompare(held: Boolean) {
        if (state.value.compareHeld != held) state.update { it.copy(compareHeld = held) }
    }

    /** The accessible Compare toggle (TalkBack double-tap): shows the original until toggled again. */
    fun toggleCompare() = state.update { it.copy(compareToggled = !it.compareToggled) }

    // --- save copy and leaving ------------------------------------------------------------------

    val isDirty: Boolean
        get() {
            val current = state.value.session?.current ?: return false
            val clean = cleanState ?: return true
            return current.copy(revision = 0) != clean.copy(revision = 0)
        }

    /** Save copy: a full-resolution JPEG of the SAME committed recipe the preview shows. */
    fun saveCopy() {
        val loaded = photo?.takeIf { isCurrent(it.generation) }?.loaded ?: return
        val session = state.value.session ?: return
        val library = library ?: return
        if (state.value.phase != EditorPhase.Ready) return
        val committed = session.current
        val plan = library.planFor(committed)
        val backgroundPlan = backgroundSession.planFor(committed.tools.background, plan, env.previewRenderer)
        val exportPlan = ExportRenderPlan { frame ->
            // One renderer and clarity base per frame; tiles read their apron from the full frame.
            val renderer = DevelopRenderer(exportPool, EXPORT_PARALLELISM)
            val base = renderer.clarityBase(frame, plan)
            // Background renders once at the analysis size (K = 8), then each full-resolution tile keeps its
            // in-focus pixels and takes the defocused or replaced ones from that render (BackgroundStage.composeTile).
            val background = backgroundPlan?.let { bp ->
                val analysis = backgroundSession.analysis!!
                val small = BackgroundSession.resize(frame, analysis.width, analysis.height)
                backgroundSession.render(renderer.render(small, plan), bp, com.lightlylabs.lightly.background.Refocus.FocusConstants.LAYERS_PER_SIDE_EXPORT, committed.tools.background)
            }
            ExportTileRenderer { source, tile ->
                val developed = renderer.renderTile(source, PixelRect(tile.x, tile.y, tile.width, tile.height), plan, base)
                if (background == null) developed else Rgba8Image(tile.width, tile.height,
                    com.lightlylabs.lightly.background.BackgroundStage.composeTile(developed.pixels, tile.x, tile.y, tile.width, tile.height, frame.width, frame.height, background.first.pixels, background.second))
            }
        }
        val job = ExportJob(sourceHandle = loaded.source.assetId, original = loaded.fullResolution, plan = exportPlan, spec = env.newImageSpec(loaded.source))
        if (env.exporter.start(job) is ExportStart.Started) {
            savingRecipe = committed
            state.update { it.copy(overlay = EditorOverlay.SAVING) }
        }
    }

    private var savingRecipe: EditState? = null
    private var userCancelledSave = false

    fun cancelSave() {
        userCancelledSave = true
        env.exporter.cancel()
    }

    private fun onExportState(export: ExportState<*>) {
        when (export) {
            is ExportState.Saved<*> -> {
                cleanState = savingRecipe ?: cleanState
                state.update { it.copy(overlay = EditorOverlay.SAVED, savedAsset = export.newAsset.toString()) }
            }
            is ExportState.Failed -> {
                val overlay = if (export.error is SaveCopyFailure.OutOfStorage) EditorOverlay.STORAGE_FULL else EditorOverlay.EXPORT_FAILED
                state.update { it.copy(overlay = overlay) }
            }
            is ExportState.Cancelled -> {
                if (userCancelledSave) showToast(SAVE_CANCELLED)
                userCancelledSave = false
                state.update { if (it.overlay == EditorOverlay.SAVING) it.copy(overlay = null) else it }
            }
            else -> Unit
        }
    }

    /**
     * Close (Android back arrow) and system Back: with unsaved changes the approved "Leave without
     * saving?" dialog asks first; otherwise the editor is left at once.
     */
    fun close() {
        when {
            state.value.overlay != null && state.value.overlay != EditorOverlay.SAVING -> dismiss()
            isDirty -> state.update { it.copy(overlay = EditorOverlay.LEAVE) }
            else -> onLeave()
        }
    }

    fun discardAndLeave() {
        state.update { it.copy(overlay = null) }
        onLeave()
    }

    private fun showToast(text: String) {
        toastJob?.cancel()
        state.update { it.copy(toast = text) }
        toastJob = scope.launch {
            delay(TOAST_MILLIS)
            state.update { if (it.toast == text) it.copy(toast = null) else it }
        }
    }

    // --- commit and preview ---------------------------------------------------------------------

    private fun commit(session: EditSession, auto: AutoState) {
        savedState[KEY_SESSION] = SavedEdits.encodeEditSession(session)
        state.update { it.copy(session = session, auto = auto) }
        requestPreview(session.current, globalOnly = false)
    }

    private fun startPreviewScheduler(loaded: LoadedPhoto, generation: Long) {
        val display = loaded.display
        // The drag preview renders a half-size copy (a quarter of the pixels); committed previews use the full proxy.
        val dragProxy = DevelopRenderer.halfSize(display)
        val newScheduler = RenderScheduler(
            sessionId = "photo-$generation",
            renderer = PreviewRenderer<PreviewRequest, Rgba8Image> { request ->
                val library = env.library.await()
                val edit = request.payload.state ?: return@PreviewRenderer display
                val start = System.nanoTime()
                val plan = library.planFor(edit, request.payload.globalOnly)
                val backgroundPlan = backgroundSession.planFor(edit.tools.background, library.planFor(edit), env.previewRenderer)
                // With Background active the drag preview keeps the full proxy: the stage works at the analysis size.
                val source = if (request.payload.globalOnly && backgroundPlan == null) dragProxy else display
                val developed = if (plan.isIdentity) source else env.previewRenderer.render(source, plan)
                val image = if (backgroundPlan == null) developed else backgroundSession.render(developed, backgroundPlan, com.lightlylabs.lightly.background.Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW, edit.tools.background).first
                val millis = (System.nanoTime() - start) / 1e6
                renderMillis += millis
                env.onPreviewRendered(millis, request.payload.globalOnly)
                image
            },
            parentScope = scope,
            renderDispatcher = env.renderDispatcher,
        )
        scheduler = newScheduler
        schedulerCollector = scope.launch {
            newScheduler.published.collect { result ->
                val rendered = (result?.outcome as? RenderOutcome.Rendered)?.value ?: return@collect
                if (result.sessionId == "photo-$photoGeneration") {
                    state.update { it.copy(preview = rendered) }
                    publishedRevision = result.revision
                }
            }
        }
    }

    /** Latest-wins: every call replaces the pending request; at most one render is in flight. */
    private fun requestPreview(edit: EditState, globalOnly: Boolean) {
        requestedRevision = scheduler?.submit(PreviewRequest(edit, globalOnly)) ?: requestedRevision
    }

    // Debug benchmark bookkeeping (docs/v1/slice2-android.md › Performance).
    @Volatile internal var publishedRevision: Long = -1
    @Volatile internal var requestedRevision: Long = -1
    internal val renderMillis: MutableList<Double> = java.util.Collections.synchronizedList(mutableListOf())

    // --- debug launch state (debug builds only; see DebugLaunchOptions) --------------------------

    /** Capture-only override of person detection, so a capture can mirror the reference photo. */
    internal var debugPresence: PersonPresence? = null

    /** Capture-only: stop after decoding, so the approved "Opening photo…" screen can be captured. */
    internal var debugHoldLoading: Boolean = false

    /** Capture-only: sets the phase (the loading capture shows "Developing…", which no model triggers here). */
    internal fun debugSetPhase(phase: EditorPhase) = state.update { it.copy(phase = phase) }

    /**
     * Applies a capture state once the session is Ready. Debug builds only: release builds never call
     * it (DebugLaunchOptions is gated on BuildConfig.DEBUG).
     */
    internal fun applyDebugState(apply: (DebugEditorApi) -> Unit) {
        scope.launch {
            while (state.value.phase != EditorPhase.Ready && state.value.phase !is EditorPhase.LoadFailed) delay(50)
            if (state.value.phase == EditorPhase.Ready) apply(DebugEditorApi())
        }
    }

    /**
     * Debug benchmark (docs/v1/slice2-android.md › Performance): cold 33³ bakes of 40 presets, a scrub
     * through 20 consecutive stops at 20 stops per second, and committed full-recipe preview renders.
     */
    internal fun debugBenchmark(log: (String) -> Unit) {
        scope.launch {
            while (state.value.phase != EditorPhase.Ready) delay(50)
            val library = library ?: return@launch
            fun summary(values: List<Double>): String {
                val sorted = values.sorted()
                return "n=${sorted.size} median=${"%.1f".format(sorted[sorted.size / 2])} p95=${"%.1f".format(sorted[(sorted.size * 95 / 100).coerceAtMost(sorted.size - 1)])} max=${"%.1f".format(sorted.last())} ms"
            }
            val presets = library.pack.category("film")!!.presets.take(40)
            val bakes = kotlinx.coroutines.withContext(env.renderDispatcher) {
                presets.map { preset ->
                    val start = System.nanoTime()
                    com.lightlylabs.lightly.develop.LutBaker.bake(com.lightlylabs.lightly.develop.DevelopGlobal(preset.recipe.global, library.model), executor = workerPoolForBenchmark(), parallelism = 4)
                    (System.nanoTime() - start) / 1e6
                }
            }
            log("bake 33³ (cold, 40 Film presets): ${summary(bakes)}")
            renderMillis.clear()
            val waits = DebugEditorApi().scrub("street", 1, 20, 50)
            log("scrub 20 stops at 50 ms/stop: stale-preview wait ${summary(waits)}")
            log("drag (global-only) preview renders: ${summary(renderMillis.toList())}")
            delay(1500)
            renderMillis.clear()
            val committed = mutableListOf<Double>()
            for (stop in listOf(10, 20, 30, 40, 50)) {
                val start = System.nanoTime()
                onRulerDrag(stop); onRulerRelease(stop)
                val revision = requestedRevision
                while (publishedRevision < revision) delay(5)
                committed += (System.nanoTime() - start) / 1e6
            }
            log("committed full-recipe preview (bake + spatial + finishing, ${state.value.original?.width}x${state.value.original?.height}): ${summary(committed)}")
            log("manifest parse + index: ${"%.0f".format(AndroidEditorEnvironment.manifestParseMillis)} ms")
        }
    }

    private fun workerPoolForBenchmark() = benchmarkPool

    /** The handful of state changes the capture script needs, applied as the user would (commits included). */
    inner class DebugEditorApi {
        val library: DevelopLibrary? get() = this@EditorViewModel.library

        fun setAuto(auto: AutoState) = state.update { it.copy(auto = auto) }

        fun applyPreset(categoryId: String, stop: Int, amount: Int = 100) {
            val preset: LookPreset = library?.pack?.category(categoryId)?.presets?.getOrNull(stop - 1) ?: return
            val session = state.value.session ?: return
            commit(session.selectLook(LookRef(preset.id, preset.lookVersion, amount / 100f)), state.value.auto)
        }

        fun setUi(change: (EditorUiState) -> EditorUiState) = state.update(change)

        /**
         * Makes the configured recipe the start of history, as the prototype's directly opened screens
         * are (their Undo is disabled). Captures only; the recipe itself is unchanged.
         */
        fun rebaseHistory(keepUnsaved: Boolean = false) {
            val session = state.value.session ?: return
            val rebased = EditSession(com.lightlylabs.lightly.session.UndoStack.startingAt(session.current), session.lastIssuedRevision)
            if (!keepUnsaved) cleanState = rebased.current
            commit(rebased, state.value.auto)
        }

        fun preview(globalOnly: Boolean, look: LookRef?) {
            val session = state.value.session ?: return
            requestPreview(session.current.copy(look = look), globalOnly)
        }

        /**
         * Scrubs [count] consecutive stops at one per [intervalMillis] and reports, per stop, how long the
         * screen showed an older stop (time until a preview at least as new was published).
         */
        suspend fun scrub(categoryId: String, firstStop: Int, count: Int, intervalMillis: Long): List<Double> {
            selectCategory(categoryId)
            val waits = mutableListOf<Double>()
            for (i in 0 until count) {
                val start = System.nanoTime()
                onRulerDrag(firstStop + i)
                val revision = requestedRevision
                while (publishedRevision < revision) delay(2)
                waits += (System.nanoTime() - start) / 1e6
                val elapsed = (System.nanoTime() - start) / 1_000_000
                if (elapsed < intervalMillis) delay(intervalMillis - elapsed)
            }
            onRulerRelease(firstStop + count - 1)
            return waits
        }
    }

    companion object {
        const val KEY_ASSET = "editor.asset"
        const val KEY_SESSION = "editor.session.json"
        const val SAVE_CANCELLED = "Save cancelled · nothing was written"

        /** Prototype `cancelOp` toast. */
        const val OPERATION_CANCELLED = "Cancelled · nothing changed"
        private const val TOAST_MILLIS = 1400L

        /** Marks "Continue with original" in the saved recipe; never resolved against a model. */
        const val USE_ORIGINAL_MODEL_VERSION = "use-original"

        /** Marks an edit made in a build with no Auto model (edit-recipe neutral fixture). */
        const val NO_MODEL_IN_BUILD_MODEL_VERSION = "no-model-in-build"

        /** Marks the approved "didn't finish" state, so Undo after "Continue with original" returns to it. */
        const val DEVELOP_FAILED_MODEL_VERSION = "develop-failed"

        private val benchmarkPool = java.util.concurrent.Executors.newFixedThreadPool(4)
        private const val EXPORT_PARALLELISM = 4
        private val exportPool = java.util.concurrent.Executors.newFixedThreadPool(EXPORT_PARALLELISM) { runnable ->
            Thread(runnable, "lightly-export-worker").apply { isDaemon = true }
        }

        fun factory(env: EditorEnvironment): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                EditorViewModel(createSavedStateHandle(), env, CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate))
            }
        }
    }
}
