package com.lightlylabs.lightly.editor

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.IntrinsicSize
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
import androidx.compose.ui.Alignment
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
    val stage: @Composable (Modifier) -> Unit = { modifier -> Stage(ui, modifier) }
    val panel: @Composable (roomy: Boolean, wrapped: Boolean) -> Unit = { roomy, wrapped -> ToolPanel(vm, ui, model, roomy, wrapped) }
    val tools: @Composable (kind: DockKind) -> Unit = { kind -> ToolNav(vm, ui, kind) }
    Column(Modifier.fillMaxSize().padding(start = frame.start, end = frame.end)) {
        when (layout.mode) {
            EditorMode.BELOW, EditorMode.WIDE -> {
                Spacer(Modifier.height(frame.top))
                EditorTopBar(vm, ui, actions)
                stage(Modifier.weight(1f).fillMaxWidth())
                val wide = layout.mode == EditorMode.WIDE
                // The panel never takes more than its share of the height: it scrolls, so the photo stays dominant.
                val maxPanel = (layout.heightDp * if (wide) 0.3f else 0.34f).let { kotlin.math.round(it) }.dp
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
    // `.save`: min-height 44, padding 0 14, radius 9, ink fill, weight 600, margin 0 4.
    Box(
        Modifier
            .padding(horizontal = 4.dp)
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(9.dp))
            .background(colors.ink)
            .clickable(role = Role.Button, onClick = vm::saveCopy)
            .testTagResource(EditorTags.SAVE)
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text("Save copy", style = lightlyTextStyle(15.sp, FontWeight.SemiBold, colors.bg), maxLines = 1)
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
private fun Stage(ui: EditorUiState, modifier: Modifier, overlay: @Composable () -> Unit = {}) {
    val colors = lightlyColors
    val image = if (ui.showsOriginal) ui.original else ui.preview ?: ui.original
    BoxWithConstraints(modifier.background(colors.canvas).testTagResource(EditorTags.STAGE), contentAlignment = Alignment.Center) {
        if (image != null) {
            val bitmap = remember(image) { image.toBitmap().asImageBitmap() }
            val ratio = image.width.toFloat() / image.height
            val width = minOf(maxWidth.value, maxHeight.value * ratio)
            Box(Modifier.size(width.dp, (width / ratio).dp)) {
                Image(bitmap, contentDescription = if (ui.showsOriginal) "The original photo" else "Your photo with the edit", contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
                if (ui.showsOriginal) {
                    Text(
                        "Original",
                        style = lightlyTextStyle(12.5.sp, FontWeight.SemiBold, Color.White),
                        modifier = Modifier.padding(10.dp).background(Color(0x8C000000), RoundedCornerShape(8.dp)).padding(horizontal = 9.dp, vertical = 3.dp),
                    )
                }
                overlay()
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
internal fun ProgressBox(label: String, detail: String?, barFraction: Float, cancel: (() -> Unit)? = null) {
    // Content-sized (min 200 dp): the bar spans the box, not the photo.
    Column(
        Modifier.width(IntrinsicSize.Max).widthIn(min = 200.dp).background(Color(0xB8141416), RoundedCornerShape(12.dp)).padding(horizontal = 16.dp, vertical = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.padding(bottom = 8.dp).size(22.dp).drawBehind {
            val stroke = 2.5.dp.toPx()
            drawCircle(Color(0x59FFFFFF), radius = size.minDimension / 2 - stroke / 2, style = androidx.compose.ui.graphics.drawscope.Stroke(stroke))
            drawArc(Color.White, -135f, 90f, useCenter = false, style = androidx.compose.ui.graphics.drawscope.Stroke(stroke),
                topLeft = Offset(stroke / 2, stroke / 2), size = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke))
        })
        Text(label, style = lightlyTextStyle(14.sp, color = Color.White))
        if (detail != null) Text(detail, style = lightlyTextStyle(13.sp, color = Color.White.copy(alpha = 0.75f)))
        Box(Modifier.padding(top = 10.dp).fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(Color(0x40FFFFFF))) {
            Box(Modifier.fillMaxHeight().fillMaxWidth(barFraction).background(Color.White))
        }
        if (cancel != null) {
            Box(Modifier.padding(top = 6.dp).heightIn(min = 44.dp).widthIn(min = 64.dp).clip(RoundedCornerShape(10.dp)).clickable(role = Role.Button, onClick = cancel).padding(horizontal = 18.dp), contentAlignment = Alignment.Center) {
                Text("Cancel", style = lightlyTextStyle(15.sp, FontWeight.SemiBold, Color.White))
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
private fun ToolPanel(vm: EditorViewModel, ui: EditorUiState, model: DevelopPanelModel?, roomy: Boolean, wrapped: Boolean) {
    if (ui.tool == EditorTool.DEVELOP) {
        if (model != null) DevelopPanel(vm, model, roomy, wrapped)
    } else {
        ToolStub(ui.tool, roomy)
    }
}

enum class DockKind { SCROLLS, FITS, RAIL }

@Composable
private fun ToolNav(vm: EditorViewModel, ui: EditorUiState, kind: DockKind) {
    val colors = lightlyColors
    val used = ui.session?.current?.look != null
    val items: @Composable () -> Unit = {
        ui.tools.forEach { tool -> ToolItem(tool, selected = tool == ui.tool, used = tool == EditorTool.DEVELOP && used, rail = kind == DockKind.RAIL) { vm.selectTool(tool) } }
    }
    when (kind) {
        DockKind.RAIL -> Column(
            Modifier.width(84.dp).fillMaxHeight().hairlineStart(colors.hair).semantics { contentDescription = "Tools" },
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
private fun ToolItem(tool: EditorTool, selected: Boolean, used: Boolean, rail: Boolean, onClick: () -> Unit) {
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
            .then(if (rail) Modifier.fillMaxWidth().heightIn(min = 62.dp) else Modifier.width(76.dp).heightIn(min = 56.dp))
            .clickable(role = Role.Tab, onClick = onClick)
            .semantics { this.selected = selected }
            .testTagResource(EditorTags.tool(tool)),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically),
    ) {
        LightlyIcon(icon, tint = if (selected) colors.sel else colors.ink3)
        Text(tool.label, style = lightlyTextStyle(11.sp, FontWeight.Medium, if (selected) colors.ink else colors.ink3), maxLines = 1)
        if (used) Box(Modifier.padding(top = 1.dp).size(4.dp).background(if (selected) colors.sel else colors.ink3, CircleShape))
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
