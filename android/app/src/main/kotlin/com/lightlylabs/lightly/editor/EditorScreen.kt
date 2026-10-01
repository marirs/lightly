package com.lightlylabs.lightly.editor

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.lightlylabs.lightly.render.image.Rgba8Image
import java.nio.ByteBuffer
import kotlin.math.roundToInt

/**
 * M2 editor shell: picker → preview → stepped Looks → Compare / Undo / Reset → Save copy.
 *
 * DEFERRED (M3/M4): adaptive layout (WindowSizeClass / FoldingFeature), haptic detents, the
 * dirty-session "Discard edits?" dialog, crossfade, full TalkBack wording, and thumbnails.
 */
@Composable
fun EditorScreen(viewModel: EditorViewModel) {
    val ui by viewModel.uiState.collectAsStateWithLifecycle()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) viewModel.openPhoto(uri.toString())
    }
    val pickPhoto = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }

    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        PhotoArea(ui, Modifier.fillMaxWidth().weight(1f), onHold = { held -> viewModel.setCompare(held) })

        when (val phase = ui.phase) {
            EditorPhase.Empty -> Button(onClick = pickPhoto) { Text("Choose a photo") }
            EditorPhase.Loading -> Text("Opening photo…")
            EditorPhase.Developing -> Text("Enhancing…")
            is EditorPhase.LoadFailed -> {
                Text(phase.message, color = MaterialTheme.colorScheme.error)
                Button(onClick = pickPhoto) { Text("Choose another") }
            }
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
    when (val status = ui.autoStatus) {
        is AutoStatus.Unavailable -> Text(status.notice, color = MaterialTheme.colorScheme.error)
        AutoStatus.UsingOriginal -> Text(AutoStatus.UsingOriginal.NOTICE, color = MaterialTheme.colorScheme.error)
        else -> Unit
    }
    ui.lookNotice?.let { Text(it, color = MaterialTheme.colorScheme.error) }

    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        viewModel.categories.forEach { category ->
            FilterChip(selected = category == ui.selectedCategory, onClick = { viewModel.selectCategory(category) }, label = { Text(category) })
        }
    }

    SteppedLookSlider(
        stopNames = listOf("Auto") + viewModel.stopNames(ui.selectedCategory),
        settledStop = viewModel.stopIndex,
        category = ui.selectedCategory,
        onMove = viewModel::onStopChanged,
        onSettle = viewModel::onStopSettled,
    )

    session.current.look?.let { activeLook ->
        StrengthSlider(committed = activeLook.strength, onPreview = viewModel::previewLookStrength, onCommit = viewModel::commitLookStrength)
    }

    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = viewModel::undo, enabled = session.canUndo) { Text("Undo") }
        OutlinedButton(onClick = viewModel::redo, enabled = session.canRedo) { Text("Redo") }
        OutlinedButton(onClick = viewModel::resetToAuto, enabled = session.current.look != null) { Text("Reset") }
        FilterChip(selected = ui.compareOn, onClick = { viewModel.setCompare(!ui.compareOn) }, label = { Text("Compare") })
        Button(onClick = { viewModel.saveCopy() }, enabled = ui.save != SaveStatus.Saving) { Text("Save copy") }
        OutlinedButton(onClick = pickPhoto) { Text("Other photo") }
    }
    when (val save = ui.save) {
        SaveStatus.Saving -> Text("Saving…")
        is SaveStatus.Saved -> Text("Saved as a new photo. Original unchanged.")
        is SaveStatus.Failed -> Text("Couldn't save: ${save.message}", color = MaterialTheme.colorScheme.error)
        else -> Unit
    }
}

@Composable
private fun PhotoArea(ui: EditorUiState, modifier: Modifier, onHold: (Boolean) -> Unit) {
    val description = when {
        ui.displayed == null -> "No photo"
        ui.compareOn -> "Photo, original"
        else -> {
            val base = if (ui.autoStatus is AutoStatus.Applied) "Photo, enhanced automatically" else "Photo, auto enhancement unavailable"
            ui.displayed?.look?.let { "$base, ${it.lookId} at ${(it.strength * 100).roundToInt()} percent" } ?: base
        }
    }
    val bitmap = remember(ui.preview) { ui.preview?.toBitmap()?.asImageBitmap() }
    Box(
        modifier
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .semantics { contentDescription = description }
            // Press and hold shows the Original (spec §2.6); the Compare chip is the non-hold alternative.
            .pointerInput(Unit) { detectTapGestures(onPress = { onHold(true); tryAwaitRelease(); onHold(false) }) },
        contentAlignment = Alignment.Center,
    ) {
        if (bitmap != null) Image(bitmap, contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
        else Text(if (ui.displayed == null && ui.phase == EditorPhase.Empty) "No photo" else "")
    }
}

@Composable
private fun SteppedLookSlider(stopNames: List<String>, settledStop: Int, category: String, onMove: (Int) -> Unit, onSettle: (Int) -> Unit) {
    var position by remember(settledStop, category) { mutableFloatStateOf(settledStop.toFloat()) }
    val current = position.roundToInt().coerceIn(0, stopNames.lastIndex)
    Column {
        Text(stopNames[current])
        Slider(
            value = position,
            onValueChange = { value ->
                val before = position.roundToInt()
                position = value
                if (value.roundToInt() != before) onMove(value.roundToInt())
            },
            onValueChangeFinished = { onSettle(position.roundToInt()) },
            valueRange = 0f..stopNames.lastIndex.toFloat(),
            steps = (stopNames.size - 2).coerceAtLeast(0),
            modifier = Modifier.semantics { stateDescription = "$category, ${stopNames[current]}, ${current + 1} of ${stopNames.size}" },
        )
    }
}

@Composable
private fun StrengthSlider(committed: Float, onPreview: (Float) -> Unit, onCommit: (Float) -> Unit) {
    var dragging by remember(committed) { mutableFloatStateOf(committed) }
    Column {
        Text("Strength ${(dragging * 100).roundToInt()}%")
        Slider(
            value = dragging,
            onValueChange = { value -> dragging = value; onPreview(value) },
            onValueChangeFinished = { onCommit(dragging) },
        )
    }
}

private fun Rgba8Image.toBitmap(): Bitmap =
    Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { it.copyPixelsFromBuffer(ByteBuffer.wrap(pixels)) }
