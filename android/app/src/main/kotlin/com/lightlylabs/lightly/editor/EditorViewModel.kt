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
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
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
    /** Edit and Effects tool UI (slice 4). */
    val edit: EditUi = EditUi(),
    val effects: EffectsUi = EffectsUi(),
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

    /** Edit › Remove: the session's patches, the running removal, and the model (loaded on first stroke). */
    private val removePatches = RemovePatchStore()
    private var removeJob: Job? = null
    private val inpainter: Inpainter? by lazy { env.inpainter() }

    /** The display proxy with the applied Remove patches composited, keyed by their digests. */
    @Volatile private var patchedDisplay: Pair<List<String>, Rgba8Image>? = null

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
        removeJob?.cancel()
        removePatches.clear()
        patchedDisplay = null
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
        // Prototype `tool`: sub, op and group reset; a removal already running keeps running.
        state.update { it.copy(tool = tool, develop = DevelopUi(), background = BackgroundUi(), edit = EditUi(removeOp = it.edit.removeOp, pendingStroke = it.edit.pendingStroke), effects = EffectsUi()) }
        if (tool == EditorTool.BACKGROUND && state.value.separation == SeparationState.NotStarted) startSeparation()
    }

    // --- Background (slice 3) -------------------------------------------------------------------

    /** Depth and subject separation, once per photo, behind the approved cancellable "Finding the subject…". */
    private fun startSeparation() {
        val current = photo?.takeIf { isCurrent(it.generation) } ?: return
        separationJob?.cancel()
        state.update { it.copy(separation = SeparationState.Separating) }
        separationJob = scope.launch(env.prefetchDispatcher) {
            // Capture of the approved "Finding the subject…" state (debug builds only): stays separating.
            if (debugHoldSeparation) return@launch
            val finished = backgroundSession.analyse(current.loaded)
            // The analysis is long CPU work with no suspension point: if the editor was cleared
            // meanwhile (left, or recreated), its preview scheduler is closed; stop here.
            ensureActive()
            if (!isCurrent(current.generation)) return@launch
            state.update { it.copy(separation = finished) }
            state.value.session?.let { requestPreview(it.current, globalOnly = false) }
            // Debug captures only: commits that need the finished analysis, inside this job so capture
            // readiness (no separation in flight) covers them.
            debugAfterSeparation?.let { action -> debugAfterSeparation = null; action() }
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
        // Derived references (the depth source and map) go in before the change too: a first blur commit
        // must not build a Focus with blur > 0 and source subject-matte, which the recipe rejects.
        commit(session.commit { s -> s.copy(tools = s.tools.copy(background = backgroundSession.withDerivedRefs(change(backgroundSession.withDerivedRefs(s.tools.background))))) }, state.value.auto)
    }

    private fun withSlider(tool: com.lightlylabs.lightly.session.BackgroundTool, field: String, value: Double) = when (field) {
        // No depth: blur stays 0 (the panel shows the approved failure state; §R8, contract fixes 1 G3).
        "blur" -> if (tool.focus.depth.source == com.lightlylabs.lightly.session.DepthSource.SUBJECT_MATTE) tool
            else tool.copy(focus = tool.focus.copy(blur = value.coerceIn(0.0, 100.0)))
        "depthOfField" -> tool.copy(focus = tool.focus.copy(depthOfField = value.coerceIn(0.0, 100.0)))
        "styleAmount" -> tool.copy(focus = tool.focus.copy(styleAmount = value.coerceIn(0.0, 100.0)))
        "scale" -> tool.copy(replacement = (tool.replacement as? com.lightlylabs.lightly.session.Replacement.Image)?.copy(scale = value.coerceIn(100.0, 200.0)) ?: tool.replacement)
        else -> tool
    }

    /** A Background slider moving: transient preview only. */
    fun onBackgroundSlider(field: String, value: Double) {
        val session = state.value.session ?: return
        state.update { it.copy(background = it.background.copy(sliderDrag = field to value)) }
        val edited = session.current.copy(tools = session.current.tools.copy(background = withSlider(backgroundSession.withDerivedRefs(session.current.tools.background), field, value)))
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

    // --- Edit (slice 4) ---------------------------------------------------------------------------

    fun selectEditSub(sub: EditSub) = state.update { it.copy(edit = it.edit.copy(sub = sub, sliderDrag = null)) }

    fun selectAdjustGroup(group: AdjustGroup) = state.update { it.copy(edit = it.edit.copy(group = group)) }

    fun setRemoveBrushSize(size: Int) = state.update { it.copy(edit = it.edit.copy(brushSize = size.coerceIn(0, 100))) }

    private fun commitEdit(change: (com.lightlylabs.lightly.session.EditTool) -> com.lightlylabs.lightly.session.EditTool) {
        val session = state.value.session ?: return
        commit(session.commit { s -> s.copy(tools = s.tools.copy(edit = change(s.tools.edit))) }, state.value.auto)
    }

    /** The source's turned size at the display proxy's resolution (crop rects are fractions of it). */
    private fun turnedDisplaySize(quarterTurns: Int): Pair<Int, Int> {
        val display = state.value.original ?: return 1 to 1
        return com.lightlylabs.lightly.develop.GeometryTransform.turnedSize(quarterTurns, display.width, display.height)
    }

    private fun centredCrop(aspect: com.lightlylabs.lightly.session.CropAspect, geometry: com.lightlylabs.lightly.session.Geometry): com.lightlylabs.lightly.session.NormalisedRect {
        val ratio = EditOptions.ratio(aspect) ?: return if (aspect == com.lightlylabs.lightly.session.CropAspect.FREE) geometry.crop.rect else FULL_RECT
        val (w, h) = turnedDisplaySize(geometry.quarterTurns)
        val r = com.lightlylabs.lightly.develop.GeometryTransform.centredRect(ratio, w, h)
        return com.lightlylabs.lightly.session.NormalisedRect(r[0].coerceIn(0.0, 1.0), r[1].coerceIn(0.0, 1.0), r[2].coerceIn(0.0, 1.0 - r[0].coerceIn(0.0, 1.0)), r[3].coerceIn(0.0, 1.0 - r[1].coerceIn(0.0, 1.0)))
    }

    /** Crop › an aspect: a fixed aspect takes the largest centred rect of that shape; Original resets; Free keeps the rect. One step. */
    fun setCropAspect(aspect: com.lightlylabs.lightly.session.CropAspect) = commitEdit { e ->
        e.copy(geometry = e.geometry.copy(crop = com.lightlylabs.lightly.session.Crop(aspect, centredCrop(aspect, e.geometry))))
    }

    /** Rotate left (−1) or right (+1): one quarter turn; a fixed aspect is laid out again, a free rect turns with the photo. */
    fun rotate(delta: Int) = commitEdit { e ->
        val turned = e.geometry.copy(quarterTurns = ((e.geometry.quarterTurns + delta) % 4 + 4) % 4)
        val r = e.geometry.crop.rect
        val rect = when {
            EditOptions.ratio(e.geometry.crop.aspect) != null -> centredCrop(e.geometry.crop.aspect, turned)
            e.geometry.crop.aspect == com.lightlylabs.lightly.session.CropAspect.FREE ->
                if (delta > 0) com.lightlylabs.lightly.session.NormalisedRect((1 - r.y - r.height).coerceIn(0.0, 1.0), r.x, r.height, r.width)
                else com.lightlylabs.lightly.session.NormalisedRect(r.y, (1 - r.x - r.width).coerceIn(0.0, 1.0), r.height, r.width)
            else -> r
        }
        e.copy(geometry = turned.copy(crop = turned.crop.copy(rect = rect)))
    }

    fun flipHorizontal() = commitEdit { it.copy(geometry = it.geometry.copy(flipHorizontal = !it.geometry.flipHorizontal)) }

    fun flipVertical() = commitEdit { it.copy(geometry = it.geometry.copy(flipVertical = !it.geometry.flipVertical)) }

    private fun withEditSlider(e: com.lightlylabs.lightly.session.EditTool, field: String, value: Double): com.lightlylabs.lightly.session.EditTool {
        val a = e.adjust
        val v = value.coerceIn(-100.0, 100.0)
        val p = value.coerceIn(0.0, 100.0)
        return when (field) {
            "straighten" -> e.copy(geometry = e.geometry.copy(straighten = value.coerceIn(-45.0, 45.0)))
            "perspectiveVertical" -> e.copy(geometry = e.geometry.copy(perspective = e.geometry.perspective.copy(vertical = v)))
            "perspectiveHorizontal" -> e.copy(geometry = e.geometry.copy(perspective = e.geometry.perspective.copy(horizontal = v)))
            "exposure" -> e.copy(adjust = a.copy(exposure = v))
            "contrast" -> e.copy(adjust = a.copy(contrast = v))
            "highlights" -> e.copy(adjust = a.copy(highlights = v))
            "shadows" -> e.copy(adjust = a.copy(shadows = v))
            "temp" -> e.copy(adjust = a.copy(temp = v))
            "tint" -> e.copy(adjust = a.copy(tint = v))
            "saturation" -> e.copy(adjust = a.copy(saturation = v))
            "vibrance" -> e.copy(adjust = a.copy(vibrance = v))
            "sharpness" -> e.copy(adjust = a.copy(sharpness = p))
            "clarity" -> e.copy(adjust = a.copy(clarity = v))
            "noise" -> e.copy(adjust = a.copy(noise = p))
            else -> e
        }
    }

    /** An Edit slider moving: preview only. */
    fun onEditSlider(field: String, value: Double) {
        val session = state.value.session ?: return
        state.update { it.copy(edit = it.edit.copy(sliderDrag = field to value)) }
        requestPreview(session.current.copy(tools = session.current.tools.copy(edit = withEditSlider(session.current.tools.edit, field, value))), globalOnly = false)
    }

    /** Slider release: one undo step. */
    fun onEditSliderRelease(field: String, value: Double) {
        state.update { it.copy(edit = it.edit.copy(sliderDrag = null)) }
        commitEdit { withEditSlider(it, field, value) }
    }

    /**
     * Crop › a corner dragged by (dx, dy) of the displayed frame (corner 0 top-left, 1 top-right, 2 bottom-left,
     * 3 bottom-right): one step. A fixed aspect is kept; cropping an uncropped photo makes it Free.
     */
    fun dragCropCorner(corner: Int, dx: Double, dy: Double) = commitEdit { e ->
        val g = e.geometry
        val r = g.crop.rect
        val (tw, th) = turnedDisplaySize(g.quarterTurns)
        var left = r.x; var top = r.y; var right = r.x + r.width; var bottom = r.y + r.height
        val mx = dx * r.width
        val my = dy * r.height
        if (corner % 2 == 0) left += mx else right += mx
        if (corner < 2) top += my else bottom += my
        left = left.coerceIn(0.0, right - MIN_CROP); right = right.coerceIn(left + MIN_CROP, 1.0)
        top = top.coerceIn(0.0, bottom - MIN_CROP); bottom = bottom.coerceIn(top + MIN_CROP, 1.0)
        val ratio = EditOptions.ratio(g.crop.aspect)
        if (ratio != null) {
            // Keep w/h in pixels: shrink the side that is too long, anchored at the opposite corner.
            val widthPx = (right - left) * tw
            val heightPx = (bottom - top) * th
            if (widthPx / heightPx > ratio) {
                val w = heightPx * ratio / tw
                if (corner % 2 == 0) left = right - w else right = left + w
            } else {
                val h = widthPx / ratio / th
                if (corner < 2) top = bottom - h else bottom = top + h
            }
        }
        val aspect = if (g.crop.aspect == com.lightlylabs.lightly.session.CropAspect.ORIGINAL) com.lightlylabs.lightly.session.CropAspect.FREE else g.crop.aspect
        e.copy(geometry = g.copy(crop = com.lightlylabs.lightly.session.Crop(aspect, rectOf(left, top, right, bottom))))
    }

    /** Crop › pinch: zoom the crop about its centre by [zoom] (> 1 = closer), kept inside the frame and its aspect. One step. */
    fun pinchCrop(zoom: Double) = commitEdit { e ->
        val g = e.geometry
        val r = g.crop.rect
        val scale = (1 / zoom).coerceIn(MIN_CROP / minOf(r.width, r.height), minOf(1 / r.width, 1 / r.height))
        val w = r.width * scale
        val h = r.height * scale
        val left = (r.x + r.width / 2 - w / 2).coerceIn(0.0, 1.0 - w)
        val top = (r.y + r.height / 2 - h / 2).coerceIn(0.0, 1.0 - h)
        val aspect = if (g.crop.aspect == com.lightlylabs.lightly.session.CropAspect.ORIGINAL) com.lightlylabs.lightly.session.CropAspect.FREE else g.crop.aspect
        e.copy(geometry = g.copy(crop = com.lightlylabs.lightly.session.Crop(aspect, rectOf(left, top, left + w, top + h))))
    }

    private fun rectOf(left: Double, top: Double, right: Double, bottom: Double): com.lightlylabs.lightly.session.NormalisedRect {
        val x = left.coerceIn(0.0, 1.0)
        val y = top.coerceIn(0.0, 1.0)
        return com.lightlylabs.lightly.session.NormalisedRect(x, y, (right - x).coerceIn(0.0, 1.0 - x), (bottom - y).coerceIn(0.0, 1.0 - y))
    }

    /** The committed geometry at the display proxy's resolution (marks and touches map through it). */
    fun displayGeometry(ui: EditorUiState = state.value): com.lightlylabs.lightly.develop.GeometryTransform? {
        val display = ui.original ?: return null
        val recipe = ui.session?.current ?: return null
        return com.lightlylabs.lightly.develop.GeometryTransform(EditMapping.geometry(recipe), display.width, display.height)
    }

    /**
     * Remove: a stroke brushed on the photo ([framePoints] normalised on the displayed frame) starts
     * removing it. It becomes ONE undo step once its patch exists; cancelled or failed, nothing changes.
     */
    fun removeStroke(framePoints: List<Pair<Double, Double>>, radius: Double = EditOptions.brushRadius(state.value.edit.brushSize)) {
        if (framePoints.isEmpty() || state.value.edit.removeOp == RemoveOp.REMOVING) return
        val geometry = displayGeometry() ?: return
        val points = framePoints.map { (x, y) -> geometry.sourceFromFrame(x, y).let { (sx, sy) -> sx.coerceIn(0.0, 1.0) to sy.coerceIn(0.0, 1.0) } }
        runRemove(PendingRemoveStroke(points, radius))
    }

    /** Remove failed › Try again: the same stroke once more. */
    fun retryRemove() {
        val stroke = state.value.edit.pendingStroke?.takeIf { state.value.edit.removeOp == RemoveOp.FAILED } ?: return
        runRemove(stroke)
    }

    /** Removing › Cancel: "Cancelled · nothing changed". */
    fun cancelRemove() {
        removeJob?.cancel()
        state.update { it.copy(edit = it.edit.copy(removeOp = RemoveOp.IDLE, pendingStroke = null)) }
        showToast(OPERATION_CANCELLED)
    }

    /** Undo stroke: removes the last applied stroke (one step); redo replays its stored patch. */
    fun undoStroke() = commitEdit { e -> e.copy(remove = e.remove.copy(strokes = e.remove.strokes.dropLast(1))) }

    private fun runRemove(stroke: PendingRemoveStroke) {
        val current = photo?.takeIf { isCurrent(it.generation) } ?: return
        removeJob?.cancel()
        state.update { it.copy(edit = it.edit.copy(removeOp = RemoveOp.REMOVING, pendingStroke = stroke)) }
        if (debugHoldRemove) return // capture of the approved "Removing…" state (debug builds only)
        removeJob = scope.launch {
            val result = runCatching {
                kotlinx.coroutines.withContext(env.prefetchDispatcher) { // off the main thread; the model call blocks
                    val model = inpainter ?: throw RemoveUnavailableException("No Remove model in this build")
                    // Full-resolution source with the earlier strokes' patches (remove-evaluation §7).
                    val source = current.loaded.fullResolution.decode()
                    val applied = state.value.session?.current?.let { EditMapping.patchDigests(it) }.orEmpty().mapNotNull { removePatches[it] }
                    RemoveEngine.composite(applied, source, inPlace = true)
                    val started = System.nanoTime()
                    val patch = RemoveEngine.patch(source, stroke.points, stroke.radius, model) { !coroutineContext.isActive }
                    runCatching { android.util.Log.i("LightlyRemove", "stroke removed in ${(System.nanoTime() - started) / 1_000_000} ms") }
                    patch to model.model
                }
            }
            if (!isCurrent(current.generation)) return@launch
            val (patch, modelRef) = result.getOrElse { failure ->
                if (failure is CancellationException) return@launch
                runCatching { android.util.Log.w("LightlyRemove", "remove failed: $failure") }
                state.update { it.copy(edit = it.edit.copy(removeOp = RemoveOp.FAILED)) }
                return@launch
            }
            removePatches.put(patch)
            val recorded = com.lightlylabs.lightly.session.RemoveStroke(stroke.radius.coerceIn(1e-6, 0.5), stroke.points.map { (x, y) -> com.lightlylabs.lightly.session.NormalisedPoint(x, y) },
                com.lightlylabs.lightly.session.RemoveResult(com.lightlylabs.lightly.session.RemoveStatus.APPLIED, patch.derivedRef(modelRef)))
            state.update { it.copy(edit = it.edit.copy(removeOp = RemoveOp.IDLE, pendingStroke = null)) }
            commitEdit { e -> e.copy(remove = e.remove.copy(strokes = e.remove.strokes + recorded)) }
            debugAfterRemove?.let { action -> debugAfterRemove = null; action() }
        }
    }

    // --- Effects (slice 4) ------------------------------------------------------------------------

    fun selectEffectsSub(sub: EffectsSub) = state.update { it.copy(effects = it.effects.copy(sub = sub, sliderDrag = null)) }

    private fun commitEffects(change: (com.lightlylabs.lightly.session.EffectsTool) -> com.lightlylabs.lightly.session.EffectsTool) {
        val session = state.value.session ?: return
        commit(session.commit { s -> s.copy(tools = s.tools.copy(effects = change(s.tools.effects))) }, state.value.auto)
    }

    /** The On/Off row: one step. */
    fun toggleEffect(sub: EffectsSub) = commitEffects { e ->
        when (sub) {
            EffectsSub.LEAK -> e.copy(lightLeak = e.lightLeak.copy(enabled = !e.lightLeak.enabled))
            EffectsSub.GRAIN -> e.copy(grain = e.grain.copy(enabled = !e.grain.enabled))
            EffectsSub.VIGNETTE -> e.copy(vignette = e.vignette.copy(enabled = !e.vignette.enabled))
        }
    }

    fun setLeakStyle(style: com.lightlylabs.lightly.session.LeakStyle) = commitEffects { it.copy(lightLeak = it.lightLeak.copy(style = style)) }

    fun setGrainStyle(style: com.lightlylabs.lightly.session.GrainStyle) = commitEffects { it.copy(grain = it.grain.copy(style = style)) }

    private fun withEffectsSlider(e: com.lightlylabs.lightly.session.EffectsTool, field: String, value: Double): com.lightlylabs.lightly.session.EffectsTool {
        val p = value.coerceIn(0.0, 100.0)
        return when (field) {
            "leakIntensity" -> e.copy(lightLeak = e.lightLeak.copy(intensity = p))
            "leakRotation" -> e.copy(lightLeak = e.lightLeak.copy(rotation = value.coerceIn(-180.0, 180.0)))
            "grainAmount" -> e.copy(grain = e.grain.copy(amount = p))
            "grainSize" -> e.copy(grain = e.grain.copy(size = p))
            "grainRoughness" -> e.copy(grain = e.grain.copy(roughness = p))
            "vignetteAmount" -> e.copy(vignette = e.vignette.copy(amount = p))
            "vignetteSize" -> e.copy(vignette = e.vignette.copy(size = p))
            "vignetteSoftness" -> e.copy(vignette = e.vignette.copy(softness = p))
            else -> e
        }
    }

    fun onEffectsSlider(field: String, value: Double) {
        val session = state.value.session ?: return
        state.update { it.copy(effects = it.effects.copy(sliderDrag = field to value)) }
        requestPreview(session.current.copy(tools = session.current.tools.copy(effects = withEffectsSlider(session.current.tools.effects, field, value))), globalOnly = false)
    }

    fun onEffectsSliderRelease(field: String, value: Double) {
        state.update { it.copy(effects = it.effects.copy(sliderDrag = null)) }
        commitEffects { withEffectsSlider(it, field, value) }
    }

    /** Light Leaks › drag on the photo: the leak follows the finger (preview); release is one step. */
    fun moveLeak(x: Double, y: Double, release: Boolean) {
        val session = state.value.session ?: return
        val move: (com.lightlylabs.lightly.session.EffectsTool) -> com.lightlylabs.lightly.session.EffectsTool = { it.copy(lightLeak = it.lightLeak.copy(x = (x * 100).coerceIn(0.0, 100.0), y = (y * 100).coerceIn(0.0, 100.0))) }
        if (release) commitEffects(move) else requestPreview(session.current.copy(tools = session.current.tools.copy(effects = move(session.current.tools.effects))), globalOnly = false)
    }

    /**
     * The approved notice: the applied preset already has its own grain (or vignette) and the person's is on.
     */
    // v3 differs (as iOS F1): the prototype decides "has its own grain/vignette" with a stand-in hash of the
    // preset id (`presetHasEffect`, marked as an open question there); this reads the preset's real
    // recipe.finishing, so the notice is true for the applied preset.
    fun presetHasOwn(sub: EffectsSub, ui: EditorUiState = state.value): Boolean {
        val preset = library?.preset(ui.session?.current?.look) ?: return false
        return when (sub) {
            EffectsSub.GRAIN -> (preset.recipe.finishing.grain?.amount ?: 0.0) != 0.0
            EffectsSub.VIGNETTE -> (preset.recipe.finishing.vignette?.amount ?: 0.0) != 0.0
            EffectsSub.LEAK -> false
        }
    }

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
        val exportPlan = if (EditMapping.usesEditOrEffects(committed)) editExportPlan(committed, plan, backgroundPlan) else ExportRenderPlan { frame ->
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

    /** Save copy of a recipe with Edit or Effects (EditPipeline): the same stages as its preview, at full resolution. */
    private fun editExportPlan(committed: EditState, plan: com.lightlylabs.lightly.develop.DevelopRenderPlan, backgroundPlan: com.lightlylabs.lightly.background.BackgroundPlan?): ExportRenderPlan {
        val library = library ?: error("no library")
        val renderer = DevelopRenderer(exportPool, EXPORT_PARALLELISM)
        val pipeline = EditPipeline(library.model, renderer, exportPool, EXPORT_PARALLELISM)
        val patches = EditMapping.patchDigests(committed).mapNotNull { removePatches[it] }
        val background = backgroundPlan?.let { bp ->
            { frame: Rgba8Image ->
                // Background renders once at the analysis size (K = 8) from Develop + Adjust, then each
                // source region keeps its in-focus pixels and takes the rest from that render.
                val analysis = backgroundSession.analysis!!
                val small = BackgroundSession.resize(frame, analysis.width, analysis.height)
                val developed = renderer.render(small, plan.withoutFinishing())
                val adjusted = com.lightlylabs.lightly.develop.AdjustStage.plan(EditMapping.adjust(committed), library.model)?.let { renderer.render(developed, it) } ?: developed
                val rendered = backgroundSession.render(adjusted, bp, com.lightlylabs.lightly.background.Refocus.FocusConstants.LAYERS_PER_SIDE_EXPORT, committed.tools.background)
                val compose: (ByteArray, PixelRect, Int, Int) -> ByteArray = { pixels, region, fw, fh ->
                    com.lightlylabs.lightly.background.BackgroundStage.composeTile(pixels, region.x, region.y, region.width, region.height, fw, fh, rendered.first.pixels, rendered.second)
                }
                compose
            }
        }
        return pipeline.exportPlan(committed, plan, patches, background)
    }

    /** [display] with the recipe's applied Remove patches composited (cached for the current list). */
    private fun patched(display: Rgba8Image, edit: EditState): Rgba8Image {
        val digests = EditMapping.patchDigests(edit)
        if (digests.isEmpty()) return display
        patchedDisplay?.takeIf { it.first == digests }?.let { return it.second }
        val image = RemoveEngine.composite(digests.mapNotNull { removePatches[it] }, display)
        patchedDisplay = digests to image
        return image
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
                val image = if (EditMapping.usesEditOrEffects(edit)) {
                    // Slice 4: every stage on the full proxy (Remove patches are in display coordinates).
                    val compose = backgroundPlan?.let { bp -> { developed: Rgba8Image -> backgroundSession.render(developed, bp, com.lightlylabs.lightly.background.Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW, edit.tools.background).first } }
                    EditPipeline(library.model, env.previewRenderer).renderPreview(patched(display, edit), edit, plan, compose)
                } else {
                    // With Background active the drag preview keeps the full proxy: the stage works at the analysis size.
                    val source = if (request.payload.globalOnly && backgroundPlan == null) dragProxy else display
                    val developed = if (plan.isIdentity) source else env.previewRenderer.render(source, plan)
                    if (backgroundPlan == null) developed else backgroundSession.render(developed, backgroundPlan, com.lightlylabs.lightly.background.Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW, edit.tools.background).first
                }
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
                if (result != null && result.sessionId == "photo-$photoGeneration") settledRevision = result.revision
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

    /** Latest revision the scheduler published anything for (rendered or failed); capture readiness. */
    @Volatile internal var settledRevision: Long = -1

    /**
     * Capture runner readiness (debug builds only): no photo load, prefetch or separation running and
     * the latest requested preview settled. Held debug states (loading, separating) count as settled,
     * because their jobs return immediately.
     */
    internal fun debugWorkIdle(): Boolean =
        listOf(loadJob, prefetchJob, separationJob, removeJob).none { it?.isActive == true } && settledRevision >= requestedRevision
    internal val renderMillis: MutableList<Double> = java.util.Collections.synchronizedList(mutableListOf())

    // --- debug launch state (debug builds only; see DebugLaunchOptions) --------------------------

    /** Capture-only override of person detection, so a capture can mirror the reference photo. */
    internal var debugPresence: PersonPresence? = null

    /** Capture-only: stop after decoding, so the approved "Opening photo…" screen can be captured. */
    internal var debugHoldLoading: Boolean = false

    /** Debug captures only: separation never finishes, so "Finding the subject…" can be captured. */
    internal var debugHoldSeparation: Boolean = false

    /** Debug captures only: Remove stays "Removing…", so the approved state can be captured. */
    internal var debugHoldRemove: Boolean = false

    /** Debug captures only: run once when a stroke has been removed (the screen's history rebase). */
    internal var debugAfterRemove: (() -> Unit)? = null

    /** Debug captures only: run once when separation finishes (e.g. the prototype screen's blur). */
    internal var debugAfterSeparation: (() -> Unit)? = null

    /** Capture-only: sets the phase (the loading capture shows "Developing…", which no model triggers here). */
    internal fun debugSetPhase(phase: EditorPhase) = state.update { it.copy(phase = phase) }

    /**
     * Applies a capture state once the session is Ready. Debug builds only: release builds never call
     * it (DebugLaunchOptions is gated on BuildConfig.DEBUG).
     */
    internal fun applyDebugState(apply: (DebugEditorApi) -> Unit): Job =
        scope.launch {
            while (state.value.phase != EditorPhase.Ready && state.value.phase !is EditorPhase.LoadFailed) delay(50)
            if (state.value.phase == EditorPhase.Ready) apply(DebugEditorApi())
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

        /** Slice 4: an Edit or Effects change committed as the user would (one step). */
        fun edit(change: (com.lightlylabs.lightly.session.EditTool) -> com.lightlylabs.lightly.session.EditTool) = commitEdit(change)

        fun effects(change: (com.lightlylabs.lightly.session.EffectsTool) -> com.lightlylabs.lightly.session.EffectsTool) = commitEffects(change)

        fun cropAspect(aspect: com.lightlylabs.lightly.session.CropAspect) = setCropAspect(aspect)

        /** Opens a tool as the user would (resets its sub-UI), then applies [ui] to the fresh UI. */
        fun openTool(tool: EditorTool, ui: (EditorUiState) -> EditorUiState = { it }) {
            selectTool(tool)
            state.update(ui)
        }

        /**
         * The prototype's Remove stroke mark (`.stroke` at left 62 %, top 30 %, 16 % × 5 %, rotate(−12deg)) as a
         * real stroke: a capsule of the same centre, length, thickness and angle on the displayed frame.
         */
        fun prototypeStroke(): Pair<List<Pair<Double, Double>>, Double>? {
            val display = state.value.original ?: return null
            val w = display.width.toDouble()
            val h = display.height.toDouble()
            val radiusPx = 0.05 * h / 2
            val half = (0.16 * w - 2 * radiusPx) / 2
            val angle = Math.toRadians(-12.0)
            val cx = 0.70 * w
            val cy = 0.325 * h
            val points = listOf(-1.0, 1.0).map { sign -> (cx + sign * half * kotlin.math.cos(angle)) / w to (cy + sign * half * kotlin.math.sin(angle)) / h }
            return points to radiusPx / maxOf(w, h)
        }

        /** Removes [stroke] with the real model; [after] runs once it is applied (or never, when it fails). */
        fun remove(stroke: Pair<List<Pair<Double, Double>>, Double>, after: (() -> Unit)? = null) {
            debugAfterRemove = after
            removeStroke(stroke.first, stroke.second)
        }

        /** Holds an approved Remove state for a capture with the stroke the person drew, without running the model. */
        fun holdRemove(op: RemoveOp, stroke: Pair<List<Pair<Double, Double>>, Double>) {
            val geometry = displayGeometry() ?: return
            val points = stroke.first.map { (x, y) -> geometry.sourceFromFrame(x, y) }
            state.update { it.copy(edit = it.edit.copy(removeOp = op, pendingStroke = PendingRemoveStroke(points, stroke.second))) }
        }

        /** Opens Background on [sub] as the user would (starts separation). */
        fun openBackground(sub: BackgroundSub, afterSeparation: (() -> Unit)? = null) {
            debugAfterSeparation = afterSeparation
            selectTool(EditorTool.BACKGROUND)
            selectBackgroundSub(sub)
        }

        /** The prototype screen's Focus & Blur settings, committed as the user would (one step each). */
        fun focus(blur: Double, style: com.lightlylabs.lightly.session.FocusStyle?) {
            onBackgroundSliderRelease("blur", blur)
            style?.let { setFocusStyle(it) }
        }

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

        /** The uncropped rect, and the smallest crop side (fraction of the frame) a gesture can leave. */
        private val FULL_RECT = com.lightlylabs.lightly.session.NormalisedRect(0.0, 0.0, 1.0, 1.0)
        private const val MIN_CROP = 0.1

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
