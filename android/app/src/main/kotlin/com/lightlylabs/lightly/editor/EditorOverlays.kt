package com.lightlylabs.lightly.editor

import androidx.compose.foundation.layout.size

import androidx.compose.foundation.shape.CircleShape

import com.lightlylabs.lightly.shell.l2TextStyle

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


/** Sheets and dialogs over the editor (prototype `overlayHTML`). */
@Composable
fun EditorOverlays(vm: EditorViewModel, ui: EditorUiState, model: DevelopPanelModel?, frame: EditorFrame, favourites: List<String>, actions: EditorActions) {
    val overlay = ui.overlay ?: return
    // Preferences › Saved signature's sheets are drawn over the More page by the shell (PreferencesSignatureSheet).
    if (vm.preferencesSheetOpen(ui)) return
    val big = frame.layout.mode != EditorMode.BELOW
    BackHandler { if (overlay == EditorOverlay.SAVING) vm.cancelSave() else vm.dismiss() }
    val colors = lightlyColors
    when (overlay) {
        // `favReplace`: sheetHead (Cancel · Replace a favourite), one row per favourite with "Replace" in bold accent.
        EditorOverlay.FAVOURITE_REPLACE -> L2Sheet(big, onDismiss = vm::dismiss) {
            L2SheetHead("Replace a favourite", leading = { L2TextButton("Cancel", "sheet-cancel", onClick = vm::dismiss) })
            val library = vm.library
            favourites.forEachIndexed { index, id ->
                val preset = library?.pack?.preset(id) ?: return@forEachIndexed
                val category = library.pack.category(preset.categoryId)?.name.orEmpty()
                ListRow(preset.displayName, sub = category, onClick = { vm.replaceFavourite(id) }, tag = "replace-$id", first = index == 0, trailing = {
                    Text("Replace", style = l2TextStyle(14.sp, FontWeight.Bold, colors.sel))
                })
            }
        }
        // Saving: the progress card over the scrim (lime spinner and bar, Cancel).
        EditorOverlay.SAVING -> Box(Modifier.fillMaxSize().background(colors.scrim).clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
            contentAlignment = Alignment.Center) {
            ProgressBox("Saving a copy…", null, 0.55f, cancel = vm::cancelSave)
        }
        // `saved`: the 52 dp lime check, "Saved as a new photo" (20 sp heading), "The original is unchanged." (14 sp ink2);
        // Share (primary), Keep editing (line), Choose another photo (plain, 44 dp, 15 sp semibold), 10 dp apart.
        EditorOverlay.SAVED -> L2Sheet(big, onDismiss = vm::dismiss) {
            Column(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 10.dp), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(52.dp).background(colors.accent, CircleShape), contentAlignment = Alignment.Center) {
                    LightlyIcon(LightlyIcons.Check, size = 28.dp, tint = colors.onAccent)
                }
                Text("Saved as a new photo", style = l2TextStyle(20.sp, FontWeight.SemiBold, colors.ink), modifier = Modifier.padding(top = 6.dp).semantics { heading() })
                Text("The original is unchanged.", style = l2TextStyle(14.sp, color = colors.ink2))
            }
            Column(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 4.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                LightlyButton("Share", ButtonKind.PRIMARY, { ui.savedAsset?.let(actions.share) }, icon = LightlyIcons.Share, tag = "saved-share")
                LightlyButton("Keep editing", ButtonKind.LINE, vm::dismiss, tag = "saved-keep-editing")
                Box(Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable(role = Role.Button) { vm.dismiss(); actions.chooseAnother() }
                    .testTagResource("saved-choose-another"), contentAlignment = Alignment.Center) {
                    Text("Choose another photo", style = l2TextStyle(15.sp, FontWeight.SemiBold, colors.ink))
                }
            }
        }
        EditorOverlay.LEAVE -> L2Dialog(
            "Leave without saving?", "Your original photo is unchanged. Edits that are not saved as a copy will be lost.",
            listOf(L2DialogButton("Save", "dialog-Save") { vm.dismiss(); vm.saveCopy() },
                L2DialogButton("Discard edits", "dialog-Discard edits", destructive = true, action = vm::discardAndLeave),
                L2DialogButton("Keep editing", "dialog-Keep editing", action = vm::dismiss)),
            onDismiss = vm::dismiss,
        )
        EditorOverlay.EXPORT_FAILED -> L2Dialog(
            "Couldn’t save the copy", "Something went wrong while saving. Your edits are kept and the original is unchanged.",
            listOf(L2DialogButton("Try again", "dialog-Try again") { vm.dismiss(); vm.saveCopy() }, L2DialogButton("Keep editing", "dialog-Keep editing", action = vm::dismiss)),
            onDismiss = vm::dismiss,
        )
        EditorOverlay.SIGNATURE_DRAW -> L2Sheet(big, onDismiss = vm::dismiss) {
            DrawSignatureSheet(ui.watermark.pad, vm::padStroke, onCancel = vm::dismiss, onSave = vm::saveDrawnSignature, onClear = vm::clearPad)
        }
        EditorOverlay.SIGNATURE_IMPORT -> L2Sheet(big, onDismiss = vm::dismiss) {
            ImportSignatureSheet(ui.watermark.imported, onCancel = vm::dismiss, onUse = vm::useImportedSignature)
        }
        EditorOverlay.STORAGE_FULL -> L2Dialog(
            "Not enough storage", "Free up some space and try again. Your edits are kept.",
            listOf(L2DialogButton("Try again", "dialog-Try again") { vm.dismiss(); vm.saveCopy() }, L2DialogButton("OK", "dialog-OK", action = vm::dismiss)),
            onDismiss = vm::dismiss,
        )
    }
}
