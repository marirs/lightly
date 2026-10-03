package com.lightlylabs.lightly.shell

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
    const val FAVOURITES_NOTE = "Up to five. Drag to reorder. Favourites are shortcuts in Develop; they are never applied automatically."
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
)

/** Data the pages show. [versionLabel] is "<versionName> (<versionCode>)" from BuildConfig. */
class MoreContent(
    val preferences: UserPreferences,
    val catalogue: PresetCatalogue,
    val releaseText: ReleaseText,
    val versionLabel: String,
    /** True when Privacy Policy was opened from Welcome: its Back returns to Welcome. */
    val privacyFromWelcome: Boolean,
)

/**
 * One More page: its head (✕ on the root page, ‹ elsewhere) and its scrolling body. The same
 * composable fills a full-screen page, a form sheet or a pane sheet; see [MorePresentation].
 */
@Composable
fun MorePageView(page: MorePage, content: MoreContent, actions: MoreActions, modifier: Modifier = Modifier) {
    Column(modifier) {
        if (page.parent == null) {
            PageHead(page.title, LightlyIcons.Close, "Close", actions.close)
        } else {
            PageHead(page.title, LightlyIcons.BackChevron, "Back", actions.back)
        }
        Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).testTagResource("more-page-${page.name.lowercase()}")) {
            when (page) {
                MorePage.MORE -> {
                    ListRow(MorePage.PREFERENCES.title, onClick = { actions.openPage(MorePage.PREFERENCES) }, tag = "row-preferences")
                    ListRow(MorePage.LEGAL.title, onClick = { actions.openPage(MorePage.LEGAL) }, tag = "row-legal")
                    ListRow(MorePage.ABOUT.title, onClick = { actions.openPage(MorePage.ABOUT) }, tag = "row-about")
                }
                MorePage.PREFERENCES -> PreferencesBody(content.preferences, actions)
                MorePage.FAVOURITES -> FavouritesBody(content.preferences, content.catalogue, actions)
                MorePage.SIGNATURE -> SignatureBody()
                MorePage.PREFERRED_BORDER -> PreferredBorderBody(content.preferences, actions)
                MorePage.LEGAL -> {
                    ListRow(MorePage.PRIVACY.title, onClick = { actions.openPage(MorePage.PRIVACY) }, tag = "row-privacy")
                    ListRow(MorePage.TERMS.title, onClick = { actions.openPage(MorePage.TERMS) }, tag = "row-terms")
                }
                MorePage.PRIVACY -> ReleaseDocumentBody(content.releaseText.privacyPolicy)
                MorePage.TERMS -> ReleaseDocumentBody(content.releaseText.termsOfUse)
                MorePage.ABOUT -> AboutBody(content.versionLabel, actions)
                MorePage.SUPPORT -> SupportBody(content.releaseText.supportDestination, content.versionLabel, actions)
            }
        }
    }
}

@Composable
private fun PreferencesBody(preferences: UserPreferences, actions: MoreActions) {
    GroupLabel(MoreCopy.APPEARANCE)
    SegmentedControl(
        options = listOf(Appearance.SYSTEM to MoreCopy.SYSTEM, Appearance.LIGHT to MoreCopy.LIGHT, Appearance.DARK to MoreCopy.DARK),
        selected = preferences.appearance,
        onSelect = { appearance -> actions.updatePreferences { it.copy(appearance = appearance) } },
    )
    GroupLabel(MoreCopy.SHORTCUTS)
    ListRow(
        MorePage.FAVOURITES.title,
        sub = MoreCopy.favouritesSub(preferences.favouritePresetIds.size),
        onClick = { actions.openPage(MorePage.FAVOURITES) },
        tag = "row-favourites",
    )
    ListRow(MorePage.SIGNATURE.title, sub = MoreCopy.SAVED_SIGNATURE_SUB, onClick = { actions.openPage(MorePage.SIGNATURE) }, tag = "row-signature")
    GroupLabel(MoreCopy.SAVING)
    val colors = lightlyColors
    ListRow(
        MorePage.PREFERRED_BORDER.title,
        sub = preferences.preferredBorder.label,
        onClick = { actions.openPage(MorePage.PREFERRED_BORDER) },
        tag = "row-preferred-border",
    ) {
        Text(preferences.preferredBorder.label, style = lightlyTextStyle(color = colors.ink3))
        LightlyIcon(LightlyIcons.Chevron, size = 18.dp, tint = colors.ink3)
    }
    SwitchRow(
        MoreCopy.KEEP_METADATA, MoreCopy.KEEP_METADATA_SUB, preferences.keepPhotoMetadata,
        onCheckedChange = { on -> actions.updatePreferences { it.copy(keepPhotoMetadata = on) } }, tag = ShellTags.KEEP_METADATA,
    )
    SwitchRow(
        MoreCopy.INCLUDE_LOCATION, MoreCopy.INCLUDE_LOCATION_SUB, preferences.includeLocation,
        onCheckedChange = { on -> actions.updatePreferences { it.copy(includeLocation = on) } }, tag = ShellTags.INCLUDE_LOCATION,
    )
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
                .heightIn(min = 52.dp)
                .onSizeChanged { rowHeightPx = it.height.coerceAtLeast(1) }
                .zIndex(if (dragging) 1f else 0f)
                .graphicsLayer { translationY = if (dragging) dragOffsetPx else 0f }
                .drawBehind {
                    if (dragging) drawRect(colors.bg2)
                    drawLine(colors.hair, Offset(0f, size.height - 0.5.dp.toPx()), Offset(size.width, size.height - 0.5.dp.toPx()), 1.dp.toPx())
                }
                .semantics(mergeDescendants = true) {
                    customActions = listOfNotNull(
                        CustomAccessibilityAction("Move up") { actions.updatePreferences { it.withFavouriteMoved(index, index - 1) }; true }.takeIf { index > 0 },
                        CustomAccessibilityAction("Move down") { actions.updatePreferences { it.withFavouriteMoved(index, index + 1) }; true }.takeIf { index < ids.lastIndex },
                    )
                }
                .padding(horizontal = 18.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(
                Modifier
                    .size(44.dp)
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
            Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
                Text(name, style = lightlyTextStyle(color = colors.ink))
                preset?.categoryName?.let { Text(it, style = lightlyTextStyle(13.sp, color = colors.ink3)) }
            }
            IconTapTarget(LightlyIcons.Trash, "Remove", onClick = { actions.updatePreferences { it.withFavouriteRemoved(id) } }, tag = "favourite-remove-$index")
        }
    }
    val free = UserPreferences.MAX_FAVOURITES - ids.size
    if (free > 0) Note(MoreCopy.favouritesFree(free))
}

/**
 * Saved signature: the page structure only. Drawing, importing and deleting arrive with Watermark.
 * DEFERRED(slice 5): signature storage, the preview of the saved signature, Draw (sigDraw) and
 * Import (sigImport) sheets, and Delete (shown only once a signature exists). Until then the two
 * rows are present but disabled rather than leading to a mock.
 */
@Composable
private fun SignatureBody() {
    ListRow(MoreCopy.DRAW_SIGNATURE, enabled = false, tag = "row-draw-signature")
    ListRow(MoreCopy.IMPORT_SIGNATURE, enabled = false, tag = "row-import-signature")
    Note(MoreCopy.SIGNATURE_NOTE)
}

@Composable
private fun PreferredBorderBody(preferences: UserPreferences, actions: MoreActions) {
    val colors = lightlyColors
    PreferredBorder.entries.forEach { border ->
        val selected = border == preferences.preferredBorder
        ListRow(
            border.label,
            onClick = { actions.updatePreferences { it.copy(preferredBorder = border) } },
            tag = "border-${border.name.lowercase()}",
            modifier = Modifier.semantics { if (selected) contentDescription = "${border.label}, selected" },
            trailing = if (selected) { { LightlyIcon(LightlyIcons.Check, size = 20.dp, tint = colors.sel) } } else null,
        )
    }
    Note(MoreCopy.BORDER_NOTE)
}

/** Release text (D2). Empty in this build, so the neutral unavailable state is shown. */
@Composable
private fun ReleaseDocumentBody(document: ReleaseDocument?) {
    val colors = lightlyColors
    if (document == null) {
        Box(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 28.dp), contentAlignment = Alignment.Center) {
            Text(ReleaseText.UNAVAILABLE_DOCUMENT, style = lightlyTextStyle(color = colors.ink2), modifier = Modifier.testTagResource("document-unavailable"))
        }
        return
    }
    Column(Modifier.padding(top = 8.dp, bottom = 24.dp)) {
        document.sections.forEach { section ->
            if (section.heading.isNotBlank()) GroupLabel(section.heading)
            Text(section.body, style = lightlyTextStyle(color = colors.ink), modifier = Modifier.padding(horizontal = 18.dp, vertical = 6.dp))
        }
    }
}

@Composable
private fun AboutBody(versionLabel: String, actions: MoreActions) {
    val colors = lightlyColors
    Column(Modifier.fillMaxWidth().padding(top = 28.dp, bottom = 18.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        LightlyMark(44.dp, colors.ink)
        Text(StartCopy.WORDMARK, style = lightlyTextStyle(19.sp, FontWeight.SemiBold, colors.ink), modifier = Modifier.semantics { heading() })
        Text("${MoreCopy.VERSION} $versionLabel", style = lightlyTextStyle(13.sp, color = colors.ink3), modifier = Modifier.testTagResource("about-version"))
    }
    ListRow(MorePage.SUPPORT.title, onClick = { actions.openPage(MorePage.SUPPORT) }, tag = "row-support")
}

/**
 * Support. The destination is release text (D2); without it there is no Contact button, because a
 * button that goes nowhere (or somewhere invented) must not ship.
 */
@Composable
private fun SupportBody(destination: String?, versionLabel: String, actions: MoreActions) {
    val colors = lightlyColors
    if (destination != null) {
        Note(MoreCopy.SUPPORT_NOTE, Modifier.padding(top = 8.dp))
        Box(Modifier.padding(horizontal = 18.dp, vertical = 8.dp)) {
            LightlyButton(MoreCopy.CONTACT_SUPPORT, ButtonKind.PRIMARY, onClick = { actions.openSupport(destination) }, tag = "support-contact")
        }
    } else {
        Box(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 20.dp), contentAlignment = Alignment.Center) {
            Text(ReleaseText.UNAVAILABLE_SUPPORT, style = lightlyTextStyle(color = colors.ink2), modifier = Modifier.testTagResource("support-unavailable"))
        }
    }
    ListRow(MoreCopy.VERSION, trailing = { Text(versionLabel, style = lightlyTextStyle(color = colors.ink3)) })
}

/** Fills the remaining space of a full-screen page. */
@Composable
fun FullScreenMorePage(page: MorePage, content: MoreContent, actions: MoreActions) {
    MorePageView(page, content, actions, Modifier.fillMaxSize())
}
