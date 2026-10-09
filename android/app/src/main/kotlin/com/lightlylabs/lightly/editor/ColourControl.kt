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
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ColourControl(title: String = "Colour", selected: String, photo: Rgba8Image?, tag: String, choose: (String) -> Unit, previewPhoto: Rgba8Image? = photo, preview: ((String) -> Unit)? = null, cancel: (() -> Unit)? = null) {
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = lightlyTextStyle(color = lightlyColors.ink))
        Spacer(Modifier.weight(1f))
        Row(Modifier.clip(CircleShape).background(lightlyColors.bg2).clickable { open = true }.semantics { stateDescription = selected }.testTagResource("$tag-picker").padding(horizontal = 12.dp).heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(24.dp).background(colourOf(selected), CircleShape).border(1.dp, lightlyColors.hair, CircleShape))
            Text("Choose colour", style = lightlyTextStyle(14.sp, color = lightlyColors.ink))
        }
    }
    if (open) {
        var hex by remember { mutableStateOf(selected.uppercase()) }
        var picking by remember { mutableStateOf(false) }
        val prefs = LocalContext.current.getSharedPreferences("lightly-colours", 0)
        val recent = remember { prefs.getString("recent", "#FFFFFF,#111111,#F4F1EC")!!.split(',') }
        LaunchedEffect(hex) { if(Regex("#[0-9A-Fa-f]{6}").matches(hex)) preview?.invoke(hex.uppercase()) }
        val palette = remember(photo) { photo?.let(::photoPalette).orEmpty() }
        ModalBottomSheet(onDismissRequest = { cancel?.invoke(); open = false }, containerColor = lightlyColors.bg) {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(title, style = lightlyTextStyle(color = lightlyColors.ink)); Spacer(Modifier.weight(1f))
                    TextButton(onClick = { cancel?.invoke(); open = false }) { Text("Cancel") }
                    TextButton(enabled = Regex("#[0-9A-Fa-f]{6}").matches(hex), onClick = {
                        val c = hex.uppercase(); prefs.edit().putString("recent", (listOf(c)+recent.filter { it != c }).take(8).joinToString(",")).apply()
                        choose(c); open = false
                    }) { Text("Done") }
                }
                if (!picking && previewPhoto != null) {
                    val rendered = remember(previewPhoto) { previewPhoto.toBitmap().asImageBitmap() }
                    Image(rendered, "Colour preview", Modifier.fillMaxWidth().height(180.dp))
                }
                if (picking && photo != null) {
                    val bitmap = remember(photo) { photo.toBitmap().asImageBitmap() }
                    Image(bitmap, "Tap a colour in the photo", Modifier.fillMaxWidth().aspectRatio(photo.width.toFloat()/photo.height).pointerInput(photo) {
                        detectTapGestures { p ->
                            val x = (p.x/size.width*photo.width).toInt().coerceIn(0,photo.width-1)
                            val y = (p.y/size.height*photo.height).toInt().coerceIn(0,photo.height-1)
                            hex = photoHex(photo, x, y); picking = false
                        }
                    })
                }
                ColourPalette("From your photo", palette, hex) { hex = it }
                ColourPalette("Paper & ink", listOf("#FFFFFF","#ECE8DF","#D4C9B5","#9C9284","#242423"), hex) { hex = it }
                ColourPalette("Earth", listOf("#DFC7AE","#B98767","#914E3E","#66775D","#334538"), hex) { hex = it }
                Text("Custom", style = lightlyTextStyle(13.sp, color = lightlyColors.ink2))
                val hsv = remember(hex) { FloatArray(3).also { android.graphics.Color.colorToHSV(runCatching { android.graphics.Color.parseColor(hex) }.getOrDefault(android.graphics.Color.BLACK), it) } }
                fun setHSV(h: Float, s: Float, v: Float) { hex = "#%06X".format(android.graphics.Color.HSVToColor(floatArrayOf(h,s,v)) and 0xffffff) }
                val hue by rememberUpdatedState(hsv[0])
                Box(Modifier.fillMaxWidth().height(100.dp).clip(RoundedCornerShape(10.dp))
                    .background(Brush.horizontalGradient(listOf(Color.White, Color.hsv(hsv[0],1f,1f))))
                    .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black)))
                    .pointerInput(Unit) {
                        detectTapGestures { p -> setHSV(hue,(p.x/size.width).coerceIn(0f,1f),(1-p.y/size.height).coerceIn(0f,1f)) }
                    }.pointerInput(Unit) {
                        fun pick(p: androidx.compose.ui.geometry.Offset) { setHSV(hue,(p.x/size.width).coerceIn(0f,1f),(1-p.y/size.height).coerceIn(0f,1f)) }
                        detectDragGestures(onDragStart = ::pick) { change, _ -> pick(change.position); change.consume() }
                    }.semantics { contentDescription = "Saturation and brightness; exact colour can also be entered below" })
                Slider(hsv[0], onValueChange = { setHSV(it,hsv[1],hsv[2]) }, valueRange = 0f..359f, modifier = Modifier.semantics { contentDescription = "Hue" })
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(hex, { hex = it }, label = { Text("HEX") }, singleLine = true, modifier = Modifier.weight(1f))
                    TextButton(onClick = { picking = !picking }) { Text("Eyedropper") }
                }
                ColourPalette("Recent", recent, hex) { hex = it }
                Spacer(Modifier.height(20.dp))
            }
        }
    }
}

@Composable private fun ColourPalette(title: String, values: List<String>, selected: String, choose: (String) -> Unit) {
    if (values.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = lightlyTextStyle(13.sp, color = lightlyColors.ink2))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            values.forEach { c -> Box(Modifier.weight(1f).height(40.dp).clip(RoundedCornerShape(8.dp)).background(colourOf(c))
                .border(if(c==selected) 2.dp else 1.dp, if(c==selected) lightlyColors.ink else lightlyColors.hair, RoundedCornerShape(8.dp))
                .clickable { choose(c) }.semantics { contentDescription = "Colour $c"; this.selected = c == selected }) }
        }
    }
}
private fun photoHex(p: Rgba8Image, x: Int, y: Int): String {
    val i=(y*p.width+x)*4; return "#%02X%02X%02X".format(p.pixels[i].toInt() and 255,p.pixels[i+1].toInt() and 255,p.pixels[i+2].toInt() and 255)
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
