package com.lightlylabs.lightly.editor

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.systemGestureExclusion
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.LookRef
import java.nio.ByteBuffer
import kotlin.math.roundToInt

/** A WindowManager FoldingFeature in window pixels; converted to the editor's own dp by the screen. */
data class WindowHinge(val boundsInWindowPx: Rect, val isVertical: Boolean, val separatesContent: Boolean)

/** Test tags for the Compose UI tests. */
object EditorTags {
    const val PHOTO = "editor-photo"
    const val PANEL = "editor-panel"
    const val ORIGINAL_INDICATOR = "editor-original-indicator"
    const val STOP_CAPTION = "editor-stop-caption"
    const val STRENGTH = "editor-strength"
    const val SAVE_COPY = "editor-save-copy"
    const val NOTICES = "editor-notices"
}

/**
 * Photo-first editor (spec §6): picker → preview → categories and stepped Looks → Strength →
 * Undo / Redo / Compare / Reset → Save copy. Placement comes from [EditorLayoutPolicy]: panel below
 * the photo on a compact portrait window, beside it otherwise, and never across a separating hinge.
 *
 * DEFERRED (M3/M4): the dirty-session "Discard edits?" dialog, crossfade, thumbnails, stop names
 * under every marker when they fit (only the current name is shown today), full TalkBack wording.
 */
@Composable
fun EditorScreen(viewModel: EditorViewModel, hinges: List<WindowHinge> = emptyList()) {
    val ui by viewModel.uiState.collectAsStateWithLifecycle()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        // openPhoto persists the read grant synchronously, while the picker's temporary grant is valid.
        if (uri != null) viewModel.openPhoto(uri.toString())
    }
    val pickPhoto = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
    EditorContent(ui, viewModel, hinges, pickPhoto)
}

/** The screen without the picker launcher, so Robolectric UI tests can drive it directly. */
@Composable
fun EditorContent(ui: EditorUiState, viewModel: EditorViewModel, hinges: List<WindowHinge>, pickPhoto: () -> Unit) {
    var originInWindow by remember { mutableStateOf(Offset.Zero) }
    val density = LocalDensity.current
    // targetSdk 36 is edge-to-edge: without the safe-drawing insets the photo sits under the status
    // bar and the bottom row under the gesture handle (seen on the API 36 emulator).
    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .onGloballyPositioned { originInWindow = it.positionInWindow() }
            // Test tags double as resource IDs so the scripted emulator run (uiautomator) can find
            // the photo, the slider markers and Save copy without pixel coordinates.
            .semantics { testTagsAsResourceId = true },
    ) {
        val hinge = hinges.firstOrNull()?.toEditorHinge(originInWindow, density)
        // The preview is decoded upright (EXIF applied), so its shape is the photo's displayed shape.
        val photoAspectRatio = ui.preview?.let { it.width.toFloat() / it.height }
        val layout = EditorLayoutPolicy.decide(maxWidth.value, maxHeight.value, density.fontScale, hinge, photoAspectRatio)
        val availableHeight = maxHeight
        val panelScroll = rememberScrollState()
        val photo: @Composable (Modifier) -> Unit = { modifier -> PhotoArea(ui, modifier, viewModel::describeLook, viewModel::holdCompare) }
        val panel: @Composable (Modifier) -> Unit = { modifier -> EditorPanel(ui, viewModel, pickPhoto, modifier, panelScroll) }
        when (layout) {
            is EditorLayout.Stacked -> Column(Modifier.fillMaxSize()) {
                photo(Modifier.fillMaxWidth().weight(1f))
                panel(Modifier.fillMaxWidth().heightIn(max = availableHeight * layout.panelMaxHeightFraction))
            }
            is EditorLayout.SideBySide -> Row(Modifier.fillMaxSize()) {
                val photoWidth = layout.photoWidthDp
                photo(if (photoWidth != null) Modifier.width(photoWidth.dp).fillMaxHeight() else Modifier.weight(1f).fillMaxHeight())
                if (layout.hingeGapDp > 0f) Spacer(Modifier.width(layout.hingeGapDp.dp))
                panel(Modifier.width(layout.panelWidthDp.dp).fillMaxHeight())
            }
            is EditorLayout.AboveHinge -> Column(Modifier.fillMaxSize()) {
                photo(Modifier.fillMaxWidth().height(layout.photoHeightDp.dp))
                Spacer(Modifier.height(layout.hingeGapDp.dp))
                panel(Modifier.fillMaxWidth().weight(1f))
            }
        }
    }
}

private fun WindowHinge.toEditorHinge(originInWindow: Offset, density: Density): EditorHinge = with(density) {
    EditorHinge(
        leftDp = (boundsInWindowPx.left - originInWindow.x).toDp().value,
        topDp = (boundsInWindowPx.top - originInWindow.y).toDp().value,
        rightDp = (boundsInWindowPx.right - originInWindow.x).toDp().value,
        bottomDp = (boundsInWindowPx.bottom - originInWindow.y).toDp().value,
        isVertical = isVertical,
        separatesContent = separatesContent,
    )
}

/**
 * The controls: a scrolling area, then Save copy pinned below it. Save copy sits outside the scroll
 * so it is visible without scrolling in every layout and state; in the scrolling panel a Strength
 * slider or an extra notice pushed it below the visible panel (d5690dd review screenshot). The
 * scrolling part takes only what is left (weight, fill = false), so a short panel still wraps.
 */
@Composable
private fun EditorPanel(ui: EditorUiState, viewModel: EditorViewModel, pickPhoto: () -> Unit, modifier: Modifier, scroll: ScrollState) {
    Column(modifier.testTag(EditorTags.PANEL)) {
        ScrollingControls(ui, viewModel, pickPhoto, Modifier.weight(1f, fill = false), scroll)
        if (ui.phase == EditorPhase.Ready && ui.session != null) SaveCopyButton(ui, viewModel)
    }
}

/** The one prominent action: full width, filled, never scrolled away. */
@Composable
private fun SaveCopyButton(ui: EditorUiState, viewModel: EditorViewModel) {
    Button(
        onClick = { viewModel.saveCopy() },
        enabled = ui.save != SaveStatus.Saving,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 12.dp).testTag(EditorTags.SAVE_COPY),
    ) { Text("Save copy") }
}

@Composable
private fun ScrollingControls(ui: EditorUiState, viewModel: EditorViewModel, pickPhoto: () -> Unit, modifier: Modifier, scroll: ScrollState) {
    Column(
        modifier.verticalScroll(scroll).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        when (val phase = ui.phase) {
            EditorPhase.Empty -> {
                Text("Choose a photo to start editing. Your original is never changed.", style = MaterialTheme.typography.bodyMedium)
                Button(onClick = pickPhoto, modifier = Modifier.fillMaxWidth()) { Text("Choose a photo") }
            }
            EditorPhase.Loading -> Text("Opening photo…")
            EditorPhase.Developing -> Text("Enhancing…")
            is EditorPhase.LoadFailed -> {
                Text(phase.message, color = MaterialTheme.colorScheme.error)
                Button(onClick = pickPhoto) { Text("Choose another") }
            }
            EditorPhase.PhotoAccessLost -> {
                Text("Lightly can no longer open this photo. Choose it again to keep editing.", color = MaterialTheme.colorScheme.error)
                Button(onClick = pickPhoto) { Text("Choose the photo again") }
            }
            // Only a genuine Auto failure offers Retry; a build without a model goes straight to Ready.
            is EditorPhase.DevelopFailed -> {
                Text("Couldn't enhance. ${phase.message}", color = MaterialTheme.colorScheme.error)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = viewModel::retryDevelop) { Text("Retry") }
                    Button(onClick = viewModel::useOriginal) { Text("Continue with original") }
                }
            }
            EditorPhase.Ready -> ReadyControls(ui, viewModel, pickPhoto)
        }
    }
}

@Composable
private fun ReadyControls(ui: EditorUiState, viewModel: EditorViewModel, pickPhoto: () -> Unit) {
    val session = ui.session ?: return
    StatusNotices(ui, viewModel)

    val selectedCategory = viewModel.categories.firstOrNull { it.id == ui.selectedCategory }
    if (selectedCategory == null) {
        // The build was made without a Look pack, or its manifest was unusable (LookPackLoader).
        Text(LookBook.NO_LOOKS_NOTICE, style = MaterialTheme.typography.bodySmall)
    } else {
        LookControls(ui, viewModel, selectedCategory)
    }

    EditActions(ui, viewModel, canUndo = session.canUndo, canRedo = session.canRedo)

    // Save copy is pinned below this scrolling area (EditorPanel); the secondary action scrolls.
    TextButton(onClick = pickPhoto) { Text("Choose another photo") }
}

/**
 * Short, small notices in one place: a Look that does not render (with its one action), why Auto
 * is off, the pack's approximation status, and the save result.
 */
@Composable
private fun StatusNotices(ui: EditorUiState, viewModel: EditorViewModel) {
    val autoNotice = when (val status = ui.autoStatus) {
        is AutoStatus.Unavailable -> status.notice
        AutoStatus.UsingOriginal -> AutoStatus.UsingOriginal.NOTICE
        AutoStatus.NoModelInThisBuild -> AutoStatus.NoModelInThisBuild.NOTICE
        else -> null
    }
    val saveLine: Pair<String, Boolean>? = when (val save = ui.save) {
        SaveStatus.Saving -> "Saving…" to false
        is SaveStatus.Saved -> "Saved as a new photo. Original unchanged." to false
        is SaveStatus.Failed -> "Couldn't save: ${save.message}" to true
        else -> null
    }
    val approximation = viewModel.lookApproximationNotice
    if (autoNotice == null && ui.lookIssue == null && approximation == null && saveLine == null) return
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth().testTag(EditorTags.NOTICES),
    ) {
        Column(Modifier.padding(horizontal = 10.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            ui.lookIssue?.let { issue ->
                Text(issue.notice, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                if (issue.offersCurrentVersion) TextButton(onClick = viewModel::useCurrentLookVersion) { Text(LookIssue.USE_CURRENT_VERSION) }
            }
            autoNotice?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
            approximation?.let { Text(it, style = MaterialTheme.typography.labelSmall) }
            saveLine?.let { (text, isError) ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                        // Spec §5.4: success is announced politely, failure assertively.
                        modifier = Modifier.weight(1f).semantics { liveRegion = if (isError) LiveRegionMode.Assertive else LiveRegionMode.Polite },
                    )
                    if (ui.save == SaveStatus.Saving) TextButton(onClick = viewModel::cancelSave) { Text("Cancel") }
                }
            }
        }
    }
}

@Composable
private fun LookControls(ui: EditorUiState, viewModel: EditorViewModel, selectedCategory: LookCategory) {
    // Labels come from the pack and are provisional; the chip is keyed by the opaque category id.
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        viewModel.categories.forEach { category ->
            FilterChip(selected = category.id == selectedCategory.id, onClick = { viewModel.selectCategory(category.id) }, label = { Text(category.label) })
        }
    }

    // "Nordic Tone (10) · 3 of 5": the name wraps rather than clipping at large text (spec §6).
    Text(viewModel.stopCaption(selectedCategory.id), style = MaterialTheme.typography.titleMedium, modifier = Modifier.testTag(EditorTags.STOP_CAPTION))
    SteppedLookSlider(
        stopNames = viewModel.sliderStopNames(selectedCategory.id),
        selectedStop = viewModel.stopIndex,
        categoryLabel = selectedCategory.label,
        onMove = viewModel::onStopChanged,
        onSettle = viewModel::onStopSettled,
    )

    // Secondary: only for a committed Look that renders.
    val activeLook = ui.session?.current?.look
    if (activeLook != null && viewModel.showsStrength) {
        StrengthSlider(committed = activeLook.strength, onPreview = viewModel::previewLookStrength, onCommit = viewModel::commitLookStrength)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun EditActions(ui: EditorUiState, viewModel: EditorViewModel, canUndo: Boolean, canRedo: Boolean) {
    // Wraps instead of scrolling: in one scrolling row an action was off screen on a phone.
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = viewModel::undo, enabled = canUndo) { Text("Undo") }
        OutlinedButton(onClick = viewModel::redo, enabled = canRedo) { Text("Redo") }
        FilterChip(selected = ui.compareOn, onClick = { viewModel.setCompare(!ui.compareOn) }, label = { Text("Compare") })
        OutlinedButton(onClick = viewModel::resetToAuto, enabled = viewModel.canReset) { Text("Reset") }
    }
}

@Composable
private fun PhotoArea(ui: EditorUiState, modifier: Modifier, describeLook: (LookRef) -> String, onHold: (Boolean) -> Unit) {
    val description = when {
        // Before a session exists (Loading / DevelopFailed) the preview already shows the Original.
        ui.displayed == null && ui.preview != null -> "Photo, original"
        ui.displayed == null -> "No photo"
        ui.showsOriginal -> "Photo, original"
        else -> {
            val base = if (ui.autoStatus is AutoStatus.Applied) "Photo, enhanced automatically" else "Photo, auto enhancement unavailable"
            // A Look that does not render is not described as applied.
            ui.displayed?.look?.takeIf { ui.lookIssue == null }?.let { "$base, ${describeLook(it)}" } ?: base
        }
    }
    val bitmap = remember(ui.preview) { ui.preview?.toBitmap()?.asImageBitmap() }
    Box(
        modifier
            .testTag(EditorTags.PHOTO)
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .semantics { contentDescription = description }
            // Press and hold shows the Original (spec §2.6); the Compare chip is the non-hold toggle.
            .pointerInput(Unit) { detectTapGestures(onPress = { onHold(true); tryAwaitRelease(); onHold(false) }) },
        contentAlignment = Alignment.Center,
    ) {
        if (bitmap != null) Image(bitmap, contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
        else Text(if (ui.phase == EditorPhase.Empty) "No photo" else "")
        if (ui.showsOriginal && ui.session != null) {
            // On the photo itself, so the Original is never mistaken for the edit (spec §2.6).
            Surface(
                color = MaterialTheme.colorScheme.inverseSurface,
                contentColor = MaterialTheme.colorScheme.inverseOnSurface,
                shape = RoundedCornerShape(50),
                modifier = Modifier.align(Alignment.TopStart).padding(12.dp).testTag(EditorTags.ORIGINAL_INDICATOR),
            ) { Text("Original", style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) }
        }
    }
}

@Composable
private fun StrengthSlider(committed: Float, onPreview: (Float) -> Unit, onCommit: (Float) -> Unit) {
    var dragging by remember(committed) { mutableFloatStateOf(committed) }
    Column(Modifier.testTag(EditorTags.STRENGTH)) {
        Text("Strength ${(dragging * 100).roundToInt()}%", style = MaterialTheme.typography.labelMedium)
        Slider(
            value = dragging,
            onValueChange = { value -> dragging = value; onPreview(value) },
            // Release commits exactly one step (spec §3).
            onValueChangeFinished = { onCommit(dragging) },
            modifier = Modifier.systemGestureExclusion(),
        )
    }
}

private fun Rgba8Image.toBitmap(): Bitmap =
    Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { it.copyPixelsFromBuffer(ByteBuffer.wrap(pixels)) }
