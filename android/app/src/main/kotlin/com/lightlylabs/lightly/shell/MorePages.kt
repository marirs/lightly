package com.lightlylabs.lightly.shell

import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.lightlylabs.lightly.prefs.Appearance
import com.lightlylabs.lightly.prefs.PreferredBorder
import com.lightlylabs.lightly.prefs.PresetCatalogue
import com.lightlylabs.lightly.prefs.ReleaseDocument
import com.lightlylabs.lightly.prefs.ReleaseText
import com.lightlylabs.lightly.prefs.UserPreferences
import kotlin.math.roundToInt

/** Approved copy for More and its pages (docs/ui/app/app.js `morePage`), verbatim. */
object MoreCopy {
    const val APPEARANCE = "Appearance"
    const val SYSTEM = "System"
    const val LIGHT = "Light"
    const val DARK = "Dark"
    const val SHORTCUTS = "Shortcuts"
    const val SAVING = "Saving"
    const val SAVED_SIGNATURE_SUB = "Reused only when you choose it"
    const val KEEP_METADATA = "Keep photo metadata"
    const val KEEP_METADATA_SUB = "Camera, lens, aperture, shutter speed, ISO and date taken. Location is separate."
    const val INCLUDE_LOCATION = "Include location"
    const val INCLUDE_LOCATION_SUB = "GPS coordinates in saved copies. Off by default."
    const val FAVOURITES_NOTE = "Up to ten. Drag to reorder. Favourites are shortcuts in Develop; they are never applied automatically."
    const val DRAW_SIGNATURE = "Draw a new signature"
    const val IMPORT_SIGNATURE = "Import from a photo"
    const val DELETE_SIGNATURE = "Delete saved signature"
    const val SIGNATURE_NOTE = "A saved signature is added only when you choose it in Watermark."
    const val BORDER_NOTE = "Opens first in Border. It is never added to a photo automatically."
    const val VERSION = "Version"
    const val SUPPORT_NOTE = "Questions or a problem with a photo? Contact us and include your version number."
    const val CONTACT_SUPPORT = "Contact support"

    fun favouritesSub(count: Int) = "$count of ${UserPreferences.MAX_FAVOURITES} · shortcuts, never applied automatically"
    fun favouritesFree(free: Int) = "$free free. Star a preset in Develop to add it."
}

/** What a More page can do. One instance per screen; the shell routes each call. */
class MoreActions(
    val openPage: (MorePage) -> Unit,
    val back: () -> Unit,
    val close: () -> Unit,
    val updatePreferences: ((UserPreferences) -> UserPreferences) -> Unit,
    val openSupport: (String) -> Unit,
    /** Preferences › Saved signature (Watermark, slice 5). */
    val drawSignature: () -> Unit = {},
    val importSignature: () -> Unit = {},
    val deleteSignature: () -> Unit = {},
    /** A double tap on the page's empty background: the next theme (owner amendment 2026-10-11, [ThemeCycle]). */
    val cycleTheme: (() -> Unit)? = null,
)

/** Data the pages show. [versionLabel] is "<versionName> (<versionCode>)" from BuildConfig. */
class MoreContent(
    val preferences: UserPreferences,
    val catalogue: PresetCatalogue,
    val releaseText: ReleaseText,
    val versionLabel: String,
    /** True when Privacy Policy was opened from Welcome: its Back returns to Welcome. */
    val privacyFromWelcome: Boolean,
    /** The saved signature Preferences › Saved signature shows (the one saved last), or null. */
    val signature: com.lightlylabs.lightly.signatures.SavedSignature? = null,
    /** About › Presets, counted from the shipped look pack; null while it is being counted. */
    val packSize: com.lightlylabs.lightly.prefs.PresetPackSize? = null,
)

/**
 * One More page (Lightly 2 `morePage`): 16 dp sides; the head (the root page's large title and Close, otherwise Back
 * and the title), 12 dp above the scrolling body.
 */
@Composable
fun MorePageView(page: MorePage, content: MoreContent, actions: MoreActions, modifier: Modifier = Modifier, inSheet: Boolean = false) {
    Column(modifier.padding(start = 16.dp, end = 16.dp, top = if (inSheet) 18.dp else 0.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (page.parent == null) {
            PageHead(page.title, LightlyIcons.Close, "Close", actions.close, root = true)
        } else {
            PageHead(page.title, LightlyIcons.BackChevron, "Back", actions.back)
        }
        Column(
            Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(bottom = 16.dp).testTagResource("more-page-${page.name.lowercase()}"),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            when (page) {
                MorePage.MORE -> MoreBody(content, actions)
                MorePage.FAVOURITES -> FavouritesBody(content.preferences, content.catalogue, actions)
                MorePage.SIGNATURE -> SignatureBody(content.signature, actions)
                MorePage.PREFERRED_BORDER -> PreferredBorderBody(content.preferences, actions)
                MorePage.LEGAL -> L2Card {
                    ListRow(MorePage.PRIVACY.title, onClick = { actions.openPage(MorePage.PRIVACY) }, tag = "row-privacy", first = true)
                    ListRow(MorePage.TERMS.title, onClick = { actions.openPage(MorePage.TERMS) }, tag = "row-terms")
                }
                MorePage.PRIVACY -> ReleaseDocumentBody(content.releaseText.privacyPolicy, "https://lightly.pro/privacy", actions.openSupport)
                MorePage.TERMS -> ReleaseDocumentBody(content.releaseText.termsOfUse, "https://lightly.pro/terms", actions.openSupport)
                MorePage.ABOUT -> AboutBody(content, actions)
            }
        }
    }
}

/**
 * The More page (`morePage('more')`): the app card; Appearance (the three preview tiles); Shortcuts (Favourite presets,
 * Saved signature); Saving (Preferred border, Keep photo metadata, Include location); Help (About, Legal).
 */
@Composable
private fun MoreBody(content: MoreContent, actions: MoreActions) {
    val colors = lightlyColors
    val preferences = content.preferences
    L2Card(padding = androidx.compose.foundation.layout.PaddingValues(horizontal = 14.dp, vertical = 12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            LightlyMark(44.dp, tile = true)
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(StartCopy.WORDMARK, style = l2TextStyle(16.sp, FontWeight.SemiBold, colors.ink))
                Text("${MoreCopy.VERSION} ${content.versionLabel}", style = l2TextStyle(12.sp, color = colors.ink2),
                    modifier = Modifier.testTagResource("about-version"))
            }
        }
    }
    Column {
        GroupLabel(MoreCopy.APPEARANCE)
        AppearanceTiles(preferences.appearance) { appearance -> actions.updatePreferences { it.copy(appearance = appearance) } }
    }
    Column {
        GroupLabel(MoreCopy.SHORTCUTS)
        L2Card {
            ListRow(MorePage.FAVOURITES.title, sub = MoreCopy.favouritesSub(preferences.favouritePresetIds.size),
                onClick = { actions.openPage(MorePage.FAVOURITES) }, tag = "row-favourites", first = true) {
                // Without an open photo the favourite thumbnails are chip-filled circles.
                Row(horizontalArrangement = Arrangement.spacedBy((-8).dp)) {
                    preferences.favouritePresetIds.take(3).forEach { _ ->
                        Box(Modifier.size(30.dp).background(colors.surface, androidx.compose.foundation.shape.CircleShape).padding(2.dp)
                            .background(colors.chip, androidx.compose.foundation.shape.CircleShape))
                    }
                }
                LightlyIcon(LightlyIcons.Chevron, size = 18.dp, tint = colors.ink3)
            }
            ListRow(MorePage.SIGNATURE.title, sub = MoreCopy.SAVED_SIGNATURE_SUB, onClick = { actions.openPage(MorePage.SIGNATURE) }, tag = "row-signature") {
                content.signature?.let { com.lightlylabs.lightly.editor.SavedSignatureGlyph(it, 20.dp, colors.ink) }
                LightlyIcon(LightlyIcons.Chevron, size = 18.dp, tint = colors.ink3)
            }
        }
    }
    Column {
        GroupLabel(MoreCopy.SAVING)
        L2Card {
            ListRow(MorePage.PREFERRED_BORDER.title, onClick = { actions.openPage(MorePage.PREFERRED_BORDER) }, tag = "row-preferred-border", first = true) {
                Text(preferences.preferredBorder.label, style = l2TextStyle(14.sp, color = colors.ink3))
                LightlyIcon(LightlyIcons.Chevron, size = 18.dp, tint = colors.ink3)
            }
            SwitchRow(MoreCopy.KEEP_METADATA, MoreCopy.KEEP_METADATA_SUB, preferences.keepPhotoMetadata,
                onCheckedChange = { on -> actions.updatePreferences { it.copy(keepPhotoMetadata = on) } }, tag = ShellTags.KEEP_METADATA)
            SwitchRow(MoreCopy.INCLUDE_LOCATION, MoreCopy.INCLUDE_LOCATION_SUB, preferences.includeLocation,
                onCheckedChange = { on -> actions.updatePreferences { it.copy(includeLocation = on) } }, tag = ShellTags.INCLUDE_LOCATION)
        }
    }
    Column {
        GroupLabel("Help")
        L2Card {
            ListRow(MorePage.ABOUT.title, sub = "Details and support email", onClick = { actions.openPage(MorePage.ABOUT) }, tag = "row-about", first = true)
            ListRow(MorePage.LEGAL.title, sub = "Privacy Policy, Terms of Use", onClick = { actions.openPage(MorePage.LEGAL) }, tag = "row-legal")
        }
    }
}

/**
 * `appearanceTiles`: a card (16/12/14 dp padding) with System, Light and Dark previews (64×76 dp, 14 dp corners; the
 * chosen one with a 2 dp accent border and a 22 dp lime check badge), 13 sp labels (bold when chosen).
 */
@Composable
private fun AppearanceTiles(selected: Appearance, onSelect: (Appearance) -> Unit) {
    val colors = lightlyColors
    L2Card(padding = androidx.compose.foundation.layout.PaddingValues(start = 12.dp, end = 12.dp, top = 16.dp, bottom = 14.dp)) {
        Row(Modifier.fillMaxWidth()) {
            listOf(Appearance.SYSTEM to MoreCopy.SYSTEM, Appearance.LIGHT to MoreCopy.LIGHT, Appearance.DARK to MoreCopy.DARK).forEach { (value, label) ->
                val on = value == selected
                Column(
                    Modifier.weight(1f).selectable(selected = on, role = Role.RadioButton) { onSelect(value) }.testTagResource("segment-$label")
                        .semantics { if (on) contentDescription = "$label, selected" },
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Box(Modifier.size(width = 64.dp, height = 76.dp)) {
                        Box(
                            Modifier.fillMaxSize().border(if (on) 2.dp else 1.dp, if (on) colors.sel else colors.hair, androidx.compose.foundation.shape.RoundedCornerShape(14.dp))
                                .padding(3.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(10.dp)),
                        ) { AppearancePreview(value) }
                        if (on) {
                            Box(
                                Modifier.align(Alignment.TopEnd).offset(x = 6.dp, y = (-6).dp).size(22.dp)
                                    .border(2.dp, colors.surface, androidx.compose.foundation.shape.CircleShape)
                                    .background(colors.accent, androidx.compose.foundation.shape.CircleShape),
                                contentAlignment = Alignment.Center,
                            ) { LightlyIcon(LightlyIcons.Check, size = 13.dp, tint = colors.onAccent) }
                        }
                    }
                    Text(label, style = l2TextStyle(13.sp, if (on) FontWeight.Bold else FontWeight.SemiBold, colors.ink))
                }
            }
        }
    }
}

/** The preview: the theme's background (System split diagonally), two text lines and a lime pill. */
@Composable
private fun AppearancePreview(value: Appearance) {
    val ink = when (value) { Appearance.LIGHT -> androidx.compose.ui.graphics.Color(0xFF141513); Appearance.DARK -> androidx.compose.ui.graphics.Color(0xFFF2F3F0); else -> androidx.compose.ui.graphics.Color(0xFF8A8E86) }
    androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
        val light = androidx.compose.ui.graphics.Color(0xFFF3F3F0); val dark = androidx.compose.ui.graphics.Color(0xFF0D0E10)
        when (value) {
            Appearance.LIGHT -> drawRect(light)
            Appearance.DARK -> drawRect(dark)
            else -> {
                drawRect(dark)
                drawPath(androidx.compose.ui.graphics.Path().apply { moveTo(0f, 0f); lineTo(size.width, 0f); lineTo(0f, size.height); close() }, light)
            }
        }
        val u = 1.dp.toPx()
        drawRoundRect(ink.copy(alpha = 0.9f), Offset(5 * u, 6 * u), androidx.compose.ui.geometry.Size(size.width - 10 * u, 5 * u), androidx.compose.ui.geometry.CornerRadius(3 * u))
        drawRoundRect(ink.copy(alpha = 0.45f), Offset(5 * u, 16 * u), androidx.compose.ui.geometry.Size(size.width - 20 * u, 4 * u), androidx.compose.ui.geometry.CornerRadius(2 * u))
        drawRoundRect(androidx.compose.ui.graphics.Color(0xFFCFF26B), Offset(5 * u, size.height - 15 * u), androidx.compose.ui.geometry.Size(22 * u, 10 * u), androidx.compose.ui.geometry.CornerRadius(5 * u))
    }
}

/**
 * Favourite presets: reorder by dragging the grip (or TalkBack's Move up / Move down), remove with
 * the bin. Adding happens only by starring in Develop (slice 2), never here.
 */
@Composable
private fun FavouritesBody(preferences: UserPreferences, catalogue: PresetCatalogue, actions: MoreActions) {
    val colors = lightlyColors
    Note(MoreCopy.FAVOURITES_NOTE)
    val ids = preferences.favouritePresetIds
    if (ids.isNotEmpty()) L2Card {
    var draggedIndex by remember { mutableIntStateOf(-1) }
    var dragOffsetPx by remember { mutableFloatStateOf(0f) }
    var rowHeightPx by remember { mutableIntStateOf(1) }
    val currentIds by rememberUpdatedState(ids)
    ids.forEachIndexed { index, id ->
        val preset = catalogue.preset(id)
        // An id the bundled catalogue no longer has is still shown (by id) so it can be removed.
        val name = preset?.displayName ?: id
        val dragging = index == draggedIndex
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 58.dp)
                .onSizeChanged { rowHeightPx = it.height.coerceAtLeast(1) }
                .zIndex(if (dragging) 1f else 0f)
                .graphicsLayer { translationY = if (dragging) dragOffsetPx else 0f }
                .drawBehind {
                    drawRect(colors.surface)
                    if (index > 0) drawLine(colors.hair, Offset(0f, 0.5.dp.toPx()), Offset(size.width, 0.5.dp.toPx()), 1.dp.toPx())
                }
                .semantics(mergeDescendants = true) {
                    customActions = listOfNotNull(
                        CustomAccessibilityAction("Move up") { actions.updatePreferences { it.withFavouriteMoved(index, index - 1) }; true }.takeIf { index > 0 },
                        CustomAccessibilityAction("Move down") { actions.updatePreferences { it.withFavouriteMoved(index, index + 1) }; true }.takeIf { index < ids.lastIndex },
                    )
                }
                .padding(start = 14.dp, end = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(
                Modifier
                    .size(width = 24.dp, height = 44.dp)
                    .pointerInput(id) {
                        detectDragGestures(
                            onDragStart = { draggedIndex = currentIds.indexOf(id); dragOffsetPx = 0f },
                            onDragEnd = { draggedIndex = -1; dragOffsetPx = 0f },
                            onDragCancel = { draggedIndex = -1; dragOffsetPx = 0f },
                        ) { change, amount ->
                            change.consume()
                            dragOffsetPx += amount.y
                            // Swap with a neighbour once the row has travelled past half of it.
                            val steps = (dragOffsetPx / rowHeightPx).roundToInt()
                            if (steps != 0 && draggedIndex >= 0) {
                                val target = (draggedIndex + steps).coerceIn(0, currentIds.lastIndex)
                                if (target != draggedIndex) {
                                    val from = draggedIndex
                                    actions.updatePreferences { it.withFavouriteMoved(from, target) }
                                    dragOffsetPx -= (target - from) * rowHeightPx
                                    draggedIndex = target
                                }
                            }
                        }
                    }
                    .semantics { contentDescription = "Reorder" },
                contentAlignment = Alignment.Center,
            ) { LightlyIcon(LightlyIcons.Grip, size = 18.dp, tint = colors.ink3) }
            Box(Modifier.size(36.dp).background(colors.chip, androidx.compose.foundation.shape.CircleShape))
            Column(Modifier.weight(1f)) {
                Text(name, style = l2TextStyle(15.sp, FontWeight.SemiBold, colors.ink))
                preset?.categoryName?.let { Text(it, style = l2TextStyle(12.sp, color = colors.ink2)) }
            }
            IconTapTarget(LightlyIcons.Trash, "Remove", onClick = { actions.updatePreferences { it.withFavouriteRemoved(id) } }, tag = "favourite-remove-$index")
        }
    }
    }
    val free = UserPreferences.MAX_FAVOURITES - ids.size
    if (free > 0) Note(MoreCopy.favouritesFree(free))
}

/**
 * Saved signature (prototype `signature` page): the saved signature 54 dp tall in ink, centred in a padded
 * band with a hairline below; Draw a new signature; Import from a photo; Delete saved signature (danger);
 * the note. With nothing saved there is no signature to show or delete.
 */
@Composable
private fun SignatureBody(signature: com.lightlylabs.lightly.signatures.SavedSignature?, actions: MoreActions) {
    val colors = lightlyColors
    L2Card {
        Box(Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(vertical = 26.dp).testTagResource("saved-signature"), contentAlignment = Alignment.Center) {
            if (signature != null) com.lightlylabs.lightly.editor.SavedSignatureGlyph(signature, 64.dp, colors.ink)
            else Text("No saved signature", style = l2TextStyle(15.sp, color = colors.ink3))
        }
    }
    L2Card {
        ListRow(MoreCopy.DRAW_SIGNATURE, onClick = actions.drawSignature, tag = "row-draw-signature", first = true)
        ListRow(MoreCopy.IMPORT_SIGNATURE, onClick = actions.importSignature, tag = "row-import-signature")
        if (signature != null) ListRow(MoreCopy.DELETE_SIGNATURE, onClick = actions.deleteSignature, labelColor = colors.danger, tag = "row-delete-signature", trailing = null)
    }
    Note(MoreCopy.SIGNATURE_NOTE)
}

@Composable
private fun PreferredBorderBody(preferences: UserPreferences, actions: MoreActions) {
    val colors = lightlyColors
    L2Card {
        // Owner, 2026-10-12: Paper is no longer offered (the enum keeps it so a stored value still reads).
        PreferredBorder.entries.filter { it != PreferredBorder.PAPER }.forEachIndexed { index, border ->
            val selected = border == preferences.preferredBorder
            ListRow(
                border.label,
                onClick = { actions.updatePreferences { it.copy(preferredBorder = border) } },
                tag = "border-${border.name.lowercase()}",
                first = index == 0,
                modifier = Modifier.semantics { if (selected) contentDescription = "${border.label}, selected" },
                trailing = if (selected) { { LightlyIcon(LightlyIcons.Check, size = 20.dp, tint = colors.sel) } } else { {} },
            )
        }
    }
    Note(MoreCopy.BORDER_NOTE)
}

/** Privacy Policy or Terms of Use (`doc`): the address (14 sp accent), each heading (15 sp bold) and paragraph (14 sp ink2, 1.5). */
@Composable
private fun ReleaseDocumentBody(document: ReleaseDocument?, onlineUrl: String, openUrl: (String) -> Unit) {
    val colors = lightlyColors
    if (document == null) {
        Note(ReleaseText.UNAVAILABLE_DOCUMENT, Modifier.testTagResource("document-unavailable"))
        return
    }
    Column(Modifier.padding(horizontal = 4.dp)) {
        Text(onlineUrl.removePrefix("https://"), style = l2TextStyle(14.sp, FontWeight.SemiBold, colors.sel),
            modifier = Modifier.clickable(role = Role.Button) { openUrl(onlineUrl) }.testTagResource("legal-online").padding(top = 2.dp, bottom = 14.dp))
        document.sections.forEach { section ->
            if (section.heading.isNotBlank()) Text(section.heading, style = l2TextStyle(15.sp, FontWeight.Bold, colors.ink), modifier = Modifier.padding(bottom = 6.dp).semantics { heading() })
            Text(section.body, style = l2TextStyle(14.sp, color = colors.ink2, lineHeight = 1.5f), modifier = Modifier.padding(bottom = 16.dp))
        }
    }
}

/**
 * About (owner 2026-10-10: details, then the support email, no Support page): the app-icon tile (72 dp), "Lightly"
 * (22 sp heading), the version; the description; the details card; "Support" and the email row (opens mail).
 */
@Composable
private fun AboutBody(content: MoreContent, actions: MoreActions) {
    val colors = lightlyColors
    Column(Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 6.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        LightlyMark(72.dp, tile = true)
        Text(StartCopy.WORDMARK, style = l2TextStyle(22.sp, FontWeight.SemiBold, colors.ink), modifier = Modifier.semantics { heading() })
        Text("${MoreCopy.VERSION} ${content.versionLabel}", style = l2TextStyle(13.sp, color = colors.ink2), modifier = Modifier.testTagResource("about-version"))
    }
    Text(
        "A photo editor that develops your photo in one tap, then lets you fine-tune it with presets, background, portrait, effects, watermark and border.",
        style = l2TextStyle(14.sp, color = colors.ink2, lineHeight = 1.5f), textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp),
    )
    L2Card {
        listOf(
            "Editing" to "On your device", "Account" to "Not needed", "Advertising and analytics" to "None",
            "Presets" to (content.packSize?.let { "${String.format(java.util.Locale.getDefault(), "%,d", it.presets)} in ${it.categories} categories" } ?: "…"),
            "Website" to "lightly.pro",
        ).forEachIndexed { index, (label, value) ->
            Row(
                Modifier.fillMaxWidth().heightIn(min = 46.dp).then(if (index > 0) Modifier.hairlineAbove(colors.hair) else Modifier).padding(horizontal = 16.dp)
                    .semantics(mergeDescendants = true) {},
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(label, style = l2TextStyle(14.sp, color = colors.ink2), modifier = Modifier.weight(1f))
                Text(value, style = l2TextStyle(14.sp, FontWeight.SemiBold, colors.ink), textAlign = androidx.compose.ui.text.style.TextAlign.End)
            }
        }
    }
    Column {
        GroupLabel("Support")
        L2Card {
            ListRow(SUPPORT_EMAIL, sub = "Questions or a problem with a photo? Include your version number.",
                onClick = { actions.openSupport("mailto:$SUPPORT_EMAIL") }, tag = "support-contact", first = true) {
                LightlyIcon(LightlyIcons.Mail, size = 20.dp, tint = colors.sel)
            }
        }
    }
}

const val SUPPORT_EMAIL = "hello@lightly.pro"

/** Fills the remaining space of a full-screen page. */
@Composable
fun FullScreenMorePage(page: MorePage, content: MoreContent, actions: MoreActions) {
    MorePageView(page, content, actions, Modifier.fillMaxSize().doubleTapEmptySpace(actions.cycleTheme).testTagResource("more-background"))
}

