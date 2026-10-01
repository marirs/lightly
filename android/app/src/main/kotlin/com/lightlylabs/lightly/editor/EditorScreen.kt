package com.lightlylabs.lightly.editor

import androidx.compose.foundation.background
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.lightlylabs.lightly.session.AutoGuardrail
import com.lightlylabs.lightly.session.AutoResult
import com.lightlylabs.lightly.session.LookRef
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef

/**
 * M2 UI shell. It exercises the session wiring (commit, preview, undo/redo/reset, compare,
 * category) and nothing else.
 *
 * DEFERRED (M3): photo picker, proxy decode, GL preview, real Looks from the look-book, Save copy,
 * adaptive layout (WindowSizeClass / FoldingFeature), stepped-slider haptics and full a11y. The
 * photo area is a text placeholder and the session is started from hard-coded demo values.
 */
@Composable
fun EditorScreen(viewModel: EditorViewModel) {
    val ui by viewModel.uiState.collectAsStateWithLifecycle()
    val session = ui.session

    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        PhotoPlaceholder(ui, Modifier.fillMaxWidth().weight(1f))

        (ui.autoStatus as? AutoStatus.Unavailable)?.let { unavailable ->
            // Visible text (read by TalkBack); Auto renders as identity meanwhile.
            Text(unavailable.notice, color = MaterialTheme.colorScheme.error)
        }

        if (session == null) {
            Button(onClick = { viewModel.startSession(DemoSession.source, DemoSession.auto) }) {
                Text("Start demo session")
            }
            return@Column
        }

        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            DemoSession.categories.keys.forEach { category ->
                FilterChip(
                    selected = category == ui.selectedCategory,
                    onClick = { viewModel.selectCategory(category) },
                    label = { Text(category) },
                )
            }
        }

        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { viewModel.commitLook(null) }) { Text("Auto") }
            DemoSession.categories.getValue(ui.selectedCategory).forEach { look ->
                OutlinedButton(onClick = { viewModel.commitLook(look) }) { Text(look.lookId.substringAfter('.')) }
            }
        }

        session.current.look?.let { activeLook ->
            StrengthSlider(
                committed = activeLook.strength,
                onPreview = { value -> viewModel.previewLook(activeLook.copy(strength = value)) },
                onCommit = viewModel::commitLookStrength,
            )
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = viewModel::undo, enabled = session.canUndo) { Text("Undo") }
            OutlinedButton(onClick = viewModel::redo, enabled = session.canRedo) { Text("Redo") }
            OutlinedButton(onClick = viewModel::resetToAuto, enabled = session.current.look != null) { Text("Reset") }
            FilterChip(selected = ui.compareOn, onClick = { viewModel.setCompare(!ui.compareOn) }, label = { Text("Compare") })
        }
    }
}

@Composable
private fun PhotoPlaceholder(ui: EditorUiState, modifier: Modifier) {
    val displayed = ui.displayed
    val description = when {
        displayed == null -> "No photo"
        ui.compareOn -> "Photo, original"
        else -> {
            val base = if (ui.autoStatus is AutoStatus.Unavailable) "Photo, auto enhancement unavailable" else "Photo, enhanced automatically"
            displayed.look?.let { "$base, ${it.lookId} at ${(it.strength * 100).toInt()} percent" } ?: base
        }
    }
    Box(
        modifier.background(MaterialTheme.colorScheme.surfaceVariant).semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Text(if (displayed == null) "No photo" else "$description\nrevision ${displayed.revision}")
    }
}

@Composable
private fun StrengthSlider(committed: Float, onPreview: (Float) -> Unit, onCommit: (Float) -> Unit) {
    var dragging by remember(committed) { mutableFloatStateOf(committed) }
    Column {
        Text("Strength ${(dragging * 100).toInt()}%")
        Slider(
            value = dragging,
            onValueChange = { value ->
                dragging = value
                onPreview(value)
            },
            onValueChangeFinished = { onCommit(dragging) },
        )
    }
}

/** Hard-coded stand-ins until the picker, model and look-book are wired in M3. */
private object DemoSession {
    val source = SourceRef(
        assetId = "demo://placeholder",
        fingerprint = SourceFingerprint(headSha256 = "0".repeat(64), byteSize = 1, pixelWidth = 4032, pixelHeight = 3024),
        orientation = 1,
    )
    val auto = AutoResult(
        modelId = AutoResult.MODEL_ID_IA3DLUT,
        modelVersion = "demo",
        weights = listOf(1f, 0f, 0f),
        guardrail = AutoGuardrail.ENDPOINT_V1,
        strength = 0.75f,
    )
    val categories: Map<String, List<LookRef>> = linkedMapOf(
        "Natural" to listOf(LookRef("natural.soft", 1, 1f), LookRef("natural.crisp", 1, 1f)),
        "Warm" to listOf(LookRef("warm.golden", 1, 1f), LookRef("warm.amber", 1, 1f)),
        "Cool" to listOf(LookRef("cool.nordic", 1, 1f)),
        "Film" to listOf(LookRef("film.portra", 1, 1f), LookRef("film.gold", 1, 1f)),
        "Mono" to listOf(LookRef("mono.silver", 1, 1f)),
    )
}
