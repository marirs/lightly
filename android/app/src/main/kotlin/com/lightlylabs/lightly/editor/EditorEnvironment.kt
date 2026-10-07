package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.develop.DevelopRenderer
import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.FullResolutionSource
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.AutoResult
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.flow.StateFlow

/** A picked photo, decoded twice (spec §3, §4.6): once for analysis, once for display. */
class LoadedPhoto(
    val source: SourceRef,
    /** Long edge 1024 (or the Original if smaller): model and detector input only. */
    val analysis: Rgba8Image,
    /** Display proxy: the preview render input. */
    val display: Rgba8Image,
    /** Full-resolution decode for Save copy, run only when exporting. */
    val fullResolution: FullResolutionSource,
    /** The original file's bytes (embedded depth lives in them). */
    val readOriginal: suspend () -> ByteArray = { ByteArray(0) },
)

fun interface PhotoLoader {
    /**
     * @throws PhotoAccessLostException when the photo can no longer be read (grant gone, item deleted).
     * @throws Exception with a user-presentable message for any other failure (LoadFailed).
     */
    suspend fun load(assetId: String): LoadedPhoto

    /**
     * The photo opened for editing: as [load], and the loader may keep a private copy of its original for Save copy.
     * [recovering]: a session restored after the process was ended; the copy kept for this photo, if any, is used.
     */
    suspend fun loadForEditing(assetId: String, recovering: Boolean = false): LoadedPhoto = load(assetId)

    /** The edit is over (left, discarded, or no session to restore at start): the kept copy, if any, is removed. */
    fun releaseEditingCopy() {}
}

sealed interface DevelopResult {
    /**
     * Auto ran. [correction]: the analysed correction (Android's own engine, `AutoCorrection`); its LUT is the stage-1
     * Auto LUT, and it is stored with the session so a restore rebuilds the LUT without analysing again.
     */
    data class Developed(val auto: AutoResult, val correction: com.lightlylabs.lightly.develop.auto.AutoCorrection? = null) : DevelopResult

    /** The model ran (or tried to) and produced no Auto result: the approved failure state with Retry. */
    data class Failed(val message: String) : DevelopResult

    /**
     * This build ships no Auto model (dependency D1). Nothing failed and Retry can never succeed: the
     * approved "Automatic correction isn't available on this device" state.
     */
    data object NoModelInThisBuild : DevelopResult
}

fun interface AutoDeveloper {
    /** [faces]: the usable faces of the photo (normalised, origin top-left), for the skin guard. */
    suspend fun develop(fingerprint: SourceFingerprint, analysis: Rgba8Image, faces: List<com.lightlylabs.lightly.develop.auto.AutoAnalysis.Face>): DevelopResult
}

/** The favourite preset ids, shared with Preferences › Favourite presets (slice 1). */
interface FavouritesStore {
    val favourites: StateFlow<List<String>>
    fun update(change: (List<String>) -> List<String>)
}

/**
 * Everything the editor depends on, injected so the whole flow is testable on the JVM with fakes
 * and virtual time. Production wiring is in [AndroidEditorEnvironment].
 */
class EditorEnvironment(
    val photoLoader: PhotoLoader,
    /** Persists read access to picked photos so a restore after process death can reopen them. */
    val photoAccess: PhotoAccessGrants,
    val autoDeveloper: AutoDeveloper,
    val personDetector: PersonDetector,
    /** The pack and model, parsed off the main thread once per process. */
    val library: Deferred<DevelopLibrary>,
    /** CPU renderer (DevelopRenderer) used by previews; the export uses one with the same operators. */
    val previewRenderer: DevelopRenderer,
    /** The single thread that owns rendering. Must dispatch, not run inline. */
    val renderDispatcher: CoroutineDispatcher,
    /** Where neighbouring presets are baked ahead of the ruler (never the render thread). */
    val prefetchDispatcher: CoroutineDispatcher,
    /**
     * A second render thread for frames of a moving control while a settled render occupies [renderDispatcher]
     * (RenderScheduler's interactive lane). null: one lane.
     */
    val interactiveRenderDispatcher: CoroutineDispatcher? = null,
    val exporter: ExportCoordinator<String, *>,
    val favourites: FavouritesStore,
    /** Debug builds show stubs for the unimplemented tools and accept the capture launch options. */
    val debugBuild: Boolean,
    /** Export tile edge: spatial operators keep float planes per tile, so tiles stay small. */
    val exportTileEdge: Int = 1024,
    val newImageSpec: (SourceRef) -> NewImageSpec = { NewImageSpec(displayName = "Lightly_${System.currentTimeMillis()}.jpg") },
    /**
     * Background › subject separation: the person matte for people, plus the class-agnostic subject model
     * once it is approved (docs/v1/android-vision-evaluation.md §5); pending when the build has neither.
     */
    val segmenter: com.lightlylabs.lightly.background.SubjectSegmenter = com.lightlylabs.lightly.background.PendingSubjectSegmenter,
    val segmenterModelRef: com.lightlylabs.lightly.session.ModelRef? = null,
    /** Portrait › Hair & Beard: the person matte of an image (null when this build has no person segmenter). */
    val personMatte: suspend (Rgba8Image) -> com.lightlylabs.lightly.background.FloatPlane? = { null },
    /** Background › monocular depth (DEFERRED: LiteRT runtime pending approval; model pending legal sign-off). */
    val depthEstimator: com.lightlylabs.lightly.background.DepthEstimator = com.lightlylabs.lightly.background.UnavailableDepthEstimator,
    val depthModelRef: com.lightlylabs.lightly.session.ModelRef? = null,
    /** Decodes an embedded depth image (PNG in core-background; JPEG needs the platform). */
    val depthImageDecoder: com.lightlylabs.lightly.background.DepthImageDecoder = com.lightlylabs.lightly.background.DepthImageDecoder.PNG_ONLY,
    /** EXIF orientation (1–8) of the original's bytes, to align embedded depth with the decoded photo. */
    val exifOrientation: (ByteArray) -> Int = { 1 },
    /** A bundled background photo by recipe id (`background.landscape_01` …), or null if this build has none. */
    val bundledBackground: (String) -> Rgba8Image? = { null },
    /** Debug builds only: an override of the Save-copy Background working resolution, for controlled comparisons. */
    val debugExportCapOverride: () -> Int? = { null },
    /** Test seam: runs at the start of every preview render (a deliberately slow preview in tests). No-op in the app. */
    val beforePreviewRender: () -> Unit = {},
    /** Test seam: awaited before a Selective Colour pick samples, so a test can hold a pick "still sampling". No-op in the app. */
    val beforePickSample: suspend () -> Unit = {},
    /**
     * Edit › Remove's model (LaMa), loaded on first use; null when this build does not carry it (release
     * gate "pending legal sign-off (training data: Places2)") or it cannot load: the approved failure state.
     */
    val inpainter: () -> Inpainter? = { null },
    /** Private storage for Remove patches (recipe derivedRef), so a recovered session keeps its fills; null = memory only. */
    val removePatchDirectory: java.io.File? = null,
    /** Preferences › Preferred border: which Border tab opens first when the photo has none (never applied). */
    val preferredBorder: () -> com.lightlylabs.lightly.prefs.PreferredBorder = { com.lightlylabs.lightly.prefs.PreferredBorder.NONE },
    /** The saved signatures and chosen logos (Watermark, Preferences › Saved signature). */
    val signatures: com.lightlylabs.lightly.signatures.SignatureStore = com.lightlylabs.lightly.signatures.SignatureStore(null),
    /** The bundled watermark fonts (assets/fonts); null assets = the default typeface (JVM tests). */
    val watermarkFonts: WatermarkFonts = WatermarkFonts(null),
    /** Called after each preview render with its milliseconds and whether it was the drag (global-only) render. */
    val onPreviewRendered: (millis: Double, globalOnly: Boolean) -> Unit = { _, _ -> },
)
