package com.lightlylabs.lightly.editor

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyHorizontalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.session.LeakStyle
import com.lightlylabs.lightly.shell.LightlyIcon
import com.lightlylabs.lightly.shell.LightlyIcons
import com.lightlylabs.lightly.shell.l2TextStyle
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.testTagResource

object LeakGalleryTags {
    const val GALLERY = "effects-leak-gallery"
    /** A tile: `none`, or the leak id. */
    fun tile(leakId: String?) = "effects-leak-${leakId ?: "none"}"
}

/**
 * Effects › Light Leaks (mockup `leakGallery`, owner 2026-10-11; screens fx-leak, fx-leak-none): "None", then every leak of the
 * pack in pack order, on two rows filled column by column like the compact preset gallery (96 dp columns, 12 dp column and 10 dp
 * row gaps, the end fading). With no pack in the build only None is offered.
 */
@Composable
fun LeakGallery(vm: EditorViewModel, ui: EditorUiState, leak: com.lightlylabs.lightly.session.LightLeak) {
    // A leak chosen and on is selected; off is None. An earlier edit's drawn style (no longer offered) selects no tile.
    val chosen: String? = if (leak.enabled) (leak.style as? LeakStyle.Image)?.leakId else null
    val noneSelected = !leak.enabled
    val leaks = vm.leakPackEntries
    // The photo under every tile, once per open photo (not per tile).
    var photo by remember { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(ui.original) { photo = vm.leakTilePhoto()?.toBitmap()?.asImageBitmap() }
    LazyHorizontalGrid(
        GridCells.Fixed(2),
        modifier = Modifier.fillMaxWidth().height(LEAK_ROW_HEIGHT * 2 + 10.dp).fadeEnd().testTagResource(LeakGalleryTags.GALLERY),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item(key = "none") { LeakTile(vm, null, "None", noneSelected, photo) }
        items(leaks, key = { it.id }) { entry -> LeakTile(vm, entry.id, entry.name, entry.id == chosen, photo) }
    }
}

/** The compact preset gallery's row (PresetGallery: two 84 dp rows): a 62 dp thumbnail, 5 dp, the 11.5 sp name. */
private val LEAK_ROW_HEIGHT = 84.dp

/**
 * A leak tile, as a compact preset tile: 96 dp wide, a 62 dp thumbnail with 14 dp corners showing the photo (cover) with the
 * leak's thumbnail screened over it at 85 % (mockup `mix-blend-mode: screen; opacity: 0.85`); selected, a 2 dp inset accent
 * ring and the 20 dp lime check badge 6 dp in; the name below (bold ink when selected, medium ink2), 5 dp between.
 */
@Composable
private fun LeakTile(vm: EditorViewModel, leakId: String?, name: String, selected: Boolean, photo: ImageBitmap?) {
    var leakThumbnail by remember(leakId) { mutableStateOf<ImageBitmap?>(null) }
    if (leakId != null) LaunchedEffect(leakId) { leakThumbnail = vm.leakThumbnail(leakId)?.toBitmap()?.asImageBitmap() }
    val colors = lightlyColors
    val shape = RoundedCornerShape(14.dp)
    Column(
        Modifier.width(96.dp).clickable { vm.chooseLeak(leakId) }
            .semantics { this.selected = selected; contentDescription = name }
            .testTagResource(LeakGalleryTags.tile(leakId)),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Box(Modifier.fillMaxWidth().height(62.dp).clip(shape).background(colors.chip)) {
            Canvas(Modifier.fillMaxSize()) {
                photo?.let { drawCover(it, alpha = 1f, blendMode = BlendMode.SrcOver) }
                leakThumbnail?.let { drawCover(it, alpha = LEAK_TILE_OPACITY, blendMode = BlendMode.Screen) }
            }
            if (selected) {
                Box(Modifier.fillMaxSize().border(2.dp, colors.sel, shape))
                Box(Modifier.align(Alignment.TopEnd).padding(6.dp).size(20.dp).background(colors.accent, CircleShape), contentAlignment = Alignment.Center) {
                    LightlyIcon(LightlyIcons.Check, size = 13.dp, tint = colors.onAccent)
                }
            }
        }
        Text(name, style = l2TextStyle(11.5.sp, if (selected) FontWeight.Bold else FontWeight.Medium, if (selected) colors.ink else colors.ink2),
            maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Mockup `opacity: 0.85` on the screened leak. */
private const val LEAK_TILE_OPACITY = 0.85f

/** CSS `background: center/cover`: the centred crop of [image] with the tile's aspect, drawn over the whole tile. */
private fun DrawScope.drawCover(image: ImageBitmap, alpha: Float, blendMode: BlendMode) {
    val scale = maxOf(size.width / image.width, size.height / image.height)
    val sourceWidth = (size.width / scale).toInt().coerceIn(1, image.width)
    val sourceHeight = (size.height / scale).toInt().coerceIn(1, image.height)
    drawImage(
        image,
        srcOffset = IntOffset((image.width - sourceWidth) / 2, (image.height - sourceHeight) / 2),
        srcSize = IntSize(sourceWidth, sourceHeight),
        dstSize = IntSize(size.width.toInt(), size.height.toInt()),
        alpha = alpha,
        blendMode = blendMode,
    )
}
