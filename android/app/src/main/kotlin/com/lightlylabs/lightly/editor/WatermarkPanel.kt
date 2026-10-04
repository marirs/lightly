package com.lightlylabs.lightly.editor

import android.graphics.BitmapFactory
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.session.BorderType
import com.lightlylabs.lightly.session.SignatureKind
import com.lightlylabs.lightly.session.WatermarkFont
import com.lightlylabs.lightly.session.WatermarkPlacement
import com.lightlylabs.lightly.session.WatermarkType
import com.lightlylabs.lightly.shell.LightlyIcon
import com.lightlylabs.lightly.shell.LightlyIcons
import com.lightlylabs.lightly.shell.SegmentedControl
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.lightlyTextStyle
import com.lightlylabs.lightly.shell.testTagResource
import com.lightlylabs.lightly.signatures.SavedSignature

/** Prototype `watermarkPanel`: None, Signature, Text, Logo with the approved controls and copy verbatim. */
@Composable
fun WatermarkPanel(vm: EditorViewModel, ui: EditorUiState, roomy: Boolean) = Column(Modifier.fillMaxWidth()) {
    if (roomy) PanelTitle("Watermark")
    val recipe = ui.session?.current ?: return@Column
    val w = recipe.tools.watermark
    val saved by vm.signatures.collectAsStateWithLifecycle()
    val tab = vm.watermarkTab(ui)
    OptionTabs(WatermarkOptions.TABS, tab, vm::chooseWatermark, tagPrefix = "watermark-tab")
    val hasBorder = recipe.tools.border.type != BorderType.NONE
    when (tab) {
        WatermarkType.NONE -> PanelNote("No watermark. Choose Signature, Text or Logo to add one.")
        WatermarkType.SIGNATURE -> {
            val chosen = if (w.type == WatermarkType.SIGNATURE) w.signature?.kind else null
            ChipRow {
                saved.drawn?.let { s -> SignatureChip(s, chosen == SignatureKind.DRAWN, vm) { vm.chooseSignature(SignatureKind.DRAWN) } }
                saved.imported?.let { s -> SignatureChip(s, chosen == SignatureKind.IMPORTED, vm) { vm.chooseSignature(SignatureKind.IMPORTED) } }
                OptChip(false, "Draw", vm::openDrawSignature, tag = "watermark-draw") { ChipLabel(LightlyIcons.Plus, "Draw") }
                OptChip(false, "Import", { vm.onChooseSignaturePhoto() }, tag = "watermark-import") { ChipLabel(LightlyIcons.Photo, "Import") }
            }
            val drawnKind = (w.signature?.kind ?: SignatureKind.DRAWN) == SignatureKind.DRAWN
            PanelNote("Saved signatures keep their own look. " + if (drawnKind) "You can change the ink colour of a drawn signature." else "An imported signature keeps its own ink.")
            CommonControls(vm, ui, hasBorder, colours = drawnKind)
        }
        WatermarkType.TEXT -> {
            val current = w.text ?: com.lightlylabs.lightly.session.WatermarkText(WatermarkOptions.DEFAULT_TEXT, WatermarkFont.ALLURA)
            TextRow(current.text, vm::setWatermarkText)
            ChipRow { WatermarkOptions.FONTS.forEach { (font, name) -> FontOption(current.text, font, name, current.font == font, vm) { vm.chooseFont(font) } } }
            CommonControls(vm, ui, hasBorder, colours = true)
        }
        WatermarkType.LOGO -> {
            ChipRow {
                // `span.opt.on`: the current logo (not a button), in the selection colour.
                val shape = RoundedCornerShape(10.dp)
                Box(
                    Modifier.heightIn(min = 44.dp).widthIn(min = 44.dp).clip(shape).background(lightlyColors.selSoft).border(1.dp, lightlyColors.sel, shape)
                        .semantics { contentDescription = "Current logo" }.padding(horizontal = 13.dp),
                    contentAlignment = Alignment.Center,
                ) { LogoGlyph(vm, w.logo?.image, 26.dp, lightlyColors.sel) }
                OptChip(false, "Replace logo", { vm.onChooseLogo() }, tag = "watermark-replace-logo") { ChipLabel(LightlyIcons.Photo, "Replace logo") }
            }
            CommonControls(vm, ui, hasBorder, colours = false)
        }
    }
}

@Composable
private fun ChipLabel(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String) {
    LightlyIcon(icon, size = 18.dp, tint = lightlyColors.ink2)
    Text(label, style = lightlyTextStyle(color = lightlyColors.ink2), maxLines = 1)
}

/** `.opt` with `min-width:120px` holding a saved signature 26 dp tall (`currentColor`: ink-2, or the selection colour when chosen). */
@Composable
private fun SignatureChip(signature: SavedSignature, on: Boolean, vm: EditorViewModel, onClick: () -> Unit) {
    OptChip(on, if (signature.kind == SignatureKind.DRAWN) "Drawn signature" else "Imported signature", onClick, tag = "watermark-signature-${signature.kind.name.lowercase()}") {
        Box(Modifier.widthIn(min = 120.dp - 26.dp), contentAlignment = Alignment.Center) {
            SignatureGlyph(vm, signature, 26.dp, if (on) lightlyColors.sel else lightlyColors.ink2)
        }
    }
}

/** A saved signature at a height: a drawn one in [ink], an imported one in its own ink. */
@Composable
fun SignatureGlyph(vm: EditorViewModel, signature: SavedSignature, height: Dp, ink: Color) = SavedSignatureGlyph(signature, height, ink)

/** Drawn signatures are stroked exactly as stage 12 strokes them (no font involved). */
private val SIGNATURE_GLYPHS = WatermarkStage(WatermarkSizes.REVISION_2, WatermarkFonts(null))

@Composable
fun SavedSignatureGlyph(signature: SavedSignature, height: Dp, ink: Color) {
    val drawn = signature.drawn
    if (drawn != null) {
        Canvas(Modifier.size(height * drawn.aspectRatio.toFloat(), height)) {
            drawIntoCanvas { SIGNATURE_GLYPHS.drawSignature(it.nativeCanvas, drawn, 0f, 0f, size.height, ink.toArgb()) }
        }
    } else {
        val bitmap = remember(signature.version) { BitmapFactory.decodeByteArray(signature.data, 0, signature.data.size)?.asImageBitmap() } ?: return
        Image(bitmap, null, Modifier.size(height * (bitmap.width.toFloat() / bitmap.height), height))
    }
}

/** The logo at a height: the bundled sample (ring and "AR" in [ink]) or a chosen image in its own colours. */
@Composable
fun LogoGlyph(vm: EditorViewModel, logo: com.lightlylabs.lightly.session.AssetRef?, height: Dp, ink: Color) {
    val file = logo as? com.lightlylabs.lightly.session.AssetRef.File
    val png = remember(file?.sha256) { file?.let { vm.logoBytes(it.sha256) } }
    if (png != null) {
        val bitmap = remember(png) { BitmapFactory.decodeByteArray(png, 0, png.size)?.asImageBitmap() } ?: return
        Image(bitmap, null, Modifier.size(height * (bitmap.width.toFloat() / bitmap.height), height))
    } else {
        Canvas(Modifier.size(height)) { drawIntoCanvas { vm.watermarkGlyphs.drawSampleLogo(it.nativeCanvas, 0f, 0f, size.height, ink.toArgb(), null) } }
    }
}

/** `.listrow` (border 0): "Text" in ink-2 and the text itself at the end in ink, editable in place. */
@Composable
private fun TextRow(value: String, onCommit: (String) -> Unit) {
    var edited by remember { mutableStateOf(value) }
    var focused by remember { mutableStateOf(false) }
    LaunchedEffect(value) { if (!focused) edited = value }
    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Text", style = lightlyTextStyle(color = lightlyColors.ink2))
        BasicTextField(
            edited, { edited = it.take(80) },
            singleLine = true,
            textStyle = lightlyTextStyle(color = lightlyColors.ink).merge(TextStyle(textAlign = TextAlign.End)),
            cursorBrush = SolidColor(lightlyColors.sel),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { onCommit(edited) }),
            modifier = Modifier.weight(1f).onFocusChanged { state -> if (focused && !state.isFocused) onCommit(edited); focused = state.isFocused }
                .semantics { contentDescription = "Watermark text" }.testTagResource("watermark-text-value"),
        )
    }
}

/**
 * `.fontopt`: the text in the font at 20 px over the font's name (Inter 500, 10.5 px, ink-3); min 100 × 60,
 * radius 10, border-box padding 4 10 plus the 1 px border; selected: selection border on its soft fill.
 */
@Composable
private fun FontOption(text: String, font: WatermarkFont, name: String, on: Boolean, vm: EditorViewModel, onClick: () -> Unit) {
    val colors = lightlyColors
    val shape = RoundedCornerShape(10.dp)
    Column(
        Modifier.widthIn(min = 100.dp).heightIn(min = 60.dp).clip(shape)
            .then(if (on) Modifier.background(colors.selSoft) else Modifier)
            .border(1.dp, if (on) colors.sel else colors.hair, shape)
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { contentDescription = name; selected = on }
            .testTagResource("watermark-font-$name")
            .padding(horizontal = 11.dp, vertical = 5.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(text, style = TextStyle(fontFamily = vm.composeFont(font), fontSize = 20.sp, color = colors.ink), maxLines = 1)
        Text(name, style = TextStyle(fontFamily = vm.composeFont(WatermarkFont.INTER, weight = 500), fontSize = com.lightlylabs.lightly.shell.fixedTextSize(10.5f), color = colors.ink3), modifier = Modifier.padding(top = 2.dp), maxLines = 1)
    }
}

/** Placement, position, size, opacity and (for text and drawn signatures) the ink colours, as the prototype's shared controls. */
@Composable
private fun CommonControls(vm: EditorViewModel, ui: EditorUiState, hasBorder: Boolean, colours: Boolean) {
    val w = ui.session?.current?.tools?.watermark ?: return
    val colors = lightlyColors
    if (hasBorder) SegmentedControl(listOf(WatermarkPlacement.PHOTO to "On photo", WatermarkPlacement.BORDER to "On border"), w.placement, vm::setWatermarkPlacement)
    else PanelNote("Add a border to place the watermark on it.")
    if (!(w.placement == WatermarkPlacement.BORDER && hasBorder)) {
        // One row cycling the nine anchors, plus dragging on the photo: no tiny grid targets.
        Row(
            Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable(role = Role.Button, onClick = vm::cycleWatermarkPosition)
                .semantics { contentDescription = "Position, ${WatermarkOptions.POSITIONS[w.position.coerceIn(0, 8)]}" }
                .testTagResource("watermark-position").padding(horizontal = 18.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Position", style = lightlyTextStyle(color = colors.ink), modifier = Modifier.weight(1f))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(WatermarkOptions.POSITIONS[w.position.coerceIn(0, 8)], style = lightlyTextStyle(color = colors.ink3))
                LightlyIcon(LightlyIcons.Chevron, size = 16.dp, tint = colors.ink3)
            }
        }
        // `.note` with `padding-top:0`.
        Text("Or drag the watermark on the photo.", style = lightlyTextStyle(13.sp, color = colors.ink3), modifier = Modifier.padding(start = 18.dp, end = 18.dp, bottom = 6.dp))
    }
    WatermarkSlider(vm, ui, "Size", "size", w.size, 10.0, 80.0)
    WatermarkSlider(vm, ui, "Opacity", "opacity", w.opacity, 0.0, 100.0)
    if (colours) ChipRow {
        Text("Colour", style = lightlyTextStyle(color = colors.ink2), modifier = Modifier.widthIn(min = 84.dp))
        WatermarkOptions.COLOURS.forEach { hex -> Swatch({ SolidColor(colourOf(hex)) }, w.colour == hex, "Colour", { vm.setWatermarkColour(hex) }, tag = "watermark-colour-$hex") }
    }
}

@Composable
private fun WatermarkSlider(vm: EditorViewModel, ui: EditorUiState, label: String, field: String, committed: Double, min: Double, max: Double) {
    val drag = ui.watermark.sliderDrag?.takeIf { it.first == field }?.second
    SliderRow(label, drag ?: committed, min, max, onDrag = { vm.onWatermarkSlider(field, it) }, onRelease = { vm.onWatermarkSliderRelease(field, it) }, tag = "watermark-slider-$field")
}

/** Compose font families for the four approved fonts, from the bundled assets (same files the stage draws with). */
internal fun watermarkFontFamily(assets: android.content.res.AssetManager, font: WatermarkFont, weight: Int? = null): FontFamily {
    @OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
    fun family(file: String, w: Int?) = FontFamily(
        Font("${WatermarkFonts.ASSET_DIR}/$file", assets, weight = FontWeight(w ?: 400),
            variationSettings = if (w != null) FontVariation.Settings(FontVariation.weight(w)) else FontVariation.Settings()),
    )
    return when (font) {
        WatermarkFont.ALLURA -> family("Allura-Regular.ttf", null)
        WatermarkFont.CORMORANT_GARAMOND -> family("CormorantGaramond-Variable.ttf", 500)
        WatermarkFont.INTER -> family("Inter-Variable.ttf", weight ?: 400)
        WatermarkFont.CAVEAT -> family("Caveat-Variable.ttf", 500)
    }
}
