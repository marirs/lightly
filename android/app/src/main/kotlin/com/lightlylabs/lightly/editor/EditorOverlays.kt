package com.lightlylabs.lightly.editor

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.min
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.shell.ButtonKind
import com.lightlylabs.lightly.shell.LightlyButton
import com.lightlylabs.lightly.shell.LightlyIcon
import com.lightlylabs.lightly.shell.LightlyIcons
import com.lightlylabs.lightly.shell.ListRow
import com.lightlylabs.lightly.shell.SheetGrabber
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.lightlyTextStyle
import com.lightlylabs.lightly.shell.testTagResource

/** Where Lightly's own sheets and dialogs go: never across a fold (prototype `.scrim.paneR` / `.paneB`). */
private enum class Pane { WHOLE, RIGHT, LOWER }

/** Sheets and dialogs over the editor (prototype `overlayHTML`). */
@Composable
fun EditorOverlays(vm: EditorViewModel, ui: EditorUiState, model: DevelopPanelModel?, frame: EditorFrame, favourites: List<String>, actions: EditorActions) {
    val overlay = ui.overlay ?: return
    // Preferences › Saved signature's sheets are drawn over the More page by the shell (PreferencesSignatureSheet).
    if (vm.preferencesSheetOpen(ui)) return
    val pane = when (frame.layout.mode) { EditorMode.SPLIT_V -> Pane.RIGHT; EditorMode.SPLIT_H -> Pane.LOWER; else -> Pane.WHOLE }
    val big = frame.layout.widthDp > 700f && pane == Pane.WHOLE
    BackHandler { if (overlay == EditorOverlay.SAVING) vm.cancelSave() else vm.dismiss() }
    when (overlay) {
        EditorOverlay.FAVOURITE_REPLACE -> Sheet(pane, big, frame) {
            SheetHead("Replace a favourite", onCancel = vm::dismiss)
            val library = vm.library
            favourites.forEach { id ->
                val preset = library?.pack?.preset(id) ?: return@forEach
                val category = library.pack.category(preset.categoryId)?.name.orEmpty()
                ListRow(preset.displayName, sub = category, onClick = { vm.replaceFavourite(id) }, tag = "replace-$id", trailing = {
                    Text("Replace", style = lightlyTextStyle(color = lightlyColors.sel))
                })
            }
        }
        EditorOverlay.SAVING -> Scrim(pane, frame, alignCentre = true) {
            ProgressBox("Saving a copy…", null, 0.55f, cancel = vm::cancelSave)
        }
        EditorOverlay.SAVED -> Sheet(pane, big, frame) {
            Column(Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                LightlyIcon(LightlyIcons.Check, size = 30.dp, tint = lightlyColors.sel, modifier = Modifier.padding(bottom = 8.dp))
                Text("Saved as a new photo", style = lightlyTextStyle(18.sp, FontWeight.SemiBold, lightlyColors.ink), modifier = Modifier.semantics { heading() })
                Text("The original is unchanged.", style = lightlyTextStyle(color = lightlyColors.ink2), modifier = Modifier.padding(top = 4.dp, bottom = 14.dp))
            }
            Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                LightlyButton("Share", ButtonKind.PRIMARY, { ui.savedAsset?.let(actions.share) }, Modifier.fillMaxWidth(), icon = LightlyIcons.Share, tag = "saved-share")
                LightlyButton("Keep editing", ButtonKind.LINE, vm::dismiss, Modifier.fillMaxWidth(), tag = "saved-keep-editing")
                LightlyButton("Choose another photo", ButtonKind.QUIET, { vm.dismiss(); actions.chooseAnother() }, Modifier.fillMaxWidth(), tag = "saved-choose-another")
            }
        }
        EditorOverlay.LEAVE -> Dialog(
            pane, frame, "Leave without saving?", "Your original photo is unchanged. Edits that are not saved as a copy will be lost.",
            listOf("Save copy" to { vm.dismiss(); vm.saveCopy() }, "Discard edits" to vm::discardAndLeave, "Keep editing" to vm::dismiss),
        )
        EditorOverlay.EXPORT_FAILED -> Dialog(
            pane, frame, "Couldn’t save the copy", "Something went wrong while saving. Your edits are kept and the original is unchanged.",
            listOf("Try again" to { vm.dismiss(); vm.saveCopy() }, "Keep editing" to vm::dismiss),
        )
        EditorOverlay.SIGNATURE_DRAW -> Sheet(pane, big, frame) {
            DrawSignatureSheet(ui.watermark.pad, vm::padStroke, onCancel = vm::dismiss, onSave = vm::saveDrawnSignature, onClear = vm::clearPad)
        }
        EditorOverlay.SIGNATURE_IMPORT -> Sheet(pane, big, frame) {
            ImportSignatureSheet(ui.watermark.imported, onCancel = vm::dismiss, onUse = vm::useImportedSignature)
        }
        EditorOverlay.STORAGE_FULL -> Dialog(
            pane, frame, "Not enough storage", "Free up some space and try again. Your edits are kept.",
            listOf("Try again" to { vm.dismiss(); vm.saveCopy() }, "OK" to vm::dismiss),
        )
    }
}

/** `.scrim`, confined to the pane on an unfolded foldable. Taps on the scrim are swallowed. */
@Composable
private fun Scrim(pane: Pane, frame: EditorFrame, alignCentre: Boolean, content: @Composable () -> Unit) {
    val colors = lightlyColors
    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .background(colors.scrim)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
    ) {
        val inset = when (pane) {
            Pane.RIGHT -> Modifier.padding(start = ((frame.foldDp ?: (maxWidth.value / 2))).dp)
            Pane.LOWER -> Modifier.padding(top = ((frame.foldDp ?: (maxHeight.value / 2))).dp)
            Pane.WHOLE -> Modifier
        }
        Box(Modifier.fillMaxSize().then(inset), contentAlignment = if (alignCentre) Alignment.Center else Alignment.BottomCenter) { content() }
    }
}

/**
 * `.sheet`: a bottom sheet (radius 14 on top, grabber, at most 88 % tall) on phones and in a fold pane;
 * a centred form sheet (min(540 dp, 92 %), radius 14, no grabber) on tablets.
 */
@Composable
private fun Sheet(pane: Pane, big: Boolean, frame: EditorFrame, content: @Composable ColumnScope.() -> Unit) {
    val colors = lightlyColors
    Scrim(pane, frame, alignCentre = big) {
        BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = if (big) Alignment.Center else Alignment.BottomCenter) {
            val shape = if (big) RoundedCornerShape(14.dp) else RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp)
            Column(
                Modifier
                    .then(if (big) Modifier.width(min(540.dp, maxWidth * 0.92f)).heightIn(max = maxHeight * 0.86f) else Modifier.fillMaxWidth().heightIn(max = if (pane == Pane.WHOLE) maxHeight * 0.88f else maxHeight))
                    .clip(shape)
                    .background(colors.sheet)
                    .pointerInput(Unit) { detectTapGestures {} }
                    .semantics { paneTitle = "Sheet" }
                    .padding(top = 8.dp, bottom = if (big) 16.dp else 30.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                if (!big) SheetGrabber()
                content()
            }
        }
    }
}

/** `.sheethead`: Cancel, the centred title, and a 70 dp balance. */
@Composable
private fun SheetHead(title: String, onCancel: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(start = 18.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        // `.btn.quiet` with the sheet head's own padding (prototype: 0 12 inside an 18 dp head).
        Box(Modifier.heightIn(min = 44.dp).clip(RoundedCornerShape(10.dp)).clickable(role = Role.Button, onClick = onCancel).padding(horizontal = 12.dp).testTagResource("sheet-cancel"), contentAlignment = Alignment.Center) {
            Text("Cancel", style = lightlyTextStyle(17.sp, FontWeight.SemiBold, lightlyColors.sel))
        }
        Text(title, style = lightlyTextStyle(17.sp, FontWeight.SemiBold, lightlyColors.ink), textAlign = TextAlign.Center, modifier = Modifier.weight(1f).semantics { heading() })
        Spacer(Modifier.width(70.dp))
    }
}

/** Android dialog (`.dialog.md`): radius 24, title 20 sp regular, body, actions right-aligned in the selection colour. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Dialog(pane: Pane, frame: EditorFrame, title: String, body: String, buttons: List<Pair<String, () -> Unit>>) {
    val colors = lightlyColors
    Scrim(pane, frame, alignCentre = true) {
        BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            val width: Dp = min(320.dp, maxWidth * 0.86f)
            Column(
                Modifier
                    .widthIn(max = width)
                    .clip(RoundedCornerShape(24.dp))
                    .background(colors.sheet)
                    .pointerInput(Unit) { detectTapGestures {} }
                    .semantics { paneTitle = title }
                    .padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 12.dp),
            ) {
                Text(title, style = lightlyTextStyle(20.sp, FontWeight.Normal, colors.ink), modifier = Modifier.padding(bottom = 10.dp).semantics { heading() })
                Text(body, style = lightlyTextStyle(13.5.sp, color = colors.ink2), modifier = Modifier.padding(bottom = 16.dp))
                FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.End), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    buttons.forEach { (label, action) ->
                        Box(Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(10.dp)).clickable(role = Role.Button, onClick = action).padding(horizontal = 12.dp).testTagResource("dialog-$label"), contentAlignment = Alignment.Center) {
                            Text(label, style = lightlyTextStyle(15.sp, FontWeight.Medium, colors.sel))
                        }
                    }
                }
            }
        }
    }
}
