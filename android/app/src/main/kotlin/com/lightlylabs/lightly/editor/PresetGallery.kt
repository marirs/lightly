package com.lightlylabs.lightly.editor

import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.nestedscroll.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.develop.LookPreset
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.shell.*

@Composable
fun PresetGallery(vm: EditorViewModel, model: DevelopPanelModel, expanded: Boolean) {
    val grid = rememberLazyGridState()
    val threshold = with(LocalDensity.current) { 60.dp.toPx() }
    var pull by remember { mutableFloatStateOf(0f) }
    val collapseScroll = remember(grid, threshold) { object : NestedScrollConnection {
        override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
            if (source == NestedScrollSource.UserInput && available.y > 0 && !grid.canScrollBackward) {
                pull += available.y
                return Offset(0f, available.y)
            }
            return Offset.Zero
        }
        override suspend fun onPreFling(available: Velocity): Velocity {
            if (pull > threshold) vm.setPresetExpanded(false)
            pull = 0f
            return Velocity.Zero
        }
    } }
    val expandGesture = Modifier.pointerInput(Unit) {
        var drag = 0f
        detectVerticalDragGestures(onDragStart = { drag = 0f }) { change, dy ->
            drag += dy
            if (drag < -32.dp.toPx()) { change.consume(); vm.setPresetExpanded(true) }
        }
    }
    val accessibility = Modifier.semantics {
        customActions = listOf(CustomAccessibilityAction(if(expanded) "Collapse presets" else "Expand presets") { vm.setPresetExpanded(!expanded); true })
    }
    LaunchedEffect(model.categoryId) { grid.scrollToItem(0) }
    val ui by vm.uiState.collectAsState()
    val context = ui.session?.current?.copy(look = null, revision = 0)
    val tiles: LazyGridScope.() -> Unit = {
        item(key = "original") { PresetTile(vm, null, expanded, ui.session?.current?.look == null, context) }
        items(model.presets, key = { it.id }) { preset -> PresetTile(vm,preset,expanded,ui.session?.current?.look?.lookId == preset.id,context) }
    }
    // Lightly 2: compact = two 84 dp rows, 96 dp columns, 10 dp row and 12 dp column gaps, the end fading while presets lie past it; expanded = two
    // equal columns, 14 dp row and 12 dp column gaps, 142 dp thumbnails.
    if (expanded) LazyVerticalGrid(GridCells.Fixed(2), state = grid, modifier = Modifier.fillMaxWidth().height(390.dp).nestedScroll(collapseScroll).then(accessibility).testTagResource("develop-gallery-expanded"), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(14.dp), content = tiles)
    else LazyHorizontalGrid(GridCells.Fixed(2), state = grid, modifier = Modifier.fillMaxWidth().height(84.dp * 2 + 10.dp).fadeEnd(grid.canScrollForward).then(expandGesture).then(accessibility).testTagResource("develop-gallery-compact"), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp), content = tiles)
}

/**
 * A gallery tile: the thumbnail (62 dp compact, 142 dp expanded; 14 dp corners), the selected one with a 2 dp inset accent
 * ring and a 20 dp lime check badge 6 dp in; the name below (11.5 sp; bold ink when selected, medium ink2), 5 dp between.
 */
@Composable private fun PresetTile(vm: EditorViewModel, preset: LookPreset?, expanded: Boolean, selected: Boolean, context: Any?) {
    // Keyed by the preset only: when the edit under the thumbnails changes (the Auto wand, another tool), the tile keeps
    // its picture until the new one is ready instead of blanking to a spinner (owner report, 2026-10-11).
    var rendered by remember(preset?.id) { mutableStateOf<Rgba8Image?>(null) }
    LaunchedEffect(preset?.id, context) { vm.presetThumbnail(preset)?.let { rendered = it } }
    val colors = lightlyColors
    val shape = RoundedCornerShape(14.dp)
    Column(Modifier.then(if (expanded) Modifier.fillMaxWidth() else Modifier.width(96.dp)).clickable { vm.selectThumbnail(preset) }
        .semantics { this.selected = selected; contentDescription = preset?.displayName ?: "Original" }
        .testTagResource("develop-thumbnail-${preset?.id ?: "original"}"), verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Box(Modifier.fillMaxWidth().height(if (expanded) 142.dp else 62.dp).clip(shape).background(colors.chip)) {
            val bitmap = remember(rendered) { rendered?.toBitmap()?.asImageBitmap() }
            if (bitmap != null) Image(bitmap, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            else CircularProgressIndicator(Modifier.size(18.dp).align(Alignment.Center), strokeWidth = 2.dp, color = colors.ink3)
            if (selected) {
                Box(Modifier.fillMaxSize().border(2.dp, colors.sel, shape))
                Box(Modifier.align(Alignment.TopEnd).padding(6.dp).size(20.dp).background(colors.accent, androidx.compose.foundation.shape.CircleShape), contentAlignment = Alignment.Center) {
                    LightlyIcon(LightlyIcons.Check, size = 13.dp, tint = colors.onAccent)
                }
            }
        }
        Text(preset?.displayName ?: "Original", style = l2TextStyle(11.5.sp, if (selected) androidx.compose.ui.text.font.FontWeight.Bold else androidx.compose.ui.text.font.FontWeight.Medium,
            if (selected) colors.ink else colors.ink2), maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
    }
}
