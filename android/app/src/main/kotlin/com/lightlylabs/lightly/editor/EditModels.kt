package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.session.CropAspect
import com.lightlylabs.lightly.session.EditState
import com.lightlylabs.lightly.session.GrainStyle
import com.lightlylabs.lightly.session.LeakStyle

/** Prototype `editPanel` tabs, in order. */
enum class EditSub(val label: String) { CROP("Crop"), ROTATE("Rotate"), STRAIGHTEN("Straighten"), PERSPECTIVE("Perspective"), ADJUST("Adjust"), REMOVE("Remove") }

/** Adjust › groups (prototype `ui.group`). */
enum class AdjustGroup(val label: String) { LIGHT("Light"), COLOUR("Colour"), DETAIL("Detail") }

/** Edit › Remove's operation (approved `ed-removing`, `ed-remove-failed`). */
enum class RemoveOp { IDLE, REMOVING, FAILED }

/** A stroke brushed on the photo, in source coordinates, while it is removed or after it failed. */
data class PendingRemoveStroke(val points: List<Pair<Double, Double>>, val radius: Double)

/** Transient Edit UI (prototype `ui.sub`, `ui.group`, `ui.op`, `ui.brushSize`). Never in history. */
data class EditUi(
    val sub: EditSub = EditSub.CROP,
    val group: AdjustGroup = AdjustGroup.LIGHT,
    /** A slider being dragged: field → value (preview only until release). */
    val sliderDrag: Pair<String, Double>? = null,
    /** `ui.brushSize`: the prototype shows 35; strokes store their own radius. */
    val brushSize: Int = 35,
    val removeOp: RemoveOp = RemoveOp.IDLE,
    val pendingStroke: PendingRemoveStroke? = null,
)

/** Prototype `effectsPanel` tabs. */
enum class EffectsSub(val label: String) { LEAK("Light Leaks"), GRAIN("Grain"), VIGNETTE("Vignette") }

/**
 * Transient Border UI. [shown] is the tab on screen (prototype `ui.sub || s.border.type`); null follows the
 * recipe. It differs from the recipe only when Border opened on the preferred type with no border set.
 */
data class BorderUi(val shown: com.lightlylabs.lightly.session.BorderType? = null, val sliderDrag: Pair<String, Double>? = null)

data class EffectsUi(val sub: EffectsSub = EffectsSub.LEAK, val sliderDrag: Pair<String, Double>? = null)

object EditOptions {
    /** Prototype `ASPECTS`, in order, with their chip labels. */
    val ASPECTS = listOf(
        CropAspect.ORIGINAL to "Original", CropAspect.FREE to "Free", CropAspect.SQUARE to "1:1", CropAspect.FOUR_FIVE to "4:5",
        CropAspect.THREE_TWO to "3:2", CropAspect.SIXTEEN_NINE to "16:9", CropAspect.NINE_SIXTEEN to "9:16",
    )

    /** w/h of a fixed aspect; null for Original and Free. */
    fun ratio(aspect: CropAspect): Double? = when (aspect) {
        CropAspect.ORIGINAL, CropAspect.FREE -> null
        CropAspect.SQUARE -> 1.0
        CropAspect.FOUR_FIVE -> 4.0 / 5
        CropAspect.THREE_TWO -> 3.0 / 2
        CropAspect.SIXTEEN_NINE -> 16.0 / 9
        CropAspect.NINE_SIXTEEN -> 9.0 / 16
    }

    val LEAK_STYLES = listOf(LeakStyle.WARM to "Warm edge", LeakStyle.AMBER to "Amber flare", LeakStyle.ROSE to "Rose", LeakStyle.PRISM to "Prism")
    val GRAIN_STYLES = listOf(GrainStyle.FINE to "Fine", GrainStyle.FILM to "Film", GrainStyle.COARSE to "Coarse")

    /** Brush size 0–100 → radius up to 5 % of the long edge (as Refine edges). */
    fun brushRadius(size: Int): Double = (size / 100.0 * 0.05).coerceIn(0.002, 0.5)
}

/** Prototype `toolUsed` for Edit and Effects, exactly as approved. */
object ToolUsed {
    /**
     * Edit: a crop aspect other than Original, a turn, a horizontal flip, a straighten angle, any Adjust
     * slider, or a Remove stroke (including the one being removed or that failed: the prototype adds the
     * stroke before removing). The approved rule leaves out Flip vertical and Perspective (iOS Q1).
     */
    fun edit(state: EditState, pendingStroke: Boolean): Boolean {
        val e = state.tools.edit
        val a = e.adjust
        return e.geometry.crop.aspect != CropAspect.ORIGINAL || e.geometry.quarterTurns != 0 || e.geometry.flipHorizontal || e.geometry.straighten != 0.0 ||
            listOf(a.exposure, a.contrast, a.highlights, a.shadows, a.temp, a.tint, a.saturation, a.vibrance, a.sharpness, a.clarity, a.noise).any { it != 0.0 } ||
            e.remove.strokes.isNotEmpty() || pendingStroke
    }

    fun effects(state: EditState): Boolean = state.tools.effects.let { it.lightLeak.enabled || it.grain.enabled || it.vignette.enabled }
}
