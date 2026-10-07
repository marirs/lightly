package com.lightlylabs.lightly

import android.Manifest
import android.app.UiModeManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.lifecycle.viewmodel.initializer
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker
import androidx.window.layout.WindowMetricsCalculator
import com.lightlylabs.lightly.editor.AndroidEditorEnvironment
import com.lightlylabs.lightly.editor.EditorActions
import com.lightlylabs.lightly.editor.EditorEnvironment
import com.lightlylabs.lightly.editor.EditorPhase
import com.lightlylabs.lightly.editor.EditorScreen
import com.lightlylabs.lightly.editor.EditorViewModel
import com.lightlylabs.lightly.editor.FavouritesStore
import com.lightlylabs.lightly.prefs.Appearance
import com.lightlylabs.lightly.prefs.PreferencesStore
import com.lightlylabs.lightly.prefs.PresetCatalogue
import com.lightlylabs.lightly.prefs.ReleaseText
import com.lightlylabs.lightly.prefs.SharedPreferencesStore
import com.lightlylabs.lightly.prefs.UserPreferences
import com.lightlylabs.lightly.shell.AppNavState
import com.lightlylabs.lightly.shell.AppNavigator
import com.lightlylabs.lightly.shell.AppViewModel
import com.lightlylabs.lightly.shell.BaseScreen
import com.lightlylabs.lightly.shell.CameraCaptures
import com.lightlylabs.lightly.shell.DebugLaunchOptions
import com.lightlylabs.lightly.shell.FoldGeometry
import com.lightlylabs.lightly.shell.LightlyAppContent
import com.lightlylabs.lightly.shell.LightlyTheme
import com.lightlylabs.lightly.shell.MoreActions
import com.lightlylabs.lightly.shell.MoreContent
import com.lightlylabs.lightly.shell.OrientationPolicy
import com.lightlylabs.lightly.shell.ShellActions
import com.lightlylabs.lightly.shell.ShellLayout
import com.lightlylabs.lightly.shell.isDarkAppearance
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * The single Activity. Launch is the system splash (themes.xml: the eight-ray mark on the approved
 * background), then Welcome. Everything below is [LightlyAppContent]; this class only owns what needs
 * an Activity: system pickers, the camera and its permission, orientation, edge-to-edge, folds.
 */
class MainActivity : ComponentActivity() {

    private lateinit var captures: CameraCaptures

    /**
     * The view models the content is built from. Only the debug capture runner replaces them (with a
     * new [ActiveViewModels.epoch]); the content is keyed by the epoch, so every remembered UI state
     * (scroll, sheets, focus, dialogs) starts again as on a fresh launch.
     */
    private var active by androidx.compose.runtime.mutableStateOf<ActiveViewModels?>(null)

    /** Store for the capture runner's per-screen view models; cleared (onCleared, scopes cancelled) per screen. */
    private val captureStore = androidx.lifecycle.ViewModelStore()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyOrientationPolicy()
        captures = CameraCaptures(this)
        val graph = AppGraph.get(this)
        val metrics = WindowInfoTracker.getOrCreate(this).windowLayoutInfo(this)
        val folds = metrics.map { info ->
            // Debug builds log what WindowManager reports, for the fold/hinge comparison runs.
            if (BuildConfig.DIAGNOSTICS) Log.d(LOG_TAG, "display features: ${info.displayFeatures}")
            info.displayFeatures.filterIsInstance<FoldingFeature>()
        }
        // Same owner and default keys as `viewModel()` would use, so these survive recreation.
        val shell = ViewModelProvider(this, AppViewModel.factory)[AppViewModel::class.java]
        val editor = ViewModelProvider(this, EditorViewModel.factory(graph.editorEnvironment))[EditorViewModel::class.java]
        editor.onLeave = { shell.navigate(AppNavigator.toWelcome()) }
        active = ActiveViewModels(0, shell, editor)
        val launchScenario = if (savedInstanceState == null) DebugLaunchOptions.apply(intent, shell, graph.preferences, editor) else null
        // Debug builds only (the release source set's hook does nothing): the persistent capture runner,
        // and the same render-complete signal for a per-launch capture.
        // Called on recreation too, so a running capture runner binds to the new Activity.
        if (BuildConfig.DIAGNOSTICS) com.lightlylabs.lightly.capture.CaptureRunnerHook.attach(this, intent, graph.preferences, launchScenario)

        setContent {
          val viewModels = active ?: return@setContent
          androidx.compose.runtime.key(viewModels.epoch) {
            val shell = viewModels.shell
            val editor = viewModels.editor
            val preferences by graph.preferences.preferences.collectAsStateWithLifecycle()
            val catalogue by graph.catalogue.collectAsStateWithLifecycle()
            val nav by shell.nav.collectAsStateWithLifecycle()
            val currentFolds by folds.collectAsStateWithLifecycle(initialValue = emptyList())
            val editorUi by editor.uiState.collectAsStateWithLifecycle()
            val savedSignatures by editor.signatures.collectAsStateWithLifecycle()

            val dark = isDarkAppearance(preferences.appearance)
            LaunchedEffect(dark) { applySystemBars(dark) }

            // A photo the editor cannot open (or can no longer read) moves to the approved "can't be opened" screen.
            LaunchedEffect(editorUi.phase, nav.base) {
                val failed = editorUi.phase is EditorPhase.LoadFailed || editorUi.phase is EditorPhase.PhotoAccessLost
                if (nav.base == BaseScreen.EDITOR && failed) shell.navigate(AppNavigator.showLoadFailed())
            }
            BackHandler(enabled = nav != AppNavState()) {
                // In the editor, Back is the editor's Close: it may ask "Leave without saving?" first.
                if (nav.base == BaseScreen.EDITOR && nav.morePage == null) editor.close() else if (!shell.back()) finish()
            }

            val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
                // Cancel (null) changes nothing. openPhoto persists the read grant while it is valid.
                if (uri != null) openInEditor(uri.toString(), editor, shell)
            }
            val takePicture = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { saved ->
                val target = shell.pendingCaptureUri
                shell.pendingCaptureUri = null
                if (target == null) return@rememberLauncherForActivityResult
                if (saved) openInEditor(target, editor, shell) else captures.discard(target)
            }
            val launchCamera = {
                val target = captures.newCaptureUri(keep = editor.currentAssetId)
                shell.pendingCaptureUri = target.toString()
                try {
                    takePicture.launch(target)
                } catch (noCameraApp: ActivityNotFoundException) {
                    // DEFERRED(slice 6): a device without any camera app; Welcome stays as it was.
                    shell.pendingCaptureUri = null
                }
            }
            val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
                if (granted) launchCamera() else shell.navigate(AppNavigator.showCameraDenied())
            }
            val choosePhoto = { photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
            // Background › Change background › "+": a photo for the new background (cancel changes nothing).
            val backgroundPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
                if (uri != null) editor.useBackgroundPhoto(uri.toString())
            }
            // Watermark › Signature › Import and Logo › Replace logo (cancel changes nothing).
            val signaturePicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
                if (uri != null) editor.importSignaturePhoto(uri.toString())
            }
            val logoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
                if (uri != null) editor.replaceLogo(uri.toString())
            }
            androidx.compose.runtime.SideEffect {
                editor.onChooseBackgroundPhoto = { backgroundPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
                editor.onChooseSignaturePhoto = { signaturePicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
                editor.onChooseLogo = { logoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
            }

            LightlyTheme(dark) {
                BoxWithConstraints(Modifier.fillMaxSize()) {
                    val density = LocalDensity.current
                    val fold = currentFolds.firstOrNull()?.let { feature ->
                        val vertical = feature.orientation == FoldingFeature.Orientation.VERTICAL
                        val centerPx = if (vertical) feature.bounds.exactCenterX() else feature.bounds.exactCenterY()
                        FoldGeometry(isVertical = vertical, centerDp = with(density) { centerPx.toDp().value })
                    }
                    val layout = ShellLayout.decide(maxWidth.value, maxHeight.value, fold)
                    LightlyAppContent(
                        state = nav,
                        layout = layout,
                        content = MoreContent(preferences, catalogue, graph.releaseText, versionLabel(), nav.privacyFromWelcome, savedSignatures.shown),
                        actions = ShellActions(
                            choosePhoto = choosePhoto,
                            camera = {
                                val granted = ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
                                if (granted) launchCamera() else cameraPermission.launch(Manifest.permission.CAMERA)
                            },
                            openAppSettings = ::openAppSettings,
                            retryLoad = {
                                editor.currentAssetId?.let { asset -> openInEditor(asset, editor, shell) } ?: shell.navigate(AppNavigator.toWelcome())
                            },
                            navigate = shell::navigate,
                            more = MoreActions(
                                openPage = { page -> shell.navigate(AppNavigator.openPage(nav, page)) },
                                back = { shell.back() },
                                close = { shell.navigate(AppNavigator.closeMore(nav)) },
                                updatePreferences = { change -> updatePreferences(graph.preferences, change) },
                                openSupport = ::openSupportDestination,
                                // Prototype `overlay:sigDraw` / `overlay:sigImport`: where More is a sheet (tablets,
                                // folds) the signature sheet replaces it; a full-screen page (phones, as the
                                // prototype's `page` screens) stays under the sheet. Dismissing closes the sheet.
                                drawSignature = {
                                    if (layout != ShellLayout.Compact) shell.navigate(AppNavigator.closeMore(nav))
                                    editor.preferencesDrawSignature()
                                },
                                importSignature = {
                                    if (layout != ShellLayout.Compact) shell.navigate(AppNavigator.closeMore(nav))
                                    editor.preferencesImportSignature()
                                },
                                deleteSignature = editor::deleteShownSignature,
                            ),
                        ),
                        editor = {
                            EditorScreen(
                                editor, layout,
                                EditorActions(
                                    more = { shell.navigate(AppNavigator.openMore(nav)) },
                                    share = ::shareSavedCopy,
                                    chooseAnother = choosePhoto,
                                ),
                            )
                        },
                    )
                    // Preferences › Saved signature › Draw / Import: over the More page and whatever is under it.
                    com.lightlylabs.lightly.editor.PreferencesSignatureSheet(editor)
                }
            }
          }
        }
    }

    /**
     * Capture runner (debug builds only): replaces the shell and editor view models with new ones, as
     * a fresh launch creates them, after clearing the previous capture's (cancelling their work and
     * timers), and clears focus and the keyboard. The content recomposes from scratch under a new key.
     */
    internal fun resetForCapture(): ActiveViewModels {
        captureStore.clear()
        val graph = AppGraph.get(this)
        val provider = ViewModelProvider.create(captureStore, androidx.lifecycle.viewmodel.viewModelFactory {
            initializer { AppViewModel(androidx.lifecycle.SavedStateHandle()) }
            initializer { EditorViewModel(androidx.lifecycle.SavedStateHandle(), graph.editorEnvironment, CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)) }
        })
        val shell = provider[AppViewModel::class.java]
        val editor = provider[EditorViewModel::class.java]
        editor.onLeave = { shell.navigate(AppNavigator.toWelcome()) }
        currentFocus?.clearFocus()
        androidx.core.view.WindowCompat.getInsetsController(window, window.decorView).hide(androidx.core.view.WindowInsetsCompat.Type.ime())
        val next = ActiveViewModels((active?.epoch ?: 0) + 1, shell, editor)
        active = next
        return next
    }

    override fun onDestroy() {
        // The capture runner's per-screen view models belong to this Activity instance.
        captureStore.clear()
        super.onDestroy()
    }

    /** Capture runner diagnostics (debug builds only): the editor of the current epoch. */
    internal fun activeEditorForCapture(): EditorViewModel? = active?.editor

    private fun openInEditor(assetId: String, editor: EditorViewModel, shell: AppViewModel) {
        editor.openPhoto(assetId)
        shell.navigate(AppNavigator.openEditor())
    }

    /** Phones and folded foldables: portrait only. Unfolded foldables and tablets: any orientation. */
    private fun applyOrientationPolicy() {
        val bounds = WindowMetricsCalculator.getOrCreate().computeMaximumWindowMetrics(this).bounds
        val density = resources.displayMetrics.density
        val smallestWidthDp = minOf(bounds.width(), bounds.height()) / density
        requestedOrientation = OrientationPolicy.requestedOrientation(smallestWidthDp, isInMultiWindowMode)
    }

    /** Transparent bars (edge-to-edge) with icons that contrast with the approved background. */
    private fun applySystemBars(dark: Boolean) {
        val style = if (dark) SystemBarStyle.dark(Color.TRANSPARENT) else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
        enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
    }

    /**
     * Saves the change; an Appearance change is also handed to the system on API 31+ so the next
     * launch's splash matches it (this recreates the Activity; navigation state is saved).
     */
    private fun updatePreferences(store: PreferencesStore, change: (UserPreferences) -> UserPreferences) {
        val before = store.preferences.value.appearance
        store.update(change)
        val after = store.preferences.value.appearance
        if (after != before && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val mode = when (after) {
                Appearance.SYSTEM -> UiModeManager.MODE_NIGHT_AUTO
                Appearance.LIGHT -> UiModeManager.MODE_NIGHT_NO
                Appearance.DARK -> UiModeManager.MODE_NIGHT_YES
            }
            getSystemService(UiModeManager::class.java)?.setApplicationNightMode(mode)
        }
    }

    private fun openAppSettings() {
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
    }

    private fun openSupportDestination(destination: String) {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(destination)))
        } catch (noHandler: ActivityNotFoundException) {
            // Nothing can open it; the Support page stays as it is.
        }
    }

    private companion object {
        const val LOG_TAG = "LightlyShell"
    }

    private fun versionLabel() = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})"

    /**
     * Saved sheet › Share: the system share sheet with the saved copy, which already follows the
     * metadata policy it was saved with. DEFERRED(slice 5): the approved share flow's own checks.
     */
    /**
     * Saved › Share (approved `share`): the system share sheet with the saved copy's exact bytes, from Share's
     * copy written alongside the save (same pixels, same metadata policy). The original is never touched.
     */
    private fun shareSavedCopy(savedUri: String) {
        // The share copy is the byte-exact file. Without it (another save replaced it, or the cache was
        // cleared), the saved asset itself is shared; MediaStore may then hide its location from the reader.
        val copy = com.lightlylabs.lightly.editor.AndroidEditorEnvironment.shareCopies(this).existingFor(savedUri)
        val stream = copy?.let { androidx.core.content.FileProvider.getUriForFile(this, "$packageName.captures", it) } ?: Uri.parse(savedUri)
        val send = Intent(Intent.ACTION_SEND).setType("image/jpeg").putExtra(Intent.EXTRA_STREAM, stream).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .apply { clipData = android.content.ClipData.newRawUri(null, stream) }
        try {
            startActivity(Intent.createChooser(send, null))
        } catch (noHandler: ActivityNotFoundException) {
            // Nothing can share it; the Saved sheet stays.
        }
    }
}

/** The view models one capture epoch (or the normal app) is built from. */
internal class ActiveViewModels(val epoch: Int, val shell: AppViewModel, val editor: EditorViewModel)

/**
 * Process-wide singletons (manual DI until Hilt). The editor environment, and with it the export
 * coordinator and the render thread, outlives Activity recreation, so a Save in progress survives
 * rotation along with the ViewModel.
 */
internal class AppGraph private constructor(context: Context) {
    val preferences: PreferencesStore = SharedPreferencesStore(context.getSharedPreferences(SharedPreferencesStore.FILE_NAME, Context.MODE_PRIVATE))

    val releaseText: ReleaseText = ReleaseText.parse(readAsset(context, ReleaseText.ASSET_PATH))

    private val catalogueState = MutableStateFlow(PresetCatalogue.EMPTY)

    /** Parsed off the main thread (340 KB of JSON); the favourites page shows ids until it is ready. */
    val catalogue: StateFlow<PresetCatalogue> = catalogueState

    /** Favourites are the slice-1 preference: Develop's star and Preferences › Favourite presets share them. */
    private val favouritesStore = object : FavouritesStore {
        private val state = MutableStateFlow(preferences.preferences.value.favouritePresetIds)
        override val favourites: StateFlow<List<String>> = state

        init {
            CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).launch {
                preferences.preferences.collect { state.value = it.favouritePresetIds }
            }
        }

        override fun update(change: (List<String>) -> List<String>) {
            preferences.update { prefs -> prefs.copy(favouritePresetIds = change(prefs.favouritePresetIds).distinct().take(UserPreferences.MAX_FAVOURITES)) }
        }
    }

    val editorEnvironment: EditorEnvironment = run {
        val metrics = context.resources.displayMetrics
        AndroidEditorEnvironment.create(
            context,
            screenLongestPx = maxOf(metrics.widthPixels, metrics.heightPixels),
            metadataPolicy = { preferences.preferences.value.metadataPolicy },
            preferredBorder = { preferences.preferences.value.preferredBorder },
            favourites = favouritesStore,
        )
    }

    init {
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            readAsset(context, PresetCatalogue.ASSET_PATH)?.let { json ->
                catalogueState.value = PresetCatalogue.parse(json, com.lightlylabs.lightly.develop.PresetDisplayNames.parse(readAsset(context, com.lightlylabs.lightly.develop.PresetDisplayNames.ASSET_PATH)))
            }
        }
    }

    companion object {
        @Volatile private var instance: AppGraph? = null

        fun get(context: Context): AppGraph = instance ?: synchronized(this) {
            instance ?: AppGraph(context.applicationContext).also { instance = it }
        }

        private fun readAsset(context: Context, path: String): String? = try {
            context.assets.open(path).use { it.readBytes().toString(Charsets.UTF_8) }
        } catch (missing: java.io.IOException) {
            null
        }
    }
}
