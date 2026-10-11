package com.lightlylabs.lightly.editor

import androidx.compose.ui.focus.focusRequester


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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
fun WatermarkPanel(vm: EditorViewModel, ui: EditorUiState, roomy: Boolean) = Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
    // Lightly 2 `watermarkPanel`, a 6 dp column: the tabs; with a watermark, the reset row and "Drag the watermark on the
    // photo to place it."; then the type's controls.
    val recipe = ui.session?.current ?: return@Column
    val w = recipe.tools.watermark
    val saved by vm.signatures.collectAsStateWithLifecycle()
    val tab = vm.watermarkTab(ui)
    OptionTabs(WatermarkOptions.TABS, tab, vm::chooseWatermark, tagPrefix = "watermark-tab")
    if (tab != WatermarkType.NONE) {
        ResetRow(vm, "watermark", "Watermark")
        PanelNote("Drag the watermark on the photo to place it.")
    }
    val hasBorder = recipe.tools.border.type != BorderType.NONE
    when (tab) {
        WatermarkType.NONE -> PanelNote("No watermark. Choose Signature, Text or Logo to add one.")
        // The signature row (8 dp gaps): the drawn signature (50 dp card, at least 112 dp), its ⋯ menu, the imported
        // signature, Clear, + Draw and Import; then the note, Size, Opacity and the colour strip (drawn signatures).
        WatermarkType.SIGNATURE -> {
            val chosen = if (w.type == WatermarkType.SIGNATURE) w.signature?.kind else null
            ChipRow {
                saved.drawn?.let { s ->
                    SignatureChip(s, chosen == SignatureKind.DRAWN, vm) { vm.chooseSignature(SignatureKind.DRAWN) }
                    SavedDrawingMenu(vm)
                }
                saved.imported?.let { s -> SignatureChip(s, chosen == SignatureKind.IMPORTED, vm) { vm.chooseSignature(SignatureKind.IMPORTED) } }
                if (chosen != null) QuietSmallButton("Clear", vm::clearSignature, Modifier.testTagResource("watermark-signature-clear"), height = 50.dp)
                OptChip(false, "Draw", vm::openDrawSignature, tag = "watermark-draw", card = true, minWidth = 50.dp) { ChipLabel(LightlyIcons.Plus, "Draw") }
                OptChip(false, "Import", { vm.onChooseSignaturePhoto() }, tag = "watermark-import", card = true, minWidth = 50.dp) { ChipLabel(LightlyIcons.Photo, "Import") }
            }
            val drawnKind = (w.signature?.kind ?: SignatureKind.DRAWN) == SignatureKind.DRAWN
            PanelNote("Saved signatures keep their own look. " + if (drawnKind) "You can change the ink colour of a drawn signature." else "An imported signature keeps its own ink.")
            CommonControls(vm, ui, hasBorder, colours = drawnKind)
        }
        // The text field (46 dp, 16 dp corners, chip fill, hairline, 16 sp text and the pencil), the six fonts, Size,
        // Opacity and the colour strip.
        WatermarkType.TEXT -> {
            val current = w.text ?: com.lightlylabs.lightly.session.WatermarkText(WatermarkOptions.DEFAULT_TEXT, WatermarkFont.ALLURA)
            TextRow(current.text, vm::setWatermarkText)
            ChipRow { WatermarkOptions.FONTS.forEach { (font, name) -> FontOption(current.text, font, name, current.font == font, vm) { vm.chooseFont(font) } } }
            CommonControls(vm, ui, hasBorder, colours = true)
        }
        // The current logo (50 dp, 16 dp padding and corners, 2 dp accent border; not a button) and Replace logo.
        WatermarkType.LOGO -> {
            ChipRow {
                val shape = RoundedCornerShape(16.dp)
                Box(
                    Modifier.heightIn(min = 50.dp).border(2.dp, lightlyColors.sel, shape)
                        .semantics { contentDescription = "Current logo" }.padding(horizontal = 16.dp),
                    contentAlignment = Alignment.Center,
                ) { LogoGlyph(vm, w.logo?.image, 26.dp, lightlyColors.ink) }
                QuietSmallButton("Replace logo", { vm.onChooseLogo() }, Modifier.testTagResource("watermark-replace-logo"), icon = LightlyIcons.Photo, height = 50.dp)
            }
            CommonControls(vm, ui, hasBorder, colours = false)
        }
    }
}

@Composable
private fun ChipLabel(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String) {
    LightlyIcon(icon, size = 16.dp, tint = lightlyColors.ink)
    Text(label, style = com.lightlylabs.lightly.shell.l2TextStyle(13.sp, FontWeight.SemiBold, lightlyColors.ink), maxLines = 1)
}

/** A saved signature card: 50 dp, at least 112 dp, the signature 24 dp tall in ink; a 2 dp accent border when chosen. */
@Composable
private fun SignatureChip(signature: SavedSignature, on: Boolean, vm: EditorViewModel, onClick: () -> Unit) {
    OptChip(on, if (signature.kind == SignatureKind.DRAWN) "Drawn signature" else "Imported signature", onClick,
        tag = "watermark-signature-${signature.kind.name.lowercase()}", card = true, minWidth = 112.dp) {
        SignatureGlyph(vm, signature, 24.dp, lightlyColors.ink)
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

/** The text field: 46 dp, 16 dp corners, chip fill, hairline, the text at 16 sp and the pencil; it opens "Watermark text". */
@Composable
private fun TextRow(value: String, onCommit: (String) -> Unit) {
    var editing by remember { mutableStateOf(false) }
    val colors = lightlyColors
    val shape = RoundedCornerShape(16.dp)
    Row(
        Modifier.fillMaxWidth().heightIn(min = 46.dp).clip(shape).background(colors.chip).border(1.dp, colors.hair, shape)
            .clickable(role = Role.Button) { editing = true }.semantics { contentDescription = "Edit watermark text" }
            .testTagResource("watermark-text-value").padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(value, modifier = Modifier.weight(1f), style = com.lightlylabs.lightly.shell.l2TextStyle(16.sp, color = colors.ink), maxLines = 1)
        LightlyIcon(LightlyIcons.Pencil, size = 18.dp, tint = colors.ink)
    }
    if (editing) WatermarkTextSheet(value, onDone = { onCommit(it); editing = false }, onCancel = { editing = false })
}

/** "Watermark text" (`textEdit`): Cancel · Watermark text · Done, up to 80 characters. */
@Composable
private fun WatermarkTextSheet(initial: String, onDone: (String) -> Unit, onCancel: () -> Unit) =
    TextEntrySheet("Watermark text", initial, maxLength = 80, tagPrefix = "watermark-text", onDone = onDone, onCancel = onCancel)

/**
 * The text sheet (`textEdit`), shared by Watermark › Text and the Text tool: sheetHead (Cancel · [title] · Done, Done
 * enabled while the text is not blank) and the field (52 dp, 16 dp corners, 2 dp accent border, 19 sp), focused at once.
 * L2Sheet pads by the IME, so the field always sits above the keyboard.
 */
@Composable
internal fun TextEntrySheet(title: String, initial: String, maxLength: Int, tagPrefix: String, onDone: (String) -> Unit, onCancel: () -> Unit) {
    var edited by remember { mutableStateOf(initial) }
    val focus = remember { androidx.compose.ui.focus.FocusRequester() }
    val colors = lightlyColors
    androidx.compose.ui.window.Dialog(onDismissRequest = onCancel,
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        L2Sheet(big = androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp >= 600, onDismiss = onCancel) {
            L2SheetHead(title,
                leading = { L2TextButton("Cancel", "$tagPrefix-cancel", onClick = onCancel) },
                trailing = { L2TextButton("Done", "$tagPrefix-done", bold = true, enabled = edited.isNotBlank()) { onDone(edited) } })
            androidx.compose.foundation.text.BasicTextField(edited, { edited = it.take(maxLength) },
                textStyle = TextStyle(fontSize = 19.sp, color = colors.ink), cursorBrush = androidx.compose.ui.graphics.SolidColor(colors.sel),
                modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 10.dp).heightIn(min = 52.dp)
                    .border(2.dp, colors.sel, RoundedCornerShape(16.dp)).padding(horizontal = 14.dp, vertical = 14.dp)
                    .focusRequester(focus).testTagResource("$tagPrefix-editor"))
        }
    }
    LaunchedEffect(Unit) { focus.requestFocus() }
}

/**
 * A font option: at least 108×58 dp, 16 dp corners, the text at 19 sp in the font over the font's name (10.5 sp ink3);
 * selected with a 2 dp accent border, otherwise a hairline.
 */
@Composable
private fun FontOption(text: String, font: WatermarkFont, name: String, on: Boolean, vm: EditorViewModel, onClick: () -> Unit) {
    val colors = lightlyColors
    val shape = RoundedCornerShape(16.dp)
    Column(
        Modifier.widthIn(min = 108.dp).heightIn(min = 58.dp).clip(shape)
            .border(if (on) 2.dp else 1.dp, if (on) colors.sel else colors.hair, shape)
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { contentDescription = name; selected = on }
            .testTagResource("watermark-font-$name")
            .padding(horizontal = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
    ) {
        Text(text, style = TextStyle(fontFamily = vm.composeFont(font), fontSize = 19.sp, color = colors.ink), maxLines = 1)
        Text(name, style = TextStyle(fontSize = com.lightlylabs.lightly.shell.fixedTextSize(10.5f), color = colors.ink3), maxLines = 1)
    }
}

/** Placement, position, size, opacity and (for text and drawn signatures) the ink colours, as the prototype's shared controls. */
@Composable
private fun CommonControls(vm: EditorViewModel, ui: EditorUiState, hasBorder: Boolean, colours: Boolean) {
    val w = ui.session?.current?.tools?.watermark ?: return
    val colors = lightlyColors
    WatermarkSlider(vm, ui, "Size", "size", w.size, 10.0, 80.0)
    WatermarkSlider(vm, ui, "Opacity", "opacity", w.opacity, 0.0, 100.0)
    if (colours) ColourControl("Colour", w.colour, ui.original, "watermark-colour", vm::setWatermarkColour, previewPhoto = ui.preview, preview = { vm.previewColour("watermark-colour", it) }, cancel = vm::cancelPhotoGesturePreview)
}

@Composable
private fun WatermarkSlider(vm: EditorViewModel, ui: EditorUiState, label: String, field: String, committed: Double, min: Double, max: Double) {
    val drag = ui.watermark.sliderDrag?.takeIf { it.first == field }?.second
    SliderRow(label, drag ?: committed, min, max, onDrag = { vm.onWatermarkSlider(field, it) }, onRelease = { vm.onWatermarkSliderRelease(field, it) }, tag = "watermark-slider-$field")
}

/** The Text tool's font as a Compose family, from the same bundled file and weight stage 11 draws with. */
internal fun textFontFamily(assets: android.content.res.AssetManager, font: com.lightlylabs.lightly.session.TextFont): FontFamily {
    @OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
    val settings = if (WatermarkFonts.textFontVariation(font) != null) FontVariation.Settings(FontVariation.weight(400)) else FontVariation.Settings()
    @OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
    return FontFamily(Font("${WatermarkFonts.ASSET_DIR}/${WatermarkFonts.textFontFile(font)}", assets, weight = FontWeight.Normal, variationSettings = settings))
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
        WatermarkFont.DANCING_SCRIPT -> family("DancingScript-Variable.ttf", 400)
        WatermarkFont.LORA -> family("Lora-Variable.ttf", 400)
        WatermarkFont.CAVEAT -> family("Caveat-Variable.ttf", 500)
    }
}


@Composable
private fun SavedDrawingMenu(vm: EditorViewModel) {
    var expanded by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }
    Box {
        // The ⋯ card: 50 dp, 16 dp corners, hairline.
        Box(Modifier.size(50.dp).clip(RoundedCornerShape(16.dp)).border(1.dp, lightlyColors.hair, RoundedCornerShape(16.dp)).clickable { expanded = true }
            .semantics { contentDescription = "Manage saved signature" }.testTagResource("watermark-signature-manage"), contentAlignment = Alignment.Center) {
            LightlyIcon(LightlyIcons.Ellipsis, size = 18.dp, tint = lightlyColors.ink)
        }
        DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(text = { Text("Draw replacement") }, onClick = { expanded = false; vm.openDrawSignature() })
            DropdownMenuItem(text = { Text("Delete saved signature") }, onClick = { expanded = false; confirm = true })
        }
    }
    if (confirm) androidx.compose.ui.window.Dialog(onDismissRequest = { confirm = false },
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        L2Dialog("Delete saved signature?", "This removes the saved drawing and its signature from this photo.",
            listOf(L2DialogButton("Delete signature", "dialog-Delete signature", destructive = true) { confirm = false; vm.deleteDrawnSignature() },
                L2DialogButton("Cancel", "dialog-Cancel") { confirm = false }),
            onDismiss = { confirm = false })
    }
}
