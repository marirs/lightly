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
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.develop.InkKind
import com.lightlylabs.lightly.develop.InkOverlay
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.shell.LightlyIcon
import com.lightlylabs.lightly.shell.LightlyIcons
import com.lightlylabs.lightly.shell.l2TextStyle
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.testTagResource

object InkGalleryTags {
    const val GALLERY = "effects-ink-gallery"
    /** A tile: `none`, or the ink id. */
    fun tile(inkId: String?) = "effects-ink-${inkId ?: "none"}"
}

/**
 * Effects › Ink gallery (owner-approved 2026-10-31, docs/ui/proposals/ink-2026-10-31 `inkGallery`, screens fx-ink-none and
 * fx-ink): built as the Light Leaks gallery. "None", then every ink of the pack in pack order, each this photo through that
 * ink (a stroke ink on the chosen paper, an overlay ink multiplied over it), on two rows filled column by column (96 dp
 * columns, 12 dp column and 10 dp row gaps, the end fading while inks lie past it). Without a pack only None is offered.
 */
@Composable
fun InkGallery(vm: EditorViewModel, ui: EditorUiState, ink: com.lightlylabs.lightly.session.InkTool?) {
    val inks = vm.inkPackEntries
    var photo by remember { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(ui.original) { photo = vm.leakTilePhoto()?.toBitmap()?.asImageBitmap() }
    val paper = InkOverlay.colour(ink?.paper ?: com.lightlylabs.lightly.session.InkTool.DEFAULT_PAPER).let { Color(it[0], it[1], it[2]) }
    val grid = rememberLazyGridState()
    // Mockup: drawn scrolled so the chosen ink is in view (`fx-ink-bloom`); None is item 0, two rows per column.
    LaunchedEffect(Unit) {
        val index = inks.indexOfFirst { it.id == ink?.id }
        if (index >= 0) grid.scrollToItem(((index + 1) / 2 * 2 - 2).coerceAtLeast(0))
    }
    LazyHorizontalGrid(
        GridCells.Fixed(2),
        state = grid,
        modifier = Modifier.fillMaxWidth().height(INK_ROW_HEIGHT * 2 + 10.dp).fadeEnd(grid.canScrollForward).testTagResource(InkGalleryTags.GALLERY),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item(key = "none") { InkTile(vm, null, null, "None", ink == null, photo, paper) }
        items(inks, key = { it.id }) { entry -> InkTile(vm, entry.id, entry.kind, entry.name, entry.id == ink?.id, photo, paper) }
    }
}

/** The compact preset gallery's row, as the leak gallery: a 62 dp thumbnail, 5 dp, the 11.5 sp name. */
private val INK_ROW_HEIGHT = 84.dp

/**
 * An ink tile, drawn as a leak tile (LeakTile): a 62 dp thumbnail with 14 dp corners; a stroke ink is the paper, then the photo
 * (cover) kept only where the stroke is, the stroke fitted whole with a 6 % margin (mockup `inkLayers`); an overlay ink is the
 * photo with the ink multiplied over it. Selected: the 2 dp accent ring and the 20 dp lime check badge; the name below.
 */
@Composable
private fun InkTile(vm: EditorViewModel, inkId: String?, kind: InkKind?, name: String, selected: Boolean, photo: ImageBitmap?, paper: Color) {
    var thumbnail by remember(inkId) { mutableStateOf<ImageBitmap?>(null) }
    if (inkId != null) LaunchedEffect(inkId) {
        thumbnail = vm.inkThumbnail(inkId)?.let { if (kind == InkKind.STROKE) alphaMask(it) else it }?.toBitmap()?.asImageBitmap()
    }
    val colors = lightlyColors
    val shape = RoundedCornerShape(14.dp)
    Column(
        Modifier.width(96.dp).clickable { vm.chooseInk(inkId) }
            .semantics { this.selected = selected; contentDescription = name }
            .testTagResource(InkGalleryTags.tile(inkId)),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Box(Modifier.fillMaxWidth().height(62.dp).clip(shape).background(colors.chip)) {
            val mask = thumbnail
            if (kind == InkKind.STROKE && mask != null) {
                Box(Modifier.fillMaxSize().background(paper))
                // Offscreen, so DstIn keeps the photo only where the stroke is without cutting the paper below.
                Canvas(Modifier.fillMaxSize().graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }) {
                    photo?.let { drawCover(it, BlendMode.SrcOver) }
                    drawContain(mask, InkOverlay.STROKE_FIT.toFloat(), BlendMode.DstIn)
                }
            } else {
                Canvas(Modifier.fillMaxSize()) {
                    photo?.let { drawCover(it, BlendMode.SrcOver) }
                    if (kind == InkKind.OVERLAY) mask?.let { drawCover(it, BlendMode.Multiply) }
                }
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

/** A grey stroke mask as white with alpha = grey, for DstIn (the photo shows where the mask is white). */
private fun alphaMask(grey: Rgba8Image): Rgba8Image {
    val out = ByteArray(grey.width * grey.height * 4)
    for (i in 0 until grey.width * grey.height) {
        out[i * 4] = -1; out[i * 4 + 1] = -1; out[i * 4 + 2] = -1
        out[i * 4 + 3] = grey.pixels[i * 4]
    }
    return Rgba8Image(grey.width, grey.height, out)
}

/** CSS `background: center/cover`: the centred crop of [image] with the tile's aspect, drawn over the whole tile. */
private fun DrawScope.drawCover(image: ImageBitmap, blendMode: BlendMode) {
    val scale = maxOf(size.width / image.width, size.height / image.height)
    val sourceWidth = (size.width / scale).toInt().coerceIn(1, image.width)
    val sourceHeight = (size.height / scale).toInt().coerceIn(1, image.height)
    drawImage(image, srcOffset = IntOffset((image.width - sourceWidth) / 2, (image.height - sourceHeight) / 2),
        srcSize = IntSize(sourceWidth, sourceHeight), dstSize = IntSize(size.width.toInt(), size.height.toInt()), blendMode = blendMode)
}

/** CSS `mask-size: contain` inside [fit] of the tile, centred. Outside the image nothing passes DstIn, so the rest is paper. */
private fun DrawScope.drawContain(image: ImageBitmap, fit: Float, blendMode: BlendMode) {
    val scale = minOf(size.width * fit / image.width, size.height * fit / image.height)
    val w = (image.width * scale).toInt().coerceAtLeast(1)
    val h = (image.height * scale).toInt().coerceAtLeast(1)
    // DstIn clears whatever the mask does not cover, so the mask is drawn over the whole tile: transparent outside it.
    drawRect(Color.Transparent, blendMode = BlendMode.Clear, topLeft = androidx.compose.ui.geometry.Offset.Zero,
        size = androidx.compose.ui.geometry.Size(size.width, (size.height - h) / 2))
    drawRect(Color.Transparent, blendMode = BlendMode.Clear, topLeft = androidx.compose.ui.geometry.Offset(0f, (size.height + h) / 2),
        size = androidx.compose.ui.geometry.Size(size.width, (size.height - h) / 2 + 1))
    drawRect(Color.Transparent, blendMode = BlendMode.Clear, topLeft = androidx.compose.ui.geometry.Offset.Zero,
        size = androidx.compose.ui.geometry.Size((size.width - w) / 2, size.height))
    drawRect(Color.Transparent, blendMode = BlendMode.Clear, topLeft = androidx.compose.ui.geometry.Offset((size.width + w) / 2, 0f),
        size = androidx.compose.ui.geometry.Size((size.width - w) / 2 + 1, size.height))
    drawImage(image, dstOffset = IntOffset(((size.width - w) / 2).toInt(), ((size.height - h) / 2).toInt()), dstSize = IntSize(w, h), blendMode = blendMode)
}
