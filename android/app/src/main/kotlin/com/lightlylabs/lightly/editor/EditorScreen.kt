package com.lightlylabs.lightly.editor

import androidx.compose.animation.core.animateFloat

import androidx.compose.ui.semantics.heading

import androidx.compose.ui.draw.shadow

import androidx.compose.foundation.layout.wrapContentHeight

import com.lightlylabs.lightly.shell.LightlyMark

import com.lightlylabs.lightly.shell.LinkButton

import com.lightlylabs.lightly.shell.SaveButton

import com.lightlylabs.lightly.shell.MoreButton

import com.lightlylabs.lightly.shell.IconTapTarget

import com.lightlylabs.lightly.shell.l2TextStyle

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
import androidx.compose.foundation.layout.wrapContentWidth
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

/** Lightly 2 `PANEL_HEIGHT`: on phones the tool panel is this tall for every tool and state; its contents scroll. */
internal val PHONE_PANEL_HEIGHT = 340.dp

@Composable
private fun EditorContent(vm: EditorViewModel, ui: EditorUiState, model: DevelopPanelModel?, frame: EditorFrame, actions: EditorActions) {
    val layout = frame.layout
    val colors = lightlyColors
    // Owner amendment (2026-10-10): Auto and Reset all sit on the photo area's bottom-start corner for every photo (on or
    // beside the photo), 10 dp inside the stage's 12/8 dp inset, instead of following the photo's own corner.
    val stage: @Composable (Modifier) -> Unit = { modifier ->
        Box(modifier) {
            // While cropping, a pinch resizes the crop frame instead of zooming the photo.
            Stage(ui, Modifier.fillMaxSize(), overlay = { BackgroundMarks(vm, ui); PortraitMarks(vm, ui); EditMarks(vm, ui) }, inspection = !vm.isCropEditing(ui), onPhotoBox = vm::onStagePhotoMeasured)
            if (!ui.showsOriginal && !vm.isCropEditing(ui)) Box(Modifier.matchParentSize().padding(start = 12.dp, bottom = 8.dp)) { AutoEnhanceOverlay(vm, ui) }
        }
    }
    Box(Modifier.fillMaxSize()) {
        if (layout.mode == EditorMode.BELOW) {
            // Phone (Android): the app bar, the photo, then the sheet: the fixed panel and the dock.
            Column(Modifier.fillMaxSize().padding(start = frame.start, end = frame.end)) {
                Spacer(Modifier.height(frame.top))
                EditorAppBar(vm, ui, actions)
                stage(Modifier.weight(1f).fillMaxWidth())
                val sheetShape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
                Column(Modifier.fillMaxWidth().clip(sheetShape).background(colors.sheet, sheetShape).border(1.dp, colors.hair, sheetShape)) {
                    val fades = ui.tool != EditorTool.DEVELOP || (model?.notice != null)
                    Column(
                        Modifier.fillMaxWidth().height(PHONE_PANEL_HEIGHT).then(if (fades) Modifier.fadeBottom() else Modifier)
                            .verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 6.dp),
                    ) { ToolPanel(vm, ui, model, false, false) }
                    ToolNav(vm, ui)
                    Spacer(Modifier.height(frame.bottom))
                }
            }
        } else {
            // Two panes (unfolded foldables and other wide windows): the header bar, the photo pane and the panel card.
            val inset = if (layout.heightDp < 700f) 12.dp else 16.dp
            Column(Modifier.fillMaxSize().padding(start = frame.start + inset, end = frame.end + inset, top = frame.top + inset, bottom = frame.bottom + inset),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                EditorHeaderBar(vm, ui, actions)
                Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    val paneShape = RoundedCornerShape(26.dp)
                    stage(Modifier.weight(1f).fillMaxHeight().clip(paneShape).background(colors.canvas, paneShape))
                    Column(
                        Modifier.weight(1f).fillMaxHeight().clip(paneShape).background(colors.surface, paneShape).border(1.dp, colors.hair, paneShape)
                            .padding(horizontal = 18.dp, vertical = 16.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Text(ui.tool.label, style = l2TextStyle(17.sp, FontWeight.SemiBold, colors.ink), modifier = Modifier.semantics { heading() })
                        Column(Modifier.weight(1f).fadeBottom().verticalScroll(rememberScrollState())) { ToolPanel(vm, ui, model, false, false) }
                    }
                }
            }
        }
        // Swiped up, the preset gallery overlays the photo above the dock without squeezing it (`expandedSheet`):
        // min(600, screen − 120) tall, 30 dp top corners, sheet fill, a shadow above.
        if (ui.tool == EditorTool.DEVELOP && ui.develop.expanded && model != null && layout.mode == EditorMode.BELOW) {
            val shape = RoundedCornerShape(topStart = 30.dp, topEnd = 30.dp)
            Column(
                Modifier.align(Alignment.BottomCenter).padding(bottom = DOCK_HEIGHT + frame.bottom).fillMaxWidth()
                    .height(minOf(600f, layout.heightDp - 120f).dp).shadow(12.dp, shape).clip(shape).background(colors.sheet, shape)
                    .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 10.dp),
            ) {
                var handleDrag by remember { mutableStateOf(0f) }
                Box(Modifier.fillMaxWidth().height(24.dp).pointerInput(Unit) {
                    detectDragGestures(onDragStart = { handleDrag = 0f }, onDragEnd = {
                        if (handleDrag > 40.dp.toPx()) vm.setPresetExpanded(false)
                    }) { change, delta -> handleDrag += delta.y; change.consume() }
                }.semantics { contentDescription = "Preset browser" }, contentAlignment = Alignment.Center) {
                    Box(Modifier.width(36.dp).height(4.dp).background(colors.track, CircleShape))
                }
                DevelopPanel(vm, model, false, false, expanded = true)
            }
        }
    }
}

// --- top bars ---------------------------------------------------------------------------------------

/**
 * The phone editor header, the same on Android and iPhone (owner amendment 2026-10-11; was an Android app bar with Back
 * and the tool's name): a 52 dp row with 12 dp sides; the glass capsule (3 dp padding, 2 dp gaps: Close, Undo, Redo),
 * then Compare (glass), Save and ⋮ More, 6 dp apart.
 */
@Composable
private fun EditorAppBar(vm: EditorViewModel, ui: EditorUiState, actions: EditorActions) {
    val colors = lightlyColors
    Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 12.dp), verticalAlignment = Alignment.Top) {
        Row(
            Modifier.clip(CircleShape).background(colors.glass, CircleShape).border(1.dp, colors.glassLine, CircleShape).padding(3.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            IconTapTarget(LightlyIcons.Close, "Close", vm::close, tag = EditorTags.CLOSE)
            IconTapTarget(LightlyIcons.Undo, "Undo", vm::undo, enabled = ui.canUndo, tag = EditorTags.UNDO)
            IconTapTarget(LightlyIcons.Redo, "Redo", vm::redo, enabled = ui.canRedo, tag = EditorTags.REDO)
        }
        Spacer(Modifier.weight(1f).widthIn(min = 6.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 3.dp)) {
            CompareButton(vm, ui, glass = true)
            SaveButton(vm::saveCopy)
            MoreButton(actions.more, tag = EditorTags.MORE)
        }
    }
}

/**
 * The header bar of two-pane windows (`header()`): 60 dp, 24 dp corners, surface, hairline; the app-icon tile, Back, the
 * tools (the selected one named on an ink fill, an orange dot on tools holding edits), then Undo, Redo, Compare, Save, ⋮.
 */
@Composable
private fun EditorHeaderBar(vm: EditorViewModel, ui: EditorUiState, actions: EditorActions) {
    val colors = lightlyColors
    val shape = RoundedCornerShape(24.dp)
    Row(
        Modifier.fillMaxWidth().height(60.dp).clip(shape).background(colors.surface, shape).border(1.dp, colors.hair, shape).padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        LightlyMark(44.dp, tile = true)
        IconTapTarget(LightlyIcons.BackChevron, "Back", vm::close, tag = EditorTags.CLOSE)
        Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()).padding(start = 4.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            ui.tools.forEach { tool ->
                val on = tool == ui.tool
                val used = toolUsed(ui, tool)
                Box(
                    Modifier.height(44.dp).clip(RoundedCornerShape(22.dp)).background(if (on) colors.segmentOn else Color.Transparent)
                        .clickable(role = Role.Tab) { vm.selectTool(tool) }
                        .semantics { selected = on; contentDescription = tool.label; if (used) stateDescription = "Edited" }
                        .testTagResource(EditorTags.tool(tool))
                        .then(if (on) Modifier.padding(horizontal = 14.dp) else Modifier.width(44.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        LightlyIcon(toolIcon(tool), size = 20.dp, tint = if (on) colors.onInk else colors.ink2)
                        if (on) Text(tool.label, style = l2TextStyle(14.sp, FontWeight.SemiBold, colors.onInk), maxLines = 1)
                    }
                    if (used) Box(Modifier.align(Alignment.TopEnd).padding(7.dp).size(5.dp).background(colors.edited, CircleShape))
                }
            }
        }
        IconTapTarget(LightlyIcons.Undo, "Undo", vm::undo, enabled = ui.canUndo, tag = EditorTags.UNDO)
        IconTapTarget(LightlyIcons.Redo, "Redo", vm::redo, enabled = ui.canRedo, tag = EditorTags.REDO)
        CompareButton(vm, ui, glass = false)
        SaveButton(vm::saveCopy)
        MoreButton(actions.more, tag = EditorTags.MORE)
    }
}

/**
 * Hold to compare: the original shows while a finger is down; a 44 dp circle, ink-filled while showing the original.
 * For TalkBack and switch access the same button is a toggle.
 */
@Composable
private fun CompareButton(vm: EditorViewModel, ui: EditorUiState, glass: Boolean) {
    val colors = lightlyColors
    val on = ui.showsOriginal
    Box(
        Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(if (on) colors.segmentOn else if (glass) colors.glass else Color.Transparent)
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
    ) { LightlyIcon(LightlyIcons.Compare, size = 20.dp, tint = if (on) colors.onInk else colors.ink) }
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
    // Lightly 2 `photo()`: the stage is transparent (its container gives --bg on phones, --stage in panes; the crop
    // workspace #141414); the photo is contain-fitted 12 dp in from the sides and 8 dp from top and bottom, with 18 dp
    // corners (3 dp with a border).
    BoxWithConstraints(modifier.clipToBounds().testTagResource(EditorTags.STAGE).padding(horizontal = 12.dp, vertical = 8.dp), contentAlignment = Alignment.Center) {
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
            val border = ui.session?.current?.let { EditMapping.border(it) }?.takeIf { !it.isNone && !ui.showsOriginal && ui.preview != null && !(ui.tool == EditorTool.EDIT && ui.edit.sub == EditSub.CROP) }
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
                Image(bitmap, contentDescription = if (ui.showsOriginal) "The original photo" else "Your photo with the edit", contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize().clip(RoundedCornerShape(if (border != null) 3.dp else 18.dp)))
                if (ui.showsOriginal) {
                    Text(
                        "Original",
                        style = l2TextStyle(com.lightlylabs.lightly.shell.fixedTextSize(12f), FontWeight.Bold, Color.White),
                        modifier = Modifier.padding(12.dp).background(Color(0x8C000000), RoundedCornerShape(10.dp)).padding(horizontal = 10.dp, vertical = 6.dp),
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
                // `toast`: centred 58 dp above the photo's bottom; 9/14 dp padding, 14 dp corners, rgba(14,15,17,.88), 13 sp semibold.
                ui.toast?.let { text ->
                    Text(
                        text,
                        style = l2TextStyle(13.sp, FontWeight.SemiBold, Color(0xFFF2F3F0)),
                        maxLines = 1,
                        modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 58.dp).background(Color(0xE00E0F11), RoundedCornerShape(14.dp)).padding(horizontal = 14.dp, vertical = 9.dp),
                    )
                }
            }
        }
    }
}

/**
 * `progressCard`: at least 190 dp wide, 16/18 dp padding, 20 dp corners, rgba(14,15,17,.82); a 24 dp lime spinner, the
 * label (14 sp semibold; an optional 12 sp sub-line at 75 %), an optional 150×4 dp lime bar on 20 % white, and an
 * optional Cancel (34 dp capsule, 12 % white, 13 sp semibold), 10 dp apart.
 */
@Composable
internal fun ProgressBox(label: String, detail: String?, barFraction: Float?, cancel: (() -> Unit)? = null) {
    val ink = Color(0xFFF2F3F0)
    val lime = Color(0xFFCFF26B)
    Column(
        Modifier.widthIn(min = 190.dp).background(Color(0xD10E0F11), RoundedCornerShape(20.dp)).padding(horizontal = 18.dp, vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        val spin = androidx.compose.animation.core.rememberInfiniteTransition(label = "spinner")
        val angle by spin.animateFloat(0f, 360f, androidx.compose.animation.core.infiniteRepeatable(androidx.compose.animation.core.tween(900, easing = androidx.compose.animation.core.LinearEasing)), label = "angle")
        Box(Modifier.size(24.dp).graphicsLayer { rotationZ = angle }.drawBehind {
            val stroke = 3.dp.toPx()
            drawArc(lime, -45f, 270f, useCenter = false, style = androidx.compose.ui.graphics.drawscope.Stroke(stroke),
                topLeft = Offset(stroke / 2, stroke / 2), size = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke))
        })
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = l2TextStyle(com.lightlylabs.lightly.shell.fixedTextSize(14f), FontWeight.SemiBold, ink), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            if (detail != null) Text(detail, style = l2TextStyle(com.lightlylabs.lightly.shell.fixedTextSize(12f), FontWeight.Medium, ink.copy(alpha = 0.75f)), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        }
        if (barFraction != null) {
            Box(Modifier.width(150.dp).height(4.dp).clip(RoundedCornerShape(2.dp)).background(Color(0x33FFFFFF))) {
                Box(Modifier.fillMaxHeight().fillMaxWidth(barFraction).background(lime))
            }
        }
        if (cancel != null) {
            Box(Modifier.heightIn(min = 44.dp).clickable(role = Role.Button, onClick = cancel).testTagResource("progress-cancel"), contentAlignment = Alignment.Center) {
                Text("Cancel", style = l2TextStyle(com.lightlylabs.lightly.shell.fixedTextSize(13f), FontWeight.SemiBold, ink),
                    modifier = Modifier.height(34.dp).background(Color(0x1FFFFFFF), RoundedCornerShape(17.dp)).padding(horizontal = 14.dp).wrapContentHeight())
            }
        }
    }
}

/**
 * Loading (`loadingScreen`): the photo between the 52 dp bar area and 120 dp from the bottom (phones; 16 dp in panes), the
 * progress card centred on it, Close at the top start (12 dp in).
 */
@Composable
private fun LoadingScreen(vm: EditorViewModel, ui: EditorUiState, frame: EditorFrame, developing: Boolean) {
    val layout = frame.layout
    val box: @Composable () -> Unit = {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            if (developing) ProgressBox("Developing…", "Applying thoughtful enhancements.", 0.7f) else ProgressBox("Opening photo…", null, 0.3f)
        }
    }
    Box(Modifier.fillMaxSize().padding(start = frame.start, end = frame.end)) {
        Column(Modifier.fillMaxSize()) {
            Spacer(Modifier.height(frame.top + 52.dp))
            Stage(ui.copy(preview = null, compareHeld = false, compareToggled = false, toast = null), Modifier.weight(1f).fillMaxWidth(), overlay = box)
            Spacer(Modifier.height(if (layout.mode == EditorMode.BELOW) 120.dp else 16.dp))
            Spacer(Modifier.height(frame.bottom))
        }
        IconTapTarget(LightlyIcons.Close, "Cancel", vm::discardAndLeave, Modifier.padding(start = 12.dp, top = frame.top), tag = EditorTags.CLOSE)
    }
}

// --- tool panel and navigation ---------------------------------------------------------------------

/**
 * Scoped reset (`resetRow`): the section title (14 sp bold) and, when there is something to reset, "Reset" (accent,
 * 13 sp bold, the reset icon). Reset offers this adjustment, the whole tool, or Cancel.
 */
@Composable
fun ResetRow(vm: EditorViewModel, section: String, title: String, adjustment: String? = null) {
    var choices by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().heightIn(min = 34.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = l2TextStyle(14.sp, FontWeight.Bold, lightlyColors.ink), modifier = Modifier.weight(1f))
        if (vm.canReset(section)) LinkButton("Reset", { choices = true }, icon = LightlyIcons.Reset, tag = "reset-$section")
    }
    if (choices) L2ResetChoices(
        listOfNotNull(
            adjustment?.let { L2DialogButton("Reset ${title.lowercase()}", "reset-$section-$it") { choices = false; vm.resetEdits(section, it) } },
            L2DialogButton("Reset $section", "reset-$section-all") { choices = false; vm.resetEdits(section) },
        ),
        onCancel = { choices = false },
    )
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

/** The dock's height above the bottom inset (`dockHeight`). */
internal val DOCK_HEIGHT = 62.dp

/** Prototype `toolUsed`: the tools holding an edit (Auto alone does not count). */
internal fun toolUsed(ui: EditorUiState, tool: EditorTool): Boolean {
    val recipe = ui.session?.current
    return when (tool) {
        EditorTool.DEVELOP -> recipe?.look != null
        EditorTool.BACKGROUND -> recipe?.tools?.background?.let { it.replacement != null || it.focus.blur > 0 } == true
        EditorTool.PORTRAIT -> recipe?.tools?.portrait?.faces?.any { PortraitEdits.changeCount(it) > 0 } == true
        EditorTool.EDIT -> recipe != null && ToolUsed.edit(recipe, pendingStroke = ui.edit.pendingStroke != null)
        EditorTool.EFFECTS -> recipe != null && ToolUsed.effects(recipe)
        EditorTool.BORDER -> recipe?.tools?.border?.type?.let { it != com.lightlylabs.lightly.session.BorderType.NONE } == true
        EditorTool.WATERMARK -> recipe?.tools?.watermark?.type?.let { it != com.lightlylabs.lightly.session.WatermarkType.NONE } == true
    }
}

internal fun toolIcon(tool: EditorTool): ImageVector = when (tool) {
    EditorTool.DEVELOP -> LightlyIcons.Develop
    EditorTool.BACKGROUND -> LightlyIcons.Background
    EditorTool.PORTRAIT -> LightlyIcons.Portrait
    EditorTool.EDIT -> LightlyIcons.Edit
    EditorTool.EFFECTS -> LightlyIcons.Effects
    EditorTool.WATERMARK -> LightlyIcons.Watermark
    EditorTool.BORDER -> LightlyIcons.Border
}

/**
 * The Android phone dock (`phoneDock`): 62 dp, a hairline above, the tools in equal slots (6 dp top, 4 dp sides); each a
 * 46×30 dp pill (lime with the on-accent icon when selected), the 9.5 sp semibold label (ink when selected, ink2) and a
 * 4 dp dot slot, orange on tools holding edits.
 */
@Composable
private fun ToolNav(vm: EditorViewModel, ui: EditorUiState) {
    val colors = lightlyColors
    Row(
        Modifier.fillMaxWidth().height(DOCK_HEIGHT).hairlineTop(colors.hair).padding(start = 4.dp, end = 4.dp, top = 6.dp).semantics { contentDescription = "Tools" },
    ) {
        ui.tools.forEach { tool ->
            val on = tool == ui.tool
            val used = toolUsed(ui, tool)
            Column(
                Modifier.weight(1f).clickable(role = Role.Tab) { vm.selectTool(tool) }
                    .semantics { this.selected = on; if (used) stateDescription = "Edited" }
                    .testTagResource(EditorTags.tool(tool)),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Box(Modifier.size(width = 46.dp, height = 30.dp).background(if (on) colors.accent else Color.Transparent, RoundedCornerShape(15.dp)),
                    contentAlignment = Alignment.Center) {
                    LightlyIcon(toolIcon(tool), size = 20.dp, tint = if (on) colors.onAccent else colors.ink2)
                }
                Text(tool.label, style = l2TextStyle(9.5.sp, FontWeight.SemiBold, if (on) colors.ink else colors.ink2), maxLines = 1)
                Box(Modifier.size(4.dp).background(if (used) colors.edited else Color.Transparent, CircleShape))
            }
        }
    }
}

/** The panel's lower edge fades (#000 90 % → transparent) where its contents scroll (`fadeDown`). */
internal fun Modifier.fadeBottom() = graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen).drawWithContent {
    drawContent()
    drawRect(Brush.verticalGradient(0.9f to Color.Black, 1f to Color.Transparent), blendMode = BlendMode.DstIn)
}

// --- small drawing helpers -------------------------------------------------------------------------

internal fun Modifier.hairlineTop(color: Color) = drawBehind { drawLine(color, Offset(0f, 0.5f), Offset(size.width, 0.5f), strokeWidth = 1.dp.toPx()) }

internal fun Modifier.hairlineStart(color: Color) = drawBehind { drawLine(color, Offset(0.5f, 0f), Offset(0.5f, size.height), strokeWidth = 1.dp.toPx()) }

/** A row's end fading (88 %), as the mockup's scrolling rows. */
internal fun Modifier.fadeEnd(enabled: Boolean = true) = if (!enabled) this else graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen).drawWithContent {
    drawContent()
    drawRect(Brush.horizontalGradient(0.88f to Color.Black, 1f to Color.Transparent), blendMode = BlendMode.DstIn)
}

/** The panel's title is drawn by its container in Lightly 2 (the two-pane card), never inside the panel. */
@Suppress("UNUSED_PARAMETER")
@Composable
internal fun ColumnScope.PanelTitle(text: String) {}


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

/**
 * Auto and "Reset all" on the photo's bottom-start corner (`autoControls`), 6 dp apart, 10 dp in: Auto is a 38 dp circle,
 * rgba(14,15,17,.66); applied, a 1.5 dp 75 % white ring, the wand in lime and a 15 dp lime badge with the check; not
 * applied, a 1 dp 18 % white ring and a #F2F3F0 wand. Reset all: a 38 dp capsule, same fill, 1 dp 18 % white ring, 13 sp
 * bold with the reset icon. Reset all asks first (the mockup's dialog).
 */
@Composable
private fun AutoEnhanceOverlay(vm: EditorViewModel, ui: EditorUiState) {
    val applied = ui.auto == AutoState.APPLIED
    var resetConfirmation by remember { mutableStateOf(false) }
    // In its own full-screen window: drawn here it would be confined (scrim and card) to the stage's corner.
    if (resetConfirmation) androidx.compose.ui.window.Dialog(onDismissRequest = { resetConfirmation = false },
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        L2Dialog(
            "Reset all edits?", "Return to the original photo. This also turns Auto off. You can undo this.",
            listOf(L2DialogButton("Reset all edits", "dialog-Reset all edits", destructive = true) { resetConfirmation = false; vm.resetEdits() },
                L2DialogButton("Keep editing", "dialog-Keep editing") { resetConfirmation = false }),
            onDismiss = { resetConfirmation = false },
        )
    }
    val fill = Color(0xA80E0F11)
    val lime = Color(0xFFCFF26B)
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomStart) {
        // Unbounded: a narrow photo never squeezes or wraps "Reset all" (the mockup's button keeps its natural width).
        Row(Modifier.wrapContentWidth(Alignment.Start, unbounded = true).padding(10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(
                Modifier.size(38.dp).clip(CircleShape).background(fill)
                    .border(if (applied) 1.5.dp else 1.dp, Color.White.copy(alpha = if (applied) 0.75f else 0.18f), CircleShape)
                    .clickable(onClick = vm::toggleAuto)
                    .semantics { contentDescription = "Auto enhance"; stateDescription = if (applied) "Applied" else "Not applied"; selected = applied }
                    .testTagResource(EditorTags.AUTO),
                contentAlignment = Alignment.Center,
            ) { LightlyIcon(LightlyIcons.AutoEnhance, size = 19.dp, tint = if (applied) lime else Color(0xFFF2F3F0)) }
            if (vm.canReset("all")) {
                Row(
                    Modifier.height(38.dp).clip(RoundedCornerShape(19.dp)).background(fill).border(1.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(19.dp))
                        .clickable { resetConfirmation = true }.semantics { contentDescription = "Reset all edits" }.testTagResource("editor-reset-all")
                        .padding(horizontal = 13.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    LightlyIcon(LightlyIcons.Reset, size = 15.dp, tint = Color(0xFFF2F3F0))
                    Text("Reset all", style = l2TextStyle(13.sp, FontWeight.Bold, Color(0xFFF2F3F0)), maxLines = 1, softWrap = false)
                }
            }
        }
        // The applied badge sits on the circle's bottom-end corner, 3 dp outside it.
        if (applied) Box(Modifier.padding(start = 10.dp + 38.dp - 12.dp, bottom = 10.dp - 3.dp).size(15.dp).background(lime, CircleShape), contentAlignment = Alignment.Center) {
            LightlyIcon(LightlyIcons.Check, size = 10.dp, tint = Color(0xFF121408))
        }
    }
}
