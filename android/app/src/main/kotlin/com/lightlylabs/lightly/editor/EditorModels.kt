package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.develop.LookPack
import com.lightlylabs.lightly.develop.LookPreset
import com.lightlylabs.lightly.session.LookRef
import kotlin.math.roundToInt

/** The seven tools of the approved editor, in dock order (prototype `TOOL_NAMES`). */
enum class EditorTool(val label: String) {
    DEVELOP("Develop"),
    BACKGROUND("Background"),
    PORTRAIT("Portrait"),
    EDIT("Edit"),
    EFFECTS("Effects"),
    WATERMARK("Watermark"),
    BORDER("Border"),
}

/**
 * Whether the photo shows a person, which decides if Portrait is offered (prototype `toolsFor`: a face,
 * or people without a usable face). [PENDING] means this build has no person detector (the vision
 * models are not packaged): it is never guessed as present or absent.
 */
enum class PersonPresence {
    PRESENT, ABSENT, PENDING;

    companion object {
        fun of(people: com.lightlylabs.lightly.vision.PeopleAnalysis?): PersonPresence = when {
            people == null -> PENDING
            people.hasPerson -> PRESENT
            else -> ABSENT
        }
    }
}

/**
 * Faces with landmarks and people (docs/v1/android-vision-evaluation.md): BlazeFace full range, Face Mesh
 * V2 and the pose detector on LiteRT. Null = no detector in this build ([PersonPresence.PENDING]).
 */
fun interface PersonDetector {
    suspend fun analyse(analysis: com.lightlylabs.lightly.render.image.Rgba8Image): com.lightlylabs.lightly.vision.PeopleAnalysis?
}

/** A build without the vision models: presence stays [PersonPresence.PENDING]. */
object PendingPersonDetector : PersonDetector {
    override suspend fun analyse(analysis: com.lightlylabs.lightly.render.image.Rgba8Image): com.lightlylabs.lightly.vision.PeopleAnalysis? = null
}

object EditorTools {
    /**
     * Portrait appears only when the photo has a person. While detection is [PersonPresence.PENDING]
     * (no vision models in this build), debug builds offer it on every photo and release builds leave
     * it out, so a release never claims a person it has not found.
     */
    fun visible(presence: PersonPresence, debugBuild: Boolean): List<EditorTool> = EditorTool.entries.filter { tool ->
        tool != EditorTool.PORTRAIT || presence == PersonPresence.PRESENT || (presence == PersonPresence.PENDING && debugBuild)
    }

    /** Every tool is implemented; Portrait is offered only where [visible] allows it. */
    fun isImplemented(tool: EditorTool) = true
}

/** Prototype `s.auto`: what stage `auto` is doing for this photo. */
enum class AutoState {
    /** A real correction is applied (needs a shippable model; none exists, dependency D1). */
    APPLIED,

    /** The user turned Auto off, or continued with the original after a failure. */
    OFF,

    /** This build/device has no model: the approved "isn't available" state. */
    UNAVAILABLE,

    /** The model ran and failed: the approved Retry / Continue with original state. */
    FAILED,
}

/** The approved editor layouts (prototype `layoutFor` modes). */
enum class EditorMode { BELOW, WIDE, SIDE, SPLIT_V, SPLIT_H }

/** Layout facts for a window: mode, and the panel and content widths of the 11- and 13-inch tablets. */
data class EditorLayout(val mode: EditorMode, val widthDp: Float, val heightDp: Float, val panelWidthDp: Float, val contentWidthDp: Float) {
    /** Roomy panels (side, split V) list categories vertically and carry a "Develop" title. */
    val roomy: Boolean get() = mode == EditorMode.SIDE || mode == EditorMode.SPLIT_V

    companion object {
        /** 13-inch tablets get the wider panel (prototype `big`: panel 400, content 640). */
        private const val BIG_TABLET_SMALLEST_DP = 1000f

        /**
         * From the shell's decision (folds and the > 700 dp rule) and the window's shape: a fold splits
         * the editor, a large window is a tablet (portrait → wide, landscape → side), anything else
         * is a phone or a folded foldable (below).
         */
        fun decide(shell: com.lightlylabs.lightly.shell.ShellLayout, widthDp: Float, heightDp: Float): EditorLayout {
            val big = minOf(widthDp, heightDp) >= BIG_TABLET_SMALLEST_DP
            val mode = when (shell) {
                is com.lightlylabs.lightly.shell.ShellLayout.SplitVertical -> EditorMode.SPLIT_V
                is com.lightlylabs.lightly.shell.ShellLayout.SplitHorizontal -> EditorMode.SPLIT_H
                com.lightlylabs.lightly.shell.ShellLayout.Large -> if (heightDp >= widthDp) EditorMode.WIDE else EditorMode.SIDE
                com.lightlylabs.lightly.shell.ShellLayout.Compact -> EditorMode.BELOW
            }
            return EditorLayout(mode, widthDp, heightDp, panelWidthDp = if (big) 400f else 360f, contentWidthDp = if (big) 640f else 600f)
        }
    }
}

/** Transient Develop UI (prototype `ui.cat`, `ui.stop`, `ui.fine`, `ui.amount`, `ui.favFull`). Never in history. */
data class DevelopUi(
    /** The category being browsed; null = the applied preset's category, else Landscape. */
    val category: String? = null,
    /** The stop under the needle while a finger drags the ruler. */
    val dragStop: Int? = null,
    /** The stop a ruler drag started from; releasing there is a cancel (nothing recorded). */
    val dragStart: Int? = null,
    /** Hold-still fine mode during a drag. */
    val fine: Boolean = false,
    val amountOpen: Boolean = false,
    /** The Amount value while the slider is being dragged. */
    val amountDrag: Int? = null,
    val favouritesFull: Boolean = false,
)

/**
 * One entry of the category tabs or list. No preset count (owner amendment 2026-10-05). [selected]: the browsed category
 * (orange underline); [dotted]: it contains the applied preset (blue dot), Favourites included.
 */
data class CategoryEntry(val id: String, val label: String, val selected: Boolean, val dotted: Boolean, val isFavourites: Boolean)

sealed interface DevelopNotice {
    data object AutoFailed : DevelopNotice
    data object FavouritesFull : DevelopNotice
}

enum class AutoSwitch { ON, OFF, UNAVAILABLE }

/** Everything the Develop panel draws (prototype `developPanel`), derived purely from state. */
data class DevelopPanelModel(
    val categories: List<CategoryEntry>,
    val categoryId: String,
    val presets: List<LookPreset>,
    /** The stop under the needle: the drag stop, else the applied preset's stop in this list, else 0. */
    val stop: Int,
    val name: String,
    val position: String,
    /** A preset is under the needle: the star and Amount are shown (otherwise kept as hidden space). */
    val presetShown: Boolean,
    val starred: Boolean,
    val amount: Int,
    val context: String,
    val notice: DevelopNotice?,
    val autoSwitch: AutoSwitch,
    val amountOpen: Boolean,
    val fine: Boolean,
) {
    companion object {
        const val FAVOURITES = "favourites"
        const val DEFAULT_CATEGORY = "landscape"
        const val MAX_FAVOURITES = 5

        fun derive(
            pack: LookPack,
            look: LookRef?,
            auto: AutoState,
            favourites: List<String>,
            ui: DevelopUi,
            rememberedAmounts: Map<String, Int>,
        ): DevelopPanelModel {
            val applied = look?.let { pack.preset(it.lookId) }?.takeIf { it.lookVersion == look.lookVersion }
            val current = ui.category ?: applied?.categoryId ?: if (favourites.isNotEmpty()) FAVOURITES else DEFAULT_CATEGORY
            val favouriteMode = current == FAVOURITES
            val favouritePresets = favourites.mapNotNull(pack::preset)
            val list = if (favouriteMode) favouritePresets else pack.category(current)?.presets.orEmpty()
            val committedStop = when {
                applied == null -> 0
                favouriteMode -> favouritePresets.indexOfFirst { it.id == applied.id } + 1
                applied.categoryId == current -> list.indexOfFirst { it.id == applied.id } + 1
                else -> 0
            }
            val stop = (ui.dragStop ?: committedStop).coerceIn(0, list.size)
            val onRuler = if (stop > 0) list[stop - 1] else null
            val base = if (auto == AutoState.APPLIED) "Auto corrected · No preset" else "No preset"
            // At rest, the applied preset is named even when it is not on this category's ruler; "Original" only while
            // dragging to stop 0, when the preview is the original (owner amendment 2026-10-05).
            val offRuler = if (onRuler == null && ui.dragStop == null) applied else null
            val shown = onRuler ?: offRuler
            val offRulerCategory = offRuler?.let { pack.category(it.categoryId) }
            // While another category is browsed, the applied preset's own position goes into the context line;
            // beside the name it would read as this ruler's (owner request 2026-10-05).
            val context = if (offRuler != null && offRulerCategory != null) {
                val index = offRulerCategory.presets.indexOfFirst { it.id == offRuler.id }
                if (index >= 0) "Applied from ${offRulerCategory.name} · ${index + 1} / ${offRulerCategory.presets.size}"
                else "Applied from ${offRulerCategory.name}"
            } else ""
            val position = if (offRuler != null) "" else "$stop / ${list.size}"
            val amount = when {
                shown == null -> 100
                ui.amountDrag != null && shown.id == applied?.id -> ui.amountDrag
                shown.id == applied?.id -> (look.strength * 100).roundToInt()
                else -> rememberedAmounts[shown.id] ?: 100
            }
            val categories = buildList {
                add(CategoryEntry(FAVOURITES, "Favourites", current == FAVOURITES, dotted = applied != null && applied.id in favourites, isFavourites = true))
                pack.categories.forEach { c ->
                    add(CategoryEntry(c.id, c.name, c.id == current, dotted = applied?.categoryId == c.id, isFavourites = false))
                }
            }
            // Unavailable Auto: no standing notice (owner amendment 2026-10-05); tapping Auto explains it.
            val notice = when {
                ui.favouritesFull -> DevelopNotice.FavouritesFull
                auto == AutoState.FAILED -> DevelopNotice.AutoFailed
                else -> null
            }
            return DevelopPanelModel(
                categories = categories,
                categoryId = current,
                presets = list,
                stop = stop,
                name = shown?.displayName ?: base,
                position = position,
                presetShown = shown != null,
                starred = shown != null && shown.id in favourites,
                amount = amount,
                context = context,
                notice = notice,
                autoSwitch = when (auto) {
                    AutoState.APPLIED -> AutoSwitch.ON
                    AutoState.OFF -> AutoSwitch.OFF
                    AutoState.UNAVAILABLE, AutoState.FAILED -> AutoSwitch.UNAVAILABLE
                },
                amountOpen = ui.amountOpen && shown != null,
                fine = ui.fine,
            )
        }
    }
}
