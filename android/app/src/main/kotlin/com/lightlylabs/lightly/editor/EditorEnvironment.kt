package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.FullResolutionSource
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.model.AutoLutResolver
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.LutPassRenderer
import com.lightlylabs.lightly.session.AutoResult
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef
import kotlinx.coroutines.CoroutineDispatcher

/** A picked photo, decoded twice (spec §3, §4.6): once for analysis, once for display. */
class LoadedPhoto(
    val source: SourceRef,
    /** Long edge 1024 (or the Original if smaller): model input only. */
    val analysis: Rgba8Image,
    /** Display proxy: preview render input only. */
    val display: Rgba8Image,
    /** Full-resolution decode for Save copy, run only when exporting. */
    val fullResolution: FullResolutionSource,
)

fun interface PhotoLoader {
    /**
     * @throws PhotoAccessLostException when the photo can no longer be read (grant gone, item deleted).
     * @throws Exception with a user-presentable message for any other failure (LoadFailed).
     */
    suspend fun load(assetId: String): LoadedPhoto
}

sealed interface DevelopResult {
    data class Developed(val auto: AutoResult) : DevelopResult

    /** The model ran (or tried to) and produced no Auto result: DevelopFailed with Retry (spec §5.1). */
    data class Failed(val message: String) : DevelopResult

    /**
     * This build ships no Auto model. Nothing failed and Retry can never succeed, so the editor goes
     * straight to Ready with Auto off and a notice, like iOS's "model not bundled" Auto.
     */
    data object NoModelInThisBuild : DevelopResult
}

fun interface AutoDeveloper {
    suspend fun develop(fingerprint: SourceFingerprint, analysis: Rgba8Image): DevelopResult
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
    val autoResolver: AutoLutResolver,
    val lookBook: LookBook,
    /** Preview renderer, run on [renderDispatcher]. */
    val previewRenderer: LutPassRenderer,
    /** The single thread that owns rendering (GL context in production). Must dispatch, not run inline. */
    val renderDispatcher: CoroutineDispatcher,
    val exporter: ExportCoordinator<String, *>,
    val newImageSpec: (SourceRef) -> NewImageSpec = { NewImageSpec(displayName = "Lightly_${System.currentTimeMillis()}.jpg") },
)
