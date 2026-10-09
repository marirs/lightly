package com.lightlylabs.lightly.editor

import androidx.compose.foundation.border
import androidx.compose.ui.graphics.luminance

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.Alignment
import androidx.compose.ui.layout.layout
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.shell.LightlyIcon
import com.lightlylabs.lightly.shell.LightlyIcons
import com.lightlylabs.lightly.shell.ShellLayout
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.lightlyTextStyle
import com.lightlylabs.lightly.shell.testTagResource
import java.nio.ByteBuffer

/** What the editor asks of the shell: ⋮ More, the system share sheet, the photo picker. */
class EditorActions(val more: () -> Unit, val share: (String) -> Unit, val chooseAnother: () -> Unit)

/** Stable tags for tests and the scripted emulator comparison. */
object EditorTags {
    const val CLOSE = "editor-close"
    const val UNDO = "editor-undo"
    const val REDO = "editor-redo"
    const val COMPARE = "editor-compare"
    const val SAVE = "editor-save"
    const val MORE = "editor-more"
    const val STAGE = "editor-stage"
    const val RULER = "develop-ruler"
    const val STAR = "develop-star"
    const val AMOUNT = "develop-amount"
    const val AUTO = "develop-auto"
    fun tool(tool: EditorTool) = "tool-${tool.name.lowercase()}"
    fun category(id: String) = "category-$id"
}

/**
 * The approved editor (prototype `editorHTML`) in every layout mode, or the approved "Opening photo…"
 * screen while the session starts.
 */
@Composable
fun EditorScreen(vm: EditorViewModel, shellLayout: ShellLayout, actions: EditorActions) {
    val ui by vm.uiState.collectAsStateWithLifecycle()
    val favourites by vm.favourites.collectAsStateWithLifecycle()
    KeepScreenOnWhileWorking(ui)
    val colors = lightlyColors
    BoxWithConstraints(Modifier.fillMaxSize().background(colors.bg)) {
        val layout = EditorLayout.decide(shellLayout, maxWidth.value, maxHeight.value)
        val insets = WindowInsets.safeDrawing.asPaddingValues()
        val direction = LocalLayoutDirection.current
        val frame = EditorFrame(
            layout = layout,
            top = insets.calculateTopPadding(),
            bottom = insets.calculateBottomPadding(),
            start = insets.calculateLeftPadding(direction),
            end = insets.calculateRightPadding(direction),
            foldDp = when (shellLayout) {
                is ShellLayout.SplitVertical -> shellLayout.foldXDp
                is ShellLayout.SplitHorizontal -> shellLayout.foldYDp
                else -> null
            },
        )
        when (ui.phase) {
            EditorPhase.Ready -> {
                val model = vm.panelModel(ui, favourites)
                EditorContent(vm, ui, model, frame, actions)
                EditorOverlays(vm, ui, model, frame, favourites, actions)
            }
            EditorPhase.Developing -> LoadingScreen(vm, ui, frame, developing = true)
            else -> LoadingScreen(vm, ui, frame, developing = false)
        }
    }
}

/** The window's layout plus its system insets and the fold position (dp from the window's top/left). */
data class EditorFrame(val layout: EditorLayout, val top: Dp, val bottom: Dp, val start: Dp, val end: Dp, val foldDp: Float?)

@Composable
private fun EditorContent(vm: EditorViewModel, ui: EditorUiState, model: DevelopPanelModel?, frame: EditorFrame, actions: EditorActions) {
    val layout = frame.layout
    val stage: @Composable (Modifier) -> Unit = { modifier -> Stage(ui, modifier, overlay = { BackgroundMarks(vm, ui); PortraitMarks(vm, ui); EditMarks(vm, ui) }, chrome = { if (!ui.showsOriginal) AutoEnhanceOverlay(vm, ui) }, inspection = true, onPhotoBox = vm::onStagePhotoMeasured) }
    val panel: @Composable (roomy: Boolean, wrapped: Boolean) -> Unit = { roomy, wrapped -> ToolPanel(vm, ui, model, roomy, wrapped) }
    val tools: @Composable (kind: DockKind) -> Unit = { kind -> ToolNav(vm, ui, kind) }
    Box(Modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize().padding(start = frame.start, end = frame.end)) {
        when (layout.mode) {
            EditorMode.BELOW, EditorMode.WIDE -> {
                Spacer(Modifier.height(frame.top))
                EditorTopBar(vm, ui, actions)
                stage(Modifier.weight(1f).fillMaxWidth())
                val wide = layout.mode == EditorMode.WIDE
                // The panel never takes more than its share of the height: it scrolls, so the photo stays dominant.
                val maxPanel = (if(ui.tool == EditorTool.DEVELOP) maxOf(350f, layout.heightDp * 0.34f) else layout.heightDp * if (wide) 0.3f else 0.34f).let { kotlin.math.round(it) }.dp
                Column(Modifier.fillMaxWidth()) {
                    Column(
                        Modifier
                            .align(Alignment.CenterHorizontally)
                            .then(if (wide) Modifier.widthIn(max = layout.contentWidthDp.dp).fillMaxWidth().padding(top = 4.dp) else Modifier.fillMaxWidth())
                            .heightIn(max = maxPanel)
                            .verticalScroll(rememberScrollState()),
                    ) { panel(false, wide) }
                    tools(if (wide) DockKind.FITS else DockKind.SCROLLS)
                    Spacer(Modifier.height(frame.bottom))
                }
            }
            EditorMode.SIDE -> {
                Spacer(Modifier.height(frame.top))
                EditorTopBar(vm, ui, actions)
                Row(Modifier.weight(1f).fillMaxWidth()) {
                    stage(Modifier.weight(1f).fillMaxHeight())
                    Column(
                        Modifier.width(layout.panelWidthDp.dp).fillMaxHeight().hairlineStart(lightlyColors.hair).verticalScroll(rememberScrollState()),
                    ) { panel(true, false) }
                    tools(DockKind.RAIL)
                }
                Spacer(Modifier.height(frame.bottom))
            }
            EditorMode.SPLIT_V -> {
                val half = ((frame.foldDp ?: (layout.widthDp / 2)) - frame.start.value).dp
                Spacer(Modifier.height(frame.top))
                // Top bar split at the fold: history and compare over the photo, Save copy and ⋮ over the panel.
                Row(Modifier.fillMaxWidth().height(48.dp), verticalAlignment = Alignment.CenterVertically) {
                    // Prototype: the left group is a plain row (no gap) of width half with 6 dp start padding.
                    Row(Modifier.width(half).padding(start = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        TopBarLeft(vm, ui)
                    }
                    Spacer(Modifier.weight(1f))
                    TopBarRight(vm, actions)
                }
                Row(Modifier.weight(1f).fillMaxWidth()) {
                    stage(Modifier.width(half).fillMaxHeight())
                    Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState())) { panel(true, false) }
                    tools(DockKind.RAIL)
                }
                Spacer(Modifier.height(frame.bottom))
            }
            EditorMode.SPLIT_H -> {
                // The whole upper half above the fold is photo; actions, controls and tools share the lower half.
                val fold = (frame.foldDp ?: (layout.heightDp / 2)).dp
                Column(Modifier.height(fold).fillMaxWidth()) {
                    Spacer(Modifier.height(frame.top))
                    stage(Modifier.weight(1f).fillMaxWidth())
                }
                Column(Modifier.weight(1f).fillMaxWidth().padding(top = 4.dp)) {
                    EditorTopBar(vm, ui, actions)
                    // Prototype `.panel.grow`: `.panel` (flex 0 0 auto) wins over `.grow`, so the panel is as
                    // tall as its content and the tools sit right under it; the rest of the pane stays empty.
                    Column(Modifier.fillMaxWidth().weight(1f, fill = false)) {
                        Column(
                            Modifier.align(Alignment.CenterHorizontally).widthIn(max = layout.contentWidthDp.dp).fillMaxWidth().weight(1f, fill = false).verticalScroll(rememberScrollState()),
                        ) { panel(false, false) }
                        tools(DockKind.FITS)
                    }
                    Spacer(Modifier.weight(0.001f))
                    Spacer(Modifier.height(frame.bottom))
                }
            }
        }
    }
    if(ui.tool == EditorTool.DEVELOP && ui.develop.expanded && model != null) {
        Column(Modifier.align(Alignment.BottomCenter).padding(bottom = 72.dp + frame.bottom).fillMaxWidth()
            .heightIn(max = (layout.heightDp - 140).dp).background(lightlyColors.bg, androidx.compose.foundation.shape.RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp))) {
            var handleDrag by remember { mutableStateOf(0f) }
            Box(Modifier.fillMaxWidth().height(24.dp).pointerInput(Unit) {
                detectDragGestures(onDragStart = { handleDrag = 0f }, onDragEnd = {
                    if (handleDrag > 30.dp.toPx()) vm.setPresetExpanded(false)
                }) { change, delta -> handleDrag += delta.y; change.consume() }
            }, contentAlignment = Alignment.Center) {
                Box(Modifier.width(34.dp).height(4.dp).background(lightlyColors.hair, CircleShape))
            }
            DevelopPanel(vm, model, false, false, expanded = true)
        }
    }
    }

}

// --- top bar ----------------------------------------------------------------------------------------

@Composable
private fun EditorTopBar(vm: EditorViewModel, ui: EditorUiState, actions: EditorActions) {
    Row(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        TopBarLeft(vm, ui)
        Spacer(Modifier.weight(1f))
        TopBarRight(vm, actions)
    }
}

@Composable
private fun TopBarLeft(vm: EditorViewModel, ui: EditorUiState) {
    // Android: the back arrow closes the editor (prototype closeIcon: backA, label "Back").
    BarIcon(LightlyIcons.BackArrow, "Back", vm::close, tag = EditorTags.CLOSE)
    BarIcon(LightlyIcons.Undo, "Undo", vm::undo, enabled = ui.canUndo, tag = EditorTags.UNDO)
    BarIcon(LightlyIcons.Redo, "Redo", vm::redo, enabled = ui.canRedo, tag = EditorTags.REDO)
    CompareButton(vm, ui)
}

@Composable
private fun TopBarRight(vm: EditorViewModel, actions: EditorActions) {
    val colors = lightlyColors
    // Compact 34 dp pill within the full 48 dp touch target (owner amendment 2026-10-08).
    Box(
        Modifier
            .padding(horizontal = 4.dp)
            .heightIn(min = 48.dp)
            .clickable(role = Role.Button, onClick = vm::saveCopy)
            .testTagResource(EditorTags.SAVE),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.heightIn(min = 34.dp).background(colors.ink, CircleShape)
                .padding(horizontal = 14.dp, vertical = 6.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text("Save copy", style = lightlyTextStyle(14.sp, FontWeight.SemiBold, colors.bg), maxLines = 1)
        }
    }
    BarIcon(LightlyIcons.More, "More", actions.more, tag = EditorTags.MORE)
}

/** `.ib`: 44 dp, radius 10; disabled icons are ink3. */
@Composable
private fun BarIcon(icon: ImageVector, description: String, onClick: () -> Unit, enabled: Boolean = true, tag: String) {
    val colors = lightlyColors
    Box(
        Modifier
            .size(44.dp)
            .clip(RoundedCornerShape(10.dp))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description }
            .testTagResource(tag),
        contentAlignment = Alignment.Center,
    ) { LightlyIcon(icon, tint = if (enabled) colors.ink else colors.ink3) }
}

/**
 * Hold to compare: the original shows while a finger is down. For TalkBack and switch access the same
 * button is a toggle (double-tap shows the original until double-tapped again).
 */
@Composable
private fun CompareButton(vm: EditorViewModel, ui: EditorUiState) {
    val colors = lightlyColors
    Box(
        Modifier
            .size(44.dp)
            .clip(RoundedCornerShape(10.dp))
            .pointerInput(Unit) {
                awaitEachGesture {
                    awaitFirstDown()
                    vm.holdCompare(true)
                    waitForUpOrCancellation()
                    vm.holdCompare(false)
                }
            }
            .semantics {
                contentDescription = "Hold to compare with the original"
                role = Role.Switch
                stateDescription = if (ui.compareToggled) "Showing the original" else "Showing your edit"
                onClick(label = "Toggle the original") { vm.toggleCompare(); true }
            }
            .testTagResource(EditorTags.COMPARE),
        contentAlignment = Alignment.Center,
    ) { LightlyIcon(LightlyIcons.Compare, tint = if (ui.showsOriginal) colors.sel else colors.ink) }
}

// --- photo stage ------------------------------------------------------------------------------------

/** Rgba8Image bytes are ARGB_8888's memory order (R, G, B, A), so they copy straight into a Bitmap. */
internal fun Rgba8Image.toBitmap(): Bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { it.copyPixelsFromBuffer(ByteBuffer.wrap(pixels)) }

/**
 * `.stage`: the canvas colour, the photo contain-fitted (never cropped). With Compare, the original and
 * the "Original" badge at the photo's top-left corner.
 */
@Composable
private fun Stage(ui: EditorUiState, modifier: Modifier, overlay: @Composable () -> Unit = {}, chrome: @Composable () -> Unit = {}, inspection: Boolean = false, onPhotoBox: (shortDp: Float, longDp: Float) -> Unit = { _, _ -> }) {
    val colors = lightlyColors
    val image = if (ui.showsOriginal) ui.original else ui.preview ?: ui.original
    BoxWithConstraints(modifier.background(colors.canvas).clipToBounds().testTagResource(EditorTags.STAGE), contentAlignment = Alignment.Center) {
        if (image != null) {
            val bitmap = remember(image) { image.toBitmap().asImageBitmap() }
            val ratio = image.width.toFloat() / image.height
            val width = minOf(maxWidth.value, maxHeight.value * ratio)
            val density = LocalDensity.current
            val viewport = with(density) { Offset(maxWidth.toPx(), maxHeight.toPx()) }
            val fitted = with(density) { Offset(width.dp.toPx(), (width / ratio).dp.toPx()) }
            var zoom by remember(ui.original) { mutableStateOf(1f) }
            var pan by remember(ui.original) { mutableStateOf(Offset.Zero) }
            fun clamp(offset: Offset, scale: Float): Offset {
                val limitX = maxOf(0f, (fitted.x * scale - viewport.x) / 2)
                val limitY = maxOf(0f, (fitted.y * scale - viewport.y) / 2)
                return Offset(offset.x.coerceIn(-limitX, limitX), offset.y.coerceIn(-limitY, limitY))
            }
            LaunchedEffect(viewport, fitted) { pan = clamp(pan, zoom) }
            val gestures = if (!inspection) Modifier else Modifier
                .pointerInput(ui.original, viewport, fitted) {
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                        var navigating = false
                        do {
                            val event = awaitPointerEvent(PointerEventPass.Initial)
                            if (event.changes.count { it.pressed } >= 2) {
                                navigating = true
                                val next = (zoom * event.calculateZoom()).coerceIn(1f, 6f)
                                val anchor = event.calculateCentroid(useCurrent = false) - viewport / 2f
                                pan = clamp(anchor - (anchor - pan) * (next / zoom) + event.calculatePan(), next)
                                zoom = next
                            }
                            // Continue consuming until every finger is lifted: do not turn the last
                            // finger of a pinch into a brush stroke or a watermark drag.
                            if (navigating) event.changes.forEach { it.consume() }
                        } while (event.changes.any { it.pressed })
                    }
                }
                .pointerInput(ui.original, viewport, fitted) {
                    detectTapGestures(onDoubleTap = { point ->
                        if (zoom > 1.01f) { zoom = 1f; pan = Offset.Zero }
                        else { zoom = 2.5f; pan = clamp((viewport / 2f - point) * (zoom - 1f), zoom) }
                    })
                }
            val border = ui.session?.current?.let { EditMapping.border(it) }?.takeIf { !it.isNone && !ui.showsOriginal && ui.preview != null }
            Box(Modifier.fillMaxSize().then(gestures).testTagResource("editor-inspection").semantics {
                stateDescription = "${(zoom * 100).toInt()} percent zoom"
            }, contentAlignment = Alignment.Center) {
            // Stage 11: with a border the preview is the canvas. `.pic` then has box-shadow 0 0 0 1px
            // rgba(0,0,0,.12), a ring just outside it (not while comparing: the original has no border).
            Box(
                Modifier.size(width.dp, (width / ratio).dp).graphicsLayer {
                    scaleX = zoom; scaleY = zoom; translationX = pan.x; translationY = pan.y
                }.then(
                    if (border == null) Modifier else Modifier.drawBehind {
                        val ring = 1.dp.toPx()
                        drawRect(Color(0x1F000000), topLeft = Offset(-ring / 2, -ring / 2), size = androidx.compose.ui.geometry.Size(size.width + ring, size.height + ring), style = androidx.compose.ui.graphics.drawscope.Stroke(ring))
                    },
                ),
            ) {
                Image(bitmap, contentDescription = if (ui.showsOriginal) "The original photo" else "Your photo with the edit", contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
                if (ui.showsOriginal) {
                    Text(
                        "Original",
                        // `.badge { font-size:12.5px }`: fixed, not scaled with the text size.
                        style = lightlyTextStyle(com.lightlylabs.lightly.shell.fixedTextSize(12.5f), FontWeight.SemiBold, Color.White),
                        modifier = Modifier.padding(10.dp).background(Color(0x8C000000), RoundedCornerShape(8.dp)).padding(horizontal = 9.dp, vertical = 3.dp),
                    )
                }
                // Marks and touches sit on the photo's box inside the border (prototype `.imgbox` in `.frame`).
                val box = border?.let { com.lightlylabs.lightly.develop.BorderStage.imageBox(it, image.width, image.height) }
                // The displayed photo box (inside the border), in dp: the on-screen basis of the watermark
                // and blur sizes (W1 and blur, PROVISIONAL). Not while comparing (the original is shown).
                if (!ui.showsOriginal && ui.preview != null) {
                    val photoW = width * (box?.get(2)?.toFloat() ?: 1f)
                    val photoH = (width / ratio) * (box?.get(3)?.toFloat() ?: 1f)
                    androidx.compose.runtime.SideEffect { onPhotoBox(minOf(photoW, photoH), maxOf(photoW, photoH)) }
                }
                if (box == null || ui.tool == EditorTool.WATERMARK) overlay() else BoxWithConstraints(Modifier.fillMaxSize()) {
                    Box(Modifier.offset(x = maxWidth * box[0].toFloat(), y = maxHeight * box[1].toFloat()).size(maxWidth * box[2].toFloat(), maxHeight * box[3].toFloat())) { overlay() }
                }
            }
            }
            // Keep the Auto control at its approved size and position while inspecting the image.
            Box(Modifier.size(width.dp, (width / ratio).dp)) {
                val box = border?.let { com.lightlylabs.lightly.develop.BorderStage.imageBox(it, image.width, image.height) }
                if (box == null) chrome() else BoxWithConstraints(Modifier.fillMaxSize()) {
                    Box(Modifier.offset(maxWidth * box[0].toFloat(), maxHeight * box[1].toFloat()).size(maxWidth * box[2].toFloat(), maxHeight * box[3].toFloat())) { chrome() }
                }
            }
        }
        ui.toast?.let { text ->
            Text(
                text,
                style = lightlyTextStyle(13.5.sp, color = Color.White),
                maxLines = 1,
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 24.dp).background(Color(0xE61C1C1E), RoundedCornerShape(10.dp)).padding(horizontal = 14.dp, vertical = 10.dp),
            )
        }
    }
}

/** `.progress`: the dark box centred on the photo with a spinner, the label and a progress bar. */
@Composable
internal fun ProgressBox(label: String, detail: String?, barFraction: Float?, cancel: (() -> Unit)? = null) {
    // `.progress` is absolutely positioned at left:50%, so its shrink-to-fit width is at most half the
    // container (the rest of the width is to the left of it), and at least min-width 200 dp: a long
    // line ("Applying thoughtful enhancements.") wraps instead of widening the box. The bar spans the box.
    androidx.compose.foundation.layout.BoxWithConstraints {
    val available = maxOf(200.dp, maxWidth / 2)
    Column(
        Modifier.width(IntrinsicSize.Max).widthIn(min = 200.dp, max = available).background(Color(0xB8141416), RoundedCornerShape(12.dp)).padding(horizontal = 16.dp, vertical = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.padding(bottom = 8.dp).size(22.dp).drawBehind {
            // `.spinner { border:2.5px }` renders as 2px (Chrome floors fractional borders).
            val stroke = 2.dp.toPx()
            drawCircle(Color(0x59FFFFFF), radius = size.minDimension / 2 - stroke / 2, style = androidx.compose.ui.graphics.drawscope.Stroke(stroke))
            drawArc(Color.White, -135f, 90f, useCenter = false, style = androidx.compose.ui.graphics.drawscope.Stroke(stroke),
                topLeft = Offset(stroke / 2, stroke / 2), size = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke))
        })
        // `.progress { font-size:14px }` and the detail's 13px are fixed: they do not follow the text size.
        Text(label, style = lightlyTextStyle(com.lightlylabs.lightly.shell.fixedTextSize(14f), color = Color.White), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        if (detail != null) Text(detail, style = lightlyTextStyle(com.lightlylabs.lightly.shell.fixedTextSize(13f), color = Color.White.copy(alpha = 0.75f)), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        if (barFraction != null) {
            Box(Modifier.padding(top = 10.dp).fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(Color(0x40FFFFFF))) {
                Box(Modifier.fillMaxHeight().fillMaxWidth(barFraction).background(Color.White))
            }
        }
        if (cancel != null) {
            Box(Modifier.padding(top = 6.dp).heightIn(min = 44.dp).widthIn(min = 64.dp).clip(RoundedCornerShape(10.dp)).clickable(role = Role.Button, onClick = cancel).padding(horizontal = 18.dp), contentAlignment = Alignment.Center) {
                // `.progress .btn` inherits the box's fixed 14px.
                Text("Cancel", style = lightlyTextStyle(com.lightlylabs.lightly.shell.fixedTextSize(14f), FontWeight.SemiBold, Color.White))
            }
        }
    }
    }
}

/**
 * Prototype `loadingHTML`: Cancel (the back arrow), the photo with "Opening photo…" (or "Developing…"
 * while a real Auto model runs), and the space the controls will take.
 */
@Composable
private fun LoadingScreen(vm: EditorViewModel, ui: EditorUiState, frame: EditorFrame, developing: Boolean) {
    val layout = frame.layout
    val box: @Composable () -> Unit = {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            if (developing) ProgressBox("Developing…", "Applying thoughtful enhancements.", 0.7f) else ProgressBox("Opening photo…", null, 0.3f)
        }
    }
    Column(Modifier.fillMaxSize().padding(start = frame.start, end = frame.end)) {
        Spacer(Modifier.height(frame.top))
        Row(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            BarIcon(LightlyIcons.BackArrow, "Cancel", vm::discardAndLeave, tag = EditorTags.CLOSE)
        }
        val stageModifier = when (layout.mode) {
            EditorMode.SPLIT_V -> Modifier.weight(1f).padding(end = (layout.widthDp / 2).dp)
            EditorMode.SPLIT_H -> Modifier.height(((frame.foldDp ?: (layout.heightDp / 2)) - frame.top.value - 48f).dp)
            else -> Modifier.weight(1f)
        }.fillMaxWidth()
        Stage(ui.copy(preview = null, compareHeld = false, compareToggled = false, toast = null), stageModifier, overlay = box)
        if (ui.original == null) Box(Modifier.fillMaxWidth()) {}
        val below = when (layout.mode) {
            EditorMode.SIDE, EditorMode.SPLIT_V -> 20.dp
            EditorMode.SPLIT_H -> ((layout.heightDp / 2) - frame.bottom.value).dp
            else -> 120.dp
        }
        if (layout.mode == EditorMode.SPLIT_H) Spacer(Modifier.weight(1f)) else Spacer(Modifier.height(below))
        Spacer(Modifier.height(frame.bottom))
    }
}

// --- tool panel and navigation ---------------------------------------------------------------------

@Composable
fun ResetRow(vm: EditorViewModel, section: String, title: String, adjustment: String? = null) {
    var choices by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = lightlyTextStyle(), modifier = Modifier.weight(1f))
        if (vm.canReset(section)) androidx.compose.material3.TextButton(onClick = { choices = true }, modifier = Modifier.testTagResource("reset-$section")) {
            LightlyIcon(LightlyIcons.RotateLeft, size = 16.dp, tint = lightlyColors.sel)
            Spacer(Modifier.width(6.dp)); Text("Reset", color = lightlyColors.sel)
        } else Spacer(Modifier.height(48.dp))
    }
    if (choices) androidx.compose.material3.AlertDialog(onDismissRequest = { choices = false }, title = { Text("Reset") },
        text = { Column {
            if (adjustment != null) androidx.compose.material3.TextButton(onClick = { choices = false; vm.resetEdits(section, adjustment) }) { Text("Reset ${title.lowercase()}") }
            androidx.compose.material3.TextButton(onClick = { choices = false; vm.resetEdits(section) }) { Text("Reset $section") }
        } }, confirmButton = { androidx.compose.material3.TextButton(onClick = { choices = false }) { Text("Cancel") } })
}

@Composable
private fun ToolPanel(vm: EditorViewModel, ui: EditorUiState, model: DevelopPanelModel?, roomy: Boolean, wrapped: Boolean) {
    when (ui.tool) {
        EditorTool.DEVELOP -> if (model != null) DevelopPanel(vm, model, roomy, wrapped)
        EditorTool.BACKGROUND -> BackgroundPanel(vm, ui, roomy)
        EditorTool.PORTRAIT -> PortraitPanel(vm, ui, roomy, wrapped)
        EditorTool.EDIT -> EditPanel(vm, ui, roomy)
        EditorTool.EFFECTS -> EffectsPanel(vm, ui, roomy)
        EditorTool.BORDER -> BorderPanel(vm, ui, roomy)
        EditorTool.WATERMARK -> WatermarkPanel(vm, ui, roomy)
        else -> ToolStub(ui.tool, roomy)
    }
}

enum class DockKind { SCROLLS, FITS, RAIL }

/** The approved large text (slice 1/2 captures: system font scale 1.24). */
private const val APPROVED_LARGE_FONT_SCALE = 1.24f
/** The reference's smallest gap between neighbouring dock labels at large text (iOS ToolNavigation: 11 pt). */
private val LABEL_GAP_BEYOND_LARGE = 11.dp

@Composable
private fun ToolNav(vm: EditorViewModel, ui: EditorUiState, kind: DockKind) {
    val colors = lightlyColors
    val recipe = ui.session?.current
    // Prototype `toolUsed`: Develop when a Look is applied, Background when replaced or blurred, Edit and
    // Effects as ToolUsed (exactly the approved rules).
    fun used(tool: EditorTool) = when (tool) {
        EditorTool.DEVELOP -> recipe?.look != null
        EditorTool.BACKGROUND -> recipe?.tools?.background?.let { it.replacement != null || it.focus.blur > 0 } == true
        // Prototype `toolUsed`: any face with a change.
        EditorTool.PORTRAIT -> recipe?.tools?.portrait?.faces?.any { PortraitEdits.changeCount(it) > 0 } == true
        EditorTool.EDIT -> recipe != null && ToolUsed.edit(recipe, pendingStroke = ui.edit.pendingStroke != null)
        EditorTool.EFFECTS -> recipe != null && ToolUsed.effects(recipe)
        EditorTool.BORDER -> recipe?.tools?.border?.type?.let { it != com.lightlylabs.lightly.session.BorderType.NONE } == true
        EditorTool.WATERMARK -> recipe?.tools?.watermark?.type?.let { it != com.lightlylabs.lightly.session.WatermarkType.NONE } == true
        else -> false
    }
    // Beyond the approved large text (font scale 1.24) the prototype has no layout: as on iOS (ToolNavigation), a slot
    // widens to its label plus the reference's smallest gap between labels at large text, the dock scrolls (a fitting
    // tablet dock too) and the rail is as wide as its widest label. At font scale 2.0 the 76 dp slots cut the labels
    // ("Develo", "Backgr"; A11, 2026-10-07).
    val widen = LocalDensity.current.fontScale > APPROVED_LARGE_FONT_SCALE
    val items: @Composable () -> Unit = {
        ui.tools.forEach { tool -> ToolItem(tool, selected = tool == ui.tool, used = used(tool), rail = kind == DockKind.RAIL, widen = widen) { vm.selectTool(tool) } }
    }
    when (if (widen && kind == DockKind.FITS) DockKind.SCROLLS else kind) {
        DockKind.RAIL -> Column(
            Modifier.then(if (widen) Modifier.width(IntrinsicSize.Max).widthIn(min = 84.dp) else Modifier.width(84.dp))
                .fillMaxHeight().hairlineStart(colors.hair).semantics { contentDescription = "Tools" },
            verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
        ) { items() }
        DockKind.FITS -> Row(
            Modifier.fillMaxWidth().hairlineTop(colors.hair).padding(start = 4.dp, end = 4.dp, top = 2.dp).semantics { contentDescription = "Tools" },
            horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        ) { items() }
        DockKind.SCROLLS -> Row(
            Modifier
                .fillMaxWidth()
                .hairlineTop(colors.hair)
                .fadeEnd()
                .horizontalScroll(rememberScrollState())
                .padding(start = 4.dp, end = 4.dp, top = 2.dp)
                .semantics { contentDescription = "Tools" },
        ) { items() }
    }
}

@Composable
private fun ToolItem(tool: EditorTool, selected: Boolean, used: Boolean, rail: Boolean, widen: Boolean = false, onClick: () -> Unit) {
    val colors = lightlyColors
    val icon = when (tool) {
        EditorTool.DEVELOP -> LightlyIcons.Develop
        EditorTool.BACKGROUND -> LightlyIcons.Background
        EditorTool.PORTRAIT -> LightlyIcons.Portrait
        EditorTool.EDIT -> LightlyIcons.Edit
        EditorTool.EFFECTS -> LightlyIcons.Effects
        EditorTool.WATERMARK -> LightlyIcons.Watermark
        EditorTool.BORDER -> LightlyIcons.Border
    }
    Column(
        Modifier
            .then(when {
                rail -> Modifier.fillMaxWidth().heightIn(min = 62.dp).then(if (widen) Modifier.padding(horizontal = LABEL_GAP_BEYOND_LARGE / 2) else Modifier)
                widen -> Modifier.widthIn(min = 76.dp).padding(horizontal = LABEL_GAP_BEYOND_LARGE / 2).heightIn(min = 56.dp)
                else -> Modifier.width(76.dp).heightIn(min = 56.dp)
            })
            .clickable(role = Role.Tab, onClick = onClick)
            // The used dot is spoken as "Edited" (as iOS).
            .semantics { this.selected = selected; if (used) stateDescription = "Edited" }
            .testTagResource(EditorTags.tool(tool)),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically),
    ) {
        LightlyIcon(icon, tint = if (selected) colors.sel else colors.ink3)
        Text(tool.label, style = lightlyTextStyle(11.sp, FontWeight.Medium, if (selected) colors.ink else colors.ink3), maxLines = 1)
        if (used) Box(Modifier.padding(top = 1.dp).size(4.dp).background(colors.browse, CircleShape))
    }
}

// --- small drawing helpers -------------------------------------------------------------------------

internal fun Modifier.hairlineTop(color: Color) = drawBehind { drawLine(color, Offset(0f, 0.5f), Offset(size.width, 0.5f), strokeWidth = 1.dp.toPx()) }

internal fun Modifier.hairlineStart(color: Color) = drawBehind { drawLine(color, Offset(0.5f, 0f), Offset(0.5f, size.height), strokeWidth = 1.dp.toPx()) }

/** `.dock.scrolls`: mask fading the last 14 % to transparent. */
private fun Modifier.fadeEnd() = graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen).drawWithContent {
    drawContent()
    drawRect(Brush.horizontalGradient(0.86f to Color.Black, 1f to Color.Transparent), blendMode = BlendMode.DstIn)
}

@Composable
internal fun ColumnScope.PanelTitle(text: String) {
    Text(text, style = lightlyTextStyle(13.sp, FontWeight.SemiBold, lightlyColors.ink2), modifier = Modifier.padding(start = 18.dp, end = 18.dp, top = 14.dp, bottom = 4.dp))
}


/**
 * Background's marks on the photo (prototype `marksFor`): the focus target ring and tap-to-focus in
 * Focus & Blur, and the "Finding the subject…" box while separating. Drawn inside the photo box.
 */
@Composable
private fun BackgroundMarks(vm: EditorViewModel, ui: EditorUiState) {
    if (ui.tool != EditorTool.BACKGROUND || ui.showsOriginal) return
    val tool = ui.session?.current?.tools?.background ?: return
    when (val state = BackgroundPanelState.of(ui.background, ui.separation, tool.replacement)) {
        BackgroundPanelState.Separating -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            ProgressBox("Finding the subject…", null, null, cancel = vm::cancelSeparation)
        }
        // PROPOSED copy (owner approval pending, 2026-10-07): depth's own progress, distinct from the subject's.
        BackgroundPanelState.EstimatingDepth -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            ProgressBox("Estimating depth…", null, null, cancel = vm::cancelSeparation)
        }
        BackgroundPanelState.Focus, BackgroundPanelState.NoSubject -> BoxWithConstraints(
            Modifier.fillMaxSize().pointerInput(Unit) {
                detectTapGestures { offset ->
                    // A tap on the displayed frame, stored in source coordinates (through Edit's geometry).
                    val (sx, sy) = vm.displayGeometry()?.sourceFromFrame(offset.x.toDouble() / size.width, offset.y.toDouble() / size.height)
                        ?: (offset.x.toDouble() / size.width to offset.y.toDouble() / size.height)
                    vm.setFocusTarget(sx, sy)
                }
            }.semantics { contentDescription = "Tap the photo to set focus" },
        ) {
            // No subject and a blur waiting for depth: depth's own progress (PROPOSED copy, see EstimatingDepth).
            if (state == BackgroundPanelState.NoSubject && tool.focus.blur > 0 && (ui.separation as? SeparationState.Finished)?.depthPending == true) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    ProgressBox("Estimating depth…", null, null, cancel = vm::cancelSeparation)
                }
            }
            // The prototype shows the target only when the photo has a subject.
            if (state == BackgroundPanelState.Focus) {
                val (tx, ty) = vm.focusTarget.let { (x, y) -> vm.displayGeometry(ui)?.frameFromSource(x, y) ?: (x to y) }
                Box(
                    Modifier
                        .offset(x = maxWidth * tx.toFloat() - 26.dp, y = maxHeight * ty.toFloat() - 26.dp)
                        .size(52.dp)
                        .drawBehind {
                            // `box-shadow: 0 0 0 1px rgba(0,0,0,.25)`: a 1 dp ring just outside the 52 dp box.
                            drawCircle(Color(0x40000000), size.minDimension / 2 + 0.5.dp.toPx(), style = androidx.compose.ui.graphics.drawscope.Stroke(1.dp.toPx()))
                            // `.target { border:1.5px }` renders as 1px (Chrome floors fractional borders).
                            drawCircle(Color.White, size.minDimension / 2 - 0.5.dp.toPx(), style = androidx.compose.ui.graphics.drawscope.Stroke(1.dp.toPx()))
                            drawCircle(Color.White, 3.dp.toPx())
                        },
                )
            }
        }
        BackgroundPanelState.Refine -> {
            // `.maskTint`: the subject tinted rgba(47,107,235,.32); brushing adds to or erases from it.
            val matte = vm.refinedMatte()
            val tint = remember(matte) { matte?.let { m ->
                val pixels = IntArray(m.width * m.height) { p -> val a = (m.values[p].coerceIn(0f, 1f) * 0.32f * 255).toInt(); (a shl 24) or (47 shl 16) or (107 shl 8) or 235 }
                android.graphics.Bitmap.createBitmap(pixels, m.width, m.height, android.graphics.Bitmap.Config.ARGB_8888).asImageBitmap()
            } }
            Box(
                Modifier.fillMaxSize().pointerInput(Unit) {
                    val points = ArrayList<Pair<Double, Double>>()
                    detectDragGestures(
                        onDragStart = { o -> points.clear(); points += o.x.toDouble() / size.width to o.y.toDouble() / size.height },
                        onDrag = { change, _ -> points += change.position.x.toDouble() / size.width to change.position.y.toDouble() / size.height },
                        onDragEnd = { vm.addRefineStroke(points.toList()) },
                    )
                }.semantics { contentDescription = "Brush over the edge to refine the subject" },
            ) {
                if (tint != null) Image(tint, null, contentScale = ContentScale.FillBounds, modifier = Modifier.fillMaxSize())
            }
        }
        else -> Unit
    }
}

/**
 * Keeps the screen on only while long foreground work runs (2026-10-07, as iOS KeepAwake): subject separation, depth,
 * a Remove stroke, Save copy. Cleared as soon as none runs (completion, failure, Cancel) and when the editor leaves
 * composition; otherwise the system's normal screen timeout applies.
 */
@Composable
private fun KeepScreenOnWhileWorking(ui: EditorUiState) {
    val view = androidx.compose.ui.platform.LocalView.current
    val separation = ui.separation
    val working = separation == SeparationState.Separating ||
        (separation is SeparationState.Finished && separation.depthPending) ||
        ui.edit.removeOp == RemoveOp.REMOVING ||
        ui.overlay == EditorOverlay.SAVING
    androidx.compose.runtime.DisposableEffect(view, working) {
        view.keepScreenOn = working
        onDispose { view.keepScreenOn = false }
    }
}

@Composable
private fun AutoEnhanceOverlay(vm: EditorViewModel, ui: EditorUiState) {
    val applied = ui.auto == AutoState.APPLIED
    var resetConfirmation by remember { mutableStateOf(false) }
    if (resetConfirmation) androidx.compose.material3.AlertDialog(
        onDismissRequest = { resetConfirmation = false },
        title = { Text("Reset all edits?") },
        text = { Text("Return to the original photo. This also turns Auto off. You can undo this.") },
        confirmButton = { androidx.compose.material3.TextButton(onClick = { resetConfirmation = false; vm.resetEdits() }) { Text("Reset all edits") } },
        dismissButton = { androidx.compose.material3.TextButton(onClick = { resetConfirmation = false }) { Text("Keep editing") } })
    // The 30 dp disc sits 12 dp inside the fitted photo, with a separate 48 dp touch area.
    val photoBox: DoubleArray? = null
    Box(Modifier.fillMaxSize().layout { measurable, constraints ->
        val b = photoBox ?: doubleArrayOf(0.0, 0.0, 1.0, 1.0)
        val w = (constraints.maxWidth * b[2]).toInt()
        val h = (constraints.maxHeight * b[3]).toInt()
        val child = measurable.measure(androidx.compose.ui.unit.Constraints.fixed(w, h))
        layout(constraints.maxWidth, constraints.maxHeight) {
            child.place((constraints.maxWidth * b[0]).toInt(), (constraints.maxHeight * b[1]).toInt())
        }
    }, contentAlignment = Alignment.BottomStart) {
        Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.padding(3.dp).size(48.dp)
            .clickable(onClick = vm::toggleAuto)
            .semantics {
                contentDescription = "Auto enhance"
                stateDescription = if (applied) "Applied" else "Not applied"
                selected = applied
            }
            .testTagResource(EditorTags.AUTO), contentAlignment = Alignment.Center) {
            Box(Modifier.size(30.dp)
                .background(Color(0xB8181B19), CircleShape)
                .drawBehind {
                    if (applied) drawCircle(Color.White.copy(alpha = 0.7f),
                        radius = size.minDimension / 2 - 0.5.dp.toPx(),
                        style = androidx.compose.ui.graphics.drawscope.Stroke(1.dp.toPx()))
                }, contentAlignment = Alignment.Center) {
                LightlyIcon(LightlyIcons.AutoEnhance, size = 18.dp, tint = Color.White)
                if (applied) Box(Modifier.align(Alignment.BottomEnd).offset(3.dp, 3.dp)
                    .size(12.dp).background(Color(0xFFF7F9F7), CircleShape), contentAlignment = Alignment.Center) {
                    LightlyIcon(LightlyIcons.Check, size = 9.dp, tint = Color(0xFF222923))
                }
            }
        }
        if (vm.canReset("all")) {
            val dark = lightlyColors.bg.luminance() < 0.5f
            val surface = if (dark) Color(0xFF202024) else Color.White
            val ink = if (dark) Color(0xFF9BBAFF) else Color(0xFF2459D5)
            Box(Modifier.height(48.dp).clickable { resetConfirmation = true }
                .semantics { contentDescription = "Reset all edits" }
                .testTagResource("editor-reset-all"), contentAlignment = Alignment.Center) {
                Row(Modifier.background(surface, RoundedCornerShape(20.dp))
                    .border(1.dp, if (dark) Color.White.copy(alpha = 0.28f) else Color.Black.copy(alpha = 0.18f), RoundedCornerShape(20.dp))
                    .padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    LightlyIcon(LightlyIcons.RotateLeft, size = 15.dp, tint = ink)
                    Text("Reset all", style = lightlyTextStyle(13.sp, color = ink))
                }
            }
        }
        }
    }
}
