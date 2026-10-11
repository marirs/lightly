package com.lightlylabs.lightly.editor

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.shell.LightlyIcon
import com.lightlylabs.lightly.shell.LightlyIcons
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.testTagResource
import kotlin.math.roundToInt

/**
 * The colour panel behind "Custom" (owner, 2026-10-11: "exactly like iOS"). Mirrors iOS's system colour panel
 * (UIColorPickerViewController) as shown on iPhone: grabber; eyedropper · "Colours"; Grid · Spectrum · Sliders; the
 * 12 × 10 grid (greys, then nine rows dark to light); the current-colour swatch and the saved colours.
 *
 * v3 differs from iOS on purpose: the Sliders values and the hex are read-only text, not fields (owner, 2026-10-11:
 * no typed input in the colour sheet, its keyboard covered the sheet). The eyedropper picks from the sheet's photo
 * ([onPickFromPhoto]) rather than from anywhere on screen.
 */
@Composable
fun ColourPanel(hex: String, onChange: (String) -> Unit, onPickFromPhoto: () -> Unit, onClose: () -> Unit, modifier: Modifier = Modifier) {
    val palette = PanelPalette.of(lightlyColors.isDark)
    var tab by remember { mutableStateOf(PanelTab.GRID) }
    val density = LocalDensity.current
    var dragged by remember { mutableStateOf(0f) }
    Column(
        modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp)
            .offset { androidx.compose.ui.unit.IntOffset(0, dragged.roundToInt().coerceAtLeast(0)) }
            .shadow(24.dp, RoundedCornerShape(38.dp))
            .clip(RoundedCornerShape(38.dp))
            .background(palette.panel)
            .pointerInput(Unit) { detectTapGestures { } }   // taps on the panel never reach the sheet below
            .semantics { contentDescription = "Colour panel" }
            .testTagResource("colour-panel")
            .navigationBarsPadding()
            .padding(horizontal = 15.dp),
    ) {
        // Grabber: dragging it down by a third of the panel closes it, as the iOS sheet does.
        Box(
            Modifier.fillMaxWidth().height(22.dp).pointerInput(Unit) {
                detectVerticalDragGestures(
                    onDragEnd = { if (dragged > with(density) { 120.dp.toPx() }) onClose(); dragged = 0f },
                    onDragCancel = { dragged = 0f },
                ) { change, amount -> dragged += amount; change.consume() }
            },
            contentAlignment = Alignment.Center,
        ) { Box(Modifier.size(36.dp, 5.dp).clip(CircleShape).background(palette.grabber)) }
        Box(Modifier.fillMaxWidth().height(40.dp)) {
            Box(Modifier.align(Alignment.CenterStart).size(44.dp).clip(CircleShape)
                .clickable(role = Role.Button, onClick = onPickFromPhoto)
                .semantics { contentDescription = "Pick a colour from the photo" }.testTagResource("colour-panel-dropper"),
                contentAlignment = Alignment.Center) { LightlyIcon(LightlyIcons.Dropper, size = 24.dp, tint = palette.ink) }
            Text("Colours", Modifier.align(Alignment.Center), style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = palette.ink))
        }
        Spacer(Modifier.height(12.dp))
        PanelSegments(tab, palette) { tab = it }
        Spacer(Modifier.height(16.dp))
        Box(Modifier.fillMaxWidth().height(286.dp)) {
            when (tab) {
                PanelTab.GRID -> ColourGrid(hex, onChange)
                PanelTab.SPECTRUM -> ColourSpectrum(hex, onChange)
                PanelTab.SLIDERS -> ColourSliders(hex, palette, onChange)
            }
        }
        Spacer(Modifier.height(18.dp))
        Box(Modifier.fillMaxWidth().height(1.dp).background(palette.hairline))
        SwatchRow(hex, palette, onChange)
    }
}

private enum class PanelTab(val label: String) { GRID("Grid"), SPECTRUM("Spectrum"), SLIDERS("Sliders") }

/** iOS system greys (light: systemGroupedBackground family; dark: the elevated sheet greys). */
private data class PanelPalette(val panel: Color, val ink: Color, val ink2: Color, val track: Color, val segmentOn: Color,
                                val field: Color, val hairline: Color, val grabber: Color, val link: Color) {
    companion object {
        fun of(dark: Boolean) = if (dark) PanelPalette(Color(0xFF1C1C1E), Color.White, Color(0x99EBEBF5), Color(0xFF2C2C2E),
            Color(0xFF636366), Color(0xFF2C2C2E), Color(0x33FFFFFF), Color(0x66EBEBF5), Color(0xFF0A84FF))
        else PanelPalette(Color(0xFFF2F2F2), Color.Black, Color(0x993C3C43), Color(0xFFE3E3E8),
            Color.White, Color.White, Color(0x1F000000), Color(0x4D3C3C43), Color(0xFF007AFF))
    }
}

@Composable
private fun PanelSegments(tab: PanelTab, palette: PanelPalette, choose: (PanelTab) -> Unit) {
    Row(Modifier.fillMaxWidth().height(34.dp).clip(CircleShape).background(palette.track).padding(2.dp)) {
        PanelTab.entries.forEach { t ->
            val on = t == tab
            Box(Modifier.weight(1f).fillMaxHeight()
                .then(if (on) Modifier.shadow(2.dp, CircleShape).background(palette.segmentOn, CircleShape) else Modifier)
                .clip(CircleShape).clickable(role = Role.Tab) { choose(t) }
                .semantics { selected = on }.testTagResource("colour-panel-${t.name.lowercase()}"),
                contentAlignment = Alignment.Center) {
                Text(t.label, style = TextStyle(fontSize = 15.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal, color = palette.ink))
            }
        }
    }
}

/** The iOS grid: a grey row (white to black), then twelve hue columns in nine rows from dark to light. */
private val GRID: List<List<Long>> = listOf(
    listOf(0xFFFFFF, 0xEBEBEB, 0xD6D6D6, 0xC2C2C2, 0xADADAD, 0x999999, 0x858585, 0x707070, 0x5C5C5C, 0x474747, 0x333333, 0x000000),
    listOf(0x00374A, 0x011D57, 0x11053B, 0x2E063D, 0x3C071B, 0x5C0701, 0x5A1C00, 0x583300, 0x563D00, 0x666100, 0x4F5504, 0x263E0F),
    listOf(0x004D65, 0x012F7B, 0x1A0A52, 0x450D59, 0x551029, 0x831100, 0x7B2900, 0x7A4A00, 0x785800, 0x8D8602, 0x6F760A, 0x38571A),
    listOf(0x016E8F, 0x0042A9, 0x2C0977, 0x61187C, 0x791A3D, 0xB51A00, 0xAD3E00, 0xA96800, 0xA67B01, 0xC4BC00, 0x9BA50E, 0x4E7A27),
    listOf(0x008CB4, 0x0056D6, 0x371A94, 0x7A219E, 0x99244F, 0xE22400, 0xDA5100, 0xD38301, 0xD19D01, 0xF5EC00, 0xC3D117, 0x669D34),
    listOf(0x00A1D8, 0x0061FE, 0x4D22B2, 0x982ABC, 0xB92D5D, 0xFF4015, 0xFF6A00, 0xFFAB01, 0xFCC700, 0xFEFB41, 0xD9EC37, 0x76BB40),
    listOf(0x01C7FC, 0x3A87FE, 0x5E30EB, 0xBE38F3, 0xE63B7A, 0xFE6250, 0xFE8648, 0xFEB43F, 0xFECB3E, 0xFFF76B, 0xE4EF65, 0x96D35F),
    listOf(0x52D6FC, 0x74A7FF, 0x864FFE, 0xD357FE, 0xEE719E, 0xFF8C82, 0xFEA57D, 0xFEC777, 0xFED977, 0xFFF994, 0xEAF28F, 0xB1DD8B),
    listOf(0x93E3FC, 0xA7C6FF, 0xB18CFE, 0xE292FE, 0xF4A4C0, 0xFFB5AF, 0xFFC5AB, 0xFED9A8, 0xFDE4A8, 0xFFFBB9, 0xF1F7B7, 0xCDE8B5),
    listOf(0xCBF0FF, 0xD3E2FF, 0xD9C9FE, 0xEFCAFE, 0xF9D3E0, 0xFFDAD8, 0xFFE2D6, 0xFEECD4, 0xFEF1D5, 0xFDFBDD, 0xF6FAD6, 0xDEEED4),
)

private fun hexOf(rgb: Long) = "#%06X".format(rgb and 0xFFFFFF)
private fun rgbOf(hex: String): Int = runCatching { android.graphics.Color.parseColor(hex) }.getOrDefault(android.graphics.Color.WHITE) and 0xFFFFFF
private fun colourOfRgb(rgb: Int) = Color(0xFF000000.toInt() or rgb)

@Composable
private fun ColourGrid(hex: String, onChange: (String) -> Unit) {
    val rows = GRID.size; val columns = GRID[0].size
    val selected = rgbOf(hex)
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val cell = maxWidth / columns
        Box(Modifier.size(maxWidth, cell * rows).clip(RoundedCornerShape(8.dp))
            .pointerInput(Unit) {
                fun pick(p: Offset) {
                    val c = (p.x / size.width * columns).toInt().coerceIn(0, columns - 1)
                    val r = (p.y / size.height * rows).toInt().coerceIn(0, rows - 1)
                    onChange(hexOf(GRID[r][c]))
                }
                detectTapGestures(onTap = ::pick)
            }
            .pointerInput(Unit) {
                fun pick(p: Offset) {
                    val c = (p.x / size.width * columns).toInt().coerceIn(0, columns - 1)
                    val r = (p.y / size.height * rows).toInt().coerceIn(0, rows - 1)
                    onChange(hexOf(GRID[r][c]))
                }
                detectDragGestures(onDragStart = ::pick) { change, _ -> pick(change.position); change.consume() }
            }
            .semantics { contentDescription = "Colour grid" }.testTagResource("colour-panel-grid-cells")) {
            Canvas(Modifier.fillMaxSize()) {
                val w = size.width / columns; val h = size.height / rows
                GRID.forEachIndexed { r, row -> row.forEachIndexed { c, rgb ->
                    drawRect(colourOfRgb(rgb.toInt()), Offset(c * w, r * h), Size(w + 0.5f, h + 0.5f))
                } }
            }
            // The chosen cell: a white rounded frame, as iOS draws it.
            GRID.forEachIndexed { r, row -> row.forEachIndexed { c, rgb ->
                if (rgb.toInt() == selected) Box(Modifier.offset(cell * c, cell * r).size(cell).border(3.dp, Color.White, RoundedCornerShape(4.dp)))
            } }
        }
    }
}

/** The iOS spectrum: hue top to bottom (red … red), white on the left to black on the right through the full colour. */
@Composable
private fun ColourSpectrum(hex: String, onChange: (String) -> Unit) {
    val hues = listOf(0f, 60f, 120f, 180f, 240f, 300f, 360f).map { Color.hsv(it % 360f, 1f, 1f) }
    var thumb by remember { mutableStateOf<Offset?>(null) }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val w = constraints.maxWidth.toFloat(); val h = constraints.maxHeight.toFloat()
        fun colourAt(p: Offset): String {
            val x = (p.x / w).coerceIn(0f, 1f); val y = (p.y / h).coerceIn(0f, 1f)
            val hue = y * 360f % 360f
            // Left half: white to the full hue; right half: the full hue to black.
            val (s, v) = if (x < 0.5f) (x * 2f) to 1f else 1f to (1f - (x - 0.5f) * 2f)
            return "#%06X".format(android.graphics.Color.HSVToColor(floatArrayOf(hue, s, v)) and 0xFFFFFF)
        }
        Box(Modifier.fillMaxSize().clip(RoundedCornerShape(8.dp))
            .background(Brush.verticalGradient(hues))
            .background(Brush.horizontalGradient(0f to Color.White, 0.5f to Color.Transparent))
            .background(Brush.horizontalGradient(0.5f to Color.Transparent, 1f to Color.Black))
            .pointerInput(Unit) { detectTapGestures { p -> thumb = p; onChange(colourAt(p)) } }
            .pointerInput(Unit) {
                detectDragGestures(onDragStart = { p -> thumb = p; onChange(colourAt(p)) }) { change, _ ->
                    val p = Offset(change.position.x.coerceIn(0f, w), change.position.y.coerceIn(0f, h))
                    thumb = p; onChange(colourAt(p)); change.consume()
                }
            }
            .semantics { contentDescription = "Colour spectrum" }.testTagResource("colour-panel-spectrum-area"))
        val at = thumb ?: Offset(0f, h)
        val d = LocalDensity.current
        Box(Modifier.offset(with(d) { (at.x).toDp() - 14.dp }, with(d) { (at.y).toDp() - 14.dp }).size(28.dp)
            .shadow(3.dp, CircleShape).background(colourOfRgb(rgbOf(hex)), CircleShape).border(3.dp, Color.White, CircleShape))
    }
}

/** Red, green and blue: each a capsule track running from the colour without that channel to the colour with it full. */
@Composable
private fun ColourSliders(hex: String, palette: PanelPalette, onChange: (String) -> Unit) {
    val rgb = rgbOf(hex)
    val channels = listOf("RED" to 16, "GREEN" to 8, "BLUE" to 0)
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        channels.forEach { (name, shift) ->
            val value = (rgb shr shift) and 0xFF
            val without = rgb and (0xFF shl shift).inv()
            Text(name, style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = palette.ink2))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                BoxWithConstraints(Modifier.weight(1f).height(32.dp)) {
                    val width = constraints.maxWidth.toFloat()
                    fun set(x: Float) {
                        val v = ((x / width).coerceIn(0f, 1f) * 255).roundToInt()
                        onChange("#%06X".format(without or (v shl shift)))
                    }
                    Box(Modifier.fillMaxSize().clip(CircleShape)
                        .background(Brush.horizontalGradient(listOf(colourOfRgb(without), colourOfRgb(without or (0xFF shl shift)))))
                        .pointerInput(Unit) { detectTapGestures { set(it.x) } }
                        .pointerInput(Unit) { detectDragGestures(onDragStart = { set(it.x) }) { change, _ -> set(change.position.x); change.consume() } }
                        .semantics { contentDescription = "${name.lowercase()} $value" }
                        .testTagResource("colour-panel-${name.lowercase()}"))
                    val travel = maxWidth - 32.dp
                    Box(Modifier.offset(travel * (value / 255f)).size(32.dp).shadow(2.dp, CircleShape)
                        .background(colourOfRgb(rgb), CircleShape).border(3.dp, Color.White, CircleShape))
                }
                ReadOnlyValue(value.toString(), palette, Modifier.width(72.dp))
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.End) {
            Text("sRGB Hex Colour #", style = TextStyle(fontSize = 17.sp, color = palette.link))
            Spacer(Modifier.width(14.dp))
            ReadOnlyValue("%06X".format(rgb), palette, Modifier.width(96.dp))
        }
    }
}

@Composable
private fun ReadOnlyValue(text: String, palette: PanelPalette, modifier: Modifier) {
    Box(modifier.height(34.dp).clip(RoundedCornerShape(10.dp)).background(palette.field), contentAlignment = Alignment.Center) {
        Text(text, style = TextStyle(fontSize = 17.sp, color = palette.ink, textAlign = TextAlign.Center))
    }
}

/** The current colour (a rounded swatch) and the saved colours (circles), as at the foot of the iOS panel. */
@Composable
private fun SwatchRow(hex: String, palette: PanelPalette, onChange: (String) -> Unit) {
    val saved = listOf("#000000", "#0061FE", "#34C759", "#FFCC00", "#FF3B30")
    Row(Modifier.fillMaxWidth().padding(top = 16.dp, bottom = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(76.dp, 34.dp).clip(RoundedCornerShape(10.dp)).background(colourOfRgb(rgbOf(hex)))
            .border(1.dp, palette.hairline, RoundedCornerShape(10.dp)).semantics { contentDescription = "Current colour $hex" })
        Spacer(Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            saved.forEach { c ->
                Box(Modifier.size(28.dp).clip(CircleShape).background(colourOfRgb(rgbOf(c)))
                    .clickable(role = Role.Button) { onChange(c) }.semantics { contentDescription = "Colour $c" })
            }
        }
    }
}
