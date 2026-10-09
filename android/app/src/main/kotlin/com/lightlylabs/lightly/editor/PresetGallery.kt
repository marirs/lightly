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
    if (expanded) LazyVerticalGrid(GridCells.Fixed(2), state = grid, modifier = Modifier.fillMaxWidth().height(390.dp).nestedScroll(collapseScroll).then(accessibility).testTagResource("develop-gallery-expanded"), contentPadding = PaddingValues(12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(16.dp), content = tiles)
    else LazyHorizontalGrid(GridCells.Fixed(2), state = grid, modifier = Modifier.fillMaxWidth().height(220.dp).then(expandGesture).then(accessibility).testTagResource("develop-gallery-compact"), contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp), content = tiles)
}

@Composable private fun PresetTile(vm: EditorViewModel, preset: LookPreset?, expanded: Boolean, selected: Boolean, context: Any?) {
    var rendered by remember(preset?.id,context) { mutableStateOf<Rgba8Image?>(null) }
    LaunchedEffect(preset?.id,context) { rendered = vm.presetThumbnail(preset) }
    Column(Modifier.then(if(expanded) Modifier.fillMaxWidth() else Modifier.width(96.dp)).clickable { vm.selectThumbnail(preset) }
        .semantics { this.selected = selected }.testTagResource("develop-thumbnail-${preset?.id ?: "original"}"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().height(if(expanded) 142.dp else 76.dp).clip(RoundedCornerShape(7.dp))
            .background(lightlyColors.bg2).border(if(selected) 2.dp else 0.dp, if(selected) lightlyColors.sel else lightlyColors.bg2, RoundedCornerShape(7.dp))) {
            val bitmap = remember(rendered) { rendered?.toBitmap()?.asImageBitmap() }
            if(bitmap != null) Image(bitmap, preset?.displayName ?: "Original", Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            else CircularProgressIndicator(Modifier.size(18.dp).align(Alignment.Center), strokeWidth = 2.dp)
            if(selected) Text("✓", Modifier.align(Alignment.TopEnd).padding(5.dp).background(lightlyColors.sel,RoundedCornerShape(20.dp)).padding(horizontal=5.dp), color=lightlyColors.bg)
        }
        Text(preset?.displayName ?: "Original", style=lightlyTextStyle(12.sp,color=lightlyColors.ink),maxLines=1)
    }
}
