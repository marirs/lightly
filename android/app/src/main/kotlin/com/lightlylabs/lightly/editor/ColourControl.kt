package com.lightlylabs.lightly.editor

import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.*
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.shell.*
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.graphics.asImageBitmap
import kotlin.math.roundToInt

/** `COLOURS` in the mockup: the one colour strip, in order. */
val STRIP_COLOURS = listOf(
    "White" to "#FFFFFF", "Warm white" to "#F4F1EC", "Light stone" to "#D9D4CC", "Cool grey" to "#C4C9CE",
    "Blue grey" to "#9AA3A8", "Slate" to "#3C4A55", "Charcoal" to "#1F2328", "Black" to "#0B0B0C",
    "Cream" to "#F3E3C3", "Mustard" to "#D9A82E", "Tan" to "#C9A27E", "Terracotta" to "#C2684A",
    "Rust" to "#8A5A44", "Blush" to "#E8B4B0", "Rose" to "#B5536B", "Plum" to "#5B3A6B",
    "Lilac" to "#B8A9D9", "Sky" to "#A9D3EE", "Ocean" to "#2F6F9F", "Navy" to "#1E2F4D",
    "Mint" to "#BFE3D0", "Sage" to "#A8B89A", "Olive" to "#6E6B3A", "Forest green" to "#4E6B5A",
)

/**
 * The one colour control (Lightly 2 `colourStrip`), identical wherever a colour is chosen: "Title · Name" (13 sp semibold
 * ink2, the name in ink) and "More colours ›"; then the 24-colour strip, 40 dp tall, a 22 dp accent ring on the chosen
 * colour. Dragging previews; lifting commits one undo step. "More colours" opens the colour sheet (any colour).
 */
@Composable
fun ColourControl(title: String = "Colour", selected: String, photo: Rgba8Image?, tag: String, choose: (String) -> Unit, previewPhoto: Rgba8Image? = photo, preview: ((String) -> Unit)? = null, cancel: (() -> Unit)? = null) {
    var open by remember { mutableStateOf(false) }
    var dragIndex by remember { mutableStateOf<Int?>(null) }
    val colors = lightlyColors
    val selectedIndex = STRIP_COLOURS.indexOfFirst { it.second.equals(selected, ignoreCase = true) }.takeIf { it >= 0 }
    val shownIndex = dragIndex ?: selectedIndex
    // A colour from the sheet that is not on the strip is named by its hex value and has no ring.
    val name = shownIndex?.let { STRIP_COLOURS[it].first } ?: selected.uppercase()
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                androidx.compose.ui.text.buildAnnotatedString {
                    append("$title · ")
                    pushStyle(androidx.compose.ui.text.SpanStyle(color = colors.ink)); append(name); pop()
                },
                style = l2TextStyle(13.sp, androidx.compose.ui.text.font.FontWeight.SemiBold, colors.ink2), modifier = Modifier.weight(1f),
            )
            LinkButton("More colours", { open = true }, icon = LightlyIcons.Chevron, iconTrailing = true, tag = "$tag-more")
        }
        BoxWithConstraints(
            Modifier.fillMaxWidth().padding(horizontal = 2.dp).height(40.dp)
                // TalkBack adjusts the strip like a slider: its value is the colour's index, spoken by name.
                .semantics {
                    contentDescription = title; stateDescription = name
                    progressBarRangeInfo = ProgressBarRangeInfo((selectedIndex ?: 0).toFloat(), 0f..STRIP_COLOURS.lastIndex.toFloat(), steps = STRIP_COLOURS.size - 2)
                    setProgress { value -> choose(STRIP_COLOURS[value.roundToInt().coerceIn(0, STRIP_COLOURS.lastIndex)].second); true }
                }
                .testTagResource("$tag-strip")
                .pointerInput(Unit) {
                    fun indexAt(x: Float) = (x / size.width * STRIP_COLOURS.size).toInt().coerceIn(0, STRIP_COLOURS.lastIndex)
                    detectDragGestures(
                        onDragStart = { o -> val i = indexAt(o.x); dragIndex = i; preview?.invoke(STRIP_COLOURS[i].second) },
                        onDragEnd = { dragIndex?.let { choose(STRIP_COLOURS[it].second) }; dragIndex = null },
                        onDragCancel = { dragIndex = null; cancel?.invoke() },
                    ) { change, _ ->
                        val i = indexAt(change.position.x)
                        if (i != dragIndex) { dragIndex = i; preview?.invoke(STRIP_COLOURS[i].second) }
                        change.consume()
                    }
                }
                .pointerInput(Unit) {
                    detectTapGestures { o -> choose(STRIP_COLOURS[(o.x / size.width * STRIP_COLOURS.size).toInt().coerceIn(0, STRIP_COLOURS.lastIndex)].second) }
                },
        ) {
            val segment = maxWidth / STRIP_COLOURS.size
            Row(Modifier.fillMaxSize().clip(RoundedCornerShape(20.dp)).border(1.dp, colors.hair, RoundedCornerShape(20.dp))) {
                STRIP_COLOURS.forEach { (_, hex) -> Box(Modifier.weight(1f).fillMaxHeight().background(colourOf(hex))) }
            }
            if (shownIndex != null) {
                Box(
                    Modifier.offset(x = segment * (shownIndex + 0.5f) - 11.dp, y = (-5).dp).size(width = 22.dp, height = 50.dp)
                        .border(2.dp, colors.sheet, RoundedCornerShape(13.dp)).padding(1.dp)
                        .border(3.dp, colors.sel, RoundedCornerShape(12.dp)),
                )
            }
        }
    }
    if (open) ColourSheet(title, selected, photo, previewPhoto, preview, choose, onClose = { cancelled -> if (cancelled) cancel?.invoke(); open = false })
}

/**
 * The colour sheet behind "More colours" (`colourSheet`), the same from every colour control: sheetHead (Cancel · title ·
 * Done), the live preview (170 dp, 18 dp corners, stage fill), "From your photo", "Paper & ink", "Earth" (five 40 dp
 * swatches, 12 dp corners, 9 dp gaps, a lime check on the chosen one), the Custom row (opens the colour
 * panel below it) and "Recent".
 */
@Composable
private fun ColourSheet(title: String, selected: String, photo: Rgba8Image?, previewPhoto: Rgba8Image?, preview: ((String) -> Unit)?, choose: (String) -> Unit, onClose: (cancelled: Boolean) -> Unit) {
    var hex by remember { mutableStateOf(selected.uppercase()) }
    var custom by remember { mutableStateOf(false) }
    val prefs = LocalContext.current.getSharedPreferences("lightly-colours", 0)
    val recent = remember { prefs.getString("recent", "#FFFFFF,#111111,#F4F1EC")!!.split(',') }
    val valid = Regex("#[0-9A-Fa-f]{6}").matches(hex)
    LaunchedEffect(hex) { if (valid) preview?.invoke(hex.uppercase()) }
    val palette = remember(photo) { photo?.let(::photoPalette).orEmpty() }
    val colors = lightlyColors
    androidx.compose.ui.window.Dialog(onDismissRequest = { onClose(true) },
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        val big = LocalConfiguration.current.screenWidthDp >= 600
        L2Sheet(big, heightFraction = if (big) 0.92f else 0.9f, onDismiss = { onClose(true) }) {
            L2SheetHead(title,
                leading = { L2TextButton("Cancel", "colour-cancel") { onClose(true) } },
                trailing = { L2TextButton("Done", "colour-done", bold = true, enabled = valid) {
                    val c = hex.uppercase(); prefs.edit().putString("recent", (listOf(c) + recent.filter { it != c }).take(8).joinToString(",")).apply()
                    choose(c); onClose(false)
                } })
            Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp).padding(bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(Modifier.fillMaxWidth().height(if (big) 200.dp else 170.dp).clip(RoundedCornerShape(18.dp)).background(colors.canvas).padding(8.dp), contentAlignment = Alignment.Center) {
                    val shown = previewPhoto ?: photo
                    if (shown != null) {
                        val bitmap = remember(shown) { shown.toBitmap().asImageBitmap() }
                        Image(bitmap, "Preview", Modifier.fillMaxSize())
                    }
                }
                ColourPalette("From your photo", palette, hex) { hex = it }
                ColourPalette("Paper & ink", listOf("#FFFFFF", "#ECE8DF", "#D4C9B5", "#9C9284", "#242423"), hex) { hex = it }
                ColourPalette("Earth", listOf("#DFC7AE", "#B98767", "#914E3E", "#66775D", "#334538"), hex) { hex = it }
                // Custom (owner, 2026-10-11): tapping the row opens the colour panel. No hex field (its keyboard covered the
                // sheet) and no eyedropper button.
                Row(Modifier.fillMaxWidth().height(44.dp).clickable(role = androidx.compose.ui.semantics.Role.Button) { custom = !custom }
                    .semantics(mergeDescendants = true) { contentDescription = "Custom" }.testTagResource("colour-custom"),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(Modifier.size(40.dp).clip(CircleShape)
                        .background(Brush.sweepGradient(listOf(Color(0xFFFF4444), Color(0xFFFFDD44), Color(0xFF44FF88), Color(0xFF44DDFF), Color(0xFF8844FF), Color(0xFFFF44CC), Color(0xFFFF4444)))))
                    Text("Custom", style = l2TextStyle(14.sp, androidx.compose.ui.text.font.FontWeight.SemiBold, colors.ink), modifier = Modifier.weight(1f))
                }
                if (custom) HsvPicker(hex) { hex = it }
                ColourPalette("Recent", recent, hex, fixed = true) { hex = it }
            }
        }
    }
}

/** The custom picker under the colour wheel: saturation and brightness, then hue. */
@Composable
private fun HsvPicker(hex: String, onChange: (String) -> Unit) {
    val hsv = remember(hex) { FloatArray(3).also { android.graphics.Color.colorToHSV(runCatching { android.graphics.Color.parseColor(hex) }.getOrDefault(android.graphics.Color.BLACK), it) } }
    fun setHSV(h: Float, s: Float, v: Float) { onChange("#%06X".format(android.graphics.Color.HSVToColor(floatArrayOf(h, s, v)) and 0xffffff)) }
    val hue by rememberUpdatedState(hsv[0])
    Box(Modifier.fillMaxWidth().height(100.dp).clip(RoundedCornerShape(12.dp))
        .background(Brush.horizontalGradient(listOf(Color.White, Color.hsv(hsv[0], 1f, 1f))))
        .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black)))
        .pointerInput(Unit) { detectTapGestures { p -> setHSV(hue, (p.x / size.width).coerceIn(0f, 1f), (1 - p.y / size.height).coerceIn(0f, 1f)) } }
        .pointerInput(Unit) {
            fun pick(p: androidx.compose.ui.geometry.Offset) { setHSV(hue, (p.x / size.width).coerceIn(0f, 1f), (1 - p.y / size.height).coerceIn(0f, 1f)) }
            detectDragGestures(onDragStart = ::pick) { change, _ -> pick(change.position); change.consume() }
        }.semantics { contentDescription = "Saturation and brightness" })
    SliderRow("Hue", hsv[0].toDouble(), 0.0, 359.0, onDrag = { setHSV(it.toFloat(), hsv[1], hsv[2]) }, onRelease = { setHSV(it.toFloat(), hsv[1], hsv[2]) }, tag = "colour-hue")
}

@Composable private fun ColourPalette(title: String, values: List<String>, selected: String, fixed: Boolean = false, choose: (String) -> Unit) {
    if (values.isEmpty()) return
    val colors = lightlyColors
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(title, style = l2TextStyle(12.sp, androidx.compose.ui.text.font.FontWeight.Bold, colors.ink2), modifier = Modifier.padding(top = 4.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(9.dp)) {
            values.forEach { c ->
                val on = c.equals(selected, ignoreCase = true)
                Box(Modifier.then(if (fixed) Modifier.size(40.dp) else Modifier.weight(1f).height(40.dp)).clip(RoundedCornerShape(12.dp)).background(colourOf(c))
                    .border(1.dp, colors.hair, RoundedCornerShape(12.dp))
                    .clickable { choose(c.uppercase()) }.semantics { contentDescription = "Colour $c"; this.selected = on }) {
                    if (on) Box(Modifier.align(Alignment.TopEnd).padding(4.dp).size(16.dp).background(colors.accent, CircleShape), contentAlignment = Alignment.Center) {
                        LightlyIcon(LightlyIcons.Check, size = 10.dp, tint = colors.onAccent)
                    }
                }
            }
        }
    }
}

private fun photoPalette(p: Rgba8Image): List<String> {
    val counts = mutableMapOf<Int,IntArray>()
    for(y in 0 until p.height step maxOf(1,p.height/64)) for(x in 0 until p.width step maxOf(1,p.width/64)) {
        val i=(y*p.width+x)*4;val r=p.pixels[i].toInt() and 255;val g=p.pixels[i+1].toInt() and 255;val b=p.pixels[i+2].toInt() and 255
        val a=counts.getOrPut(r/32*64+g/32*8+b/32){IntArray(4)};a[0]++;a[1]+=r;a[2]+=g;a[3]+=b
    }
    val colours = mutableListOf<IntArray>()
    for ((_,v) in counts.entries.sortedWith(compareByDescending<Map.Entry<Int,IntArray>>{it.value[0]}.thenBy{it.key})) {
        val c = intArrayOf(v[1]/v[0],v[2]/v[0],v[3]/v[0])
        if (colours.all { old -> (0..2).sumOf { (old[it]-c[it])*(old[it]-c[it]) } >= 3025 }) colours.add(c)
        if (colours.size == 5) break
    }
    return colours.map { "#%02X%02X%02X".format(it[0],it[1],it[2]) }
}
