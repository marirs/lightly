package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.session.Bokeh
import com.lightlylabs.lightly.session.FocusStyle
import com.lightlylabs.lightly.session.Replacement

/** Background's sub-modes (prototype `ui.sub`): Focus & Blur, Change background, and Refine edges inside Focus & Blur. */
enum class BackgroundSub { FOCUS, CHANGE, REFINE }

enum class ReplacementKind(val label: String) { IMAGE("Image"), COLOUR("Colour"), GRADIENT("Gradient") }

enum class BrushMode { ADD, ERASE }

/**
 * Subject separation and depth for the photo (prototype `ui.op`): running ("Finding the subject…"),
 * finished, or failed. [depthAvailable]/[matteAvailable] say what the finished analysis produced;
 * [noClearSubject] means the segmenter ran and found none.
 */
sealed interface SeparationState {
    data object NotStarted : SeparationState
    data object Separating : SeparationState

    /** Cancelled before the matte arrived (prototype `cancelOp`): the panel shows its controls; nothing changed. */
    data object Cancelled : SeparationState
    /**
     * [depthPending]: the matte is in and depth is still being estimated. Change background and Refine
     * edges need only the matte, so they do not wait for it; Focus & Blur (and the no-subject blur) does.
     */
    data class Finished(val depthAvailable: Boolean, val matteAvailable: Boolean, val noClearSubject: Boolean, val depthPending: Boolean = false, val depthCancelled: Boolean = false) : SeparationState
}

/** Transient Background UI (never in history). */
data class BackgroundUi(
    val sub: BackgroundSub = BackgroundSub.FOCUS,
    /** The Change background tab; null = the replaced kind, else Image. */
    val kind: ReplacementKind? = null,
    val brush: BrushMode = BrushMode.ADD,
    /** Refine edges brush size (prototype `ui.brushSize`, 40); UI-only, each stroke stores its radius. */
    val brushSize: Int = 40,
    /** A slider being dragged: the recipe field's name and its transient value. */
    val sliderDrag: Pair<String, Double>? = null,
)

/** What the Background panel shows (prototype `backgroundPanel`). */
sealed interface BackgroundPanelState {
    /** Photo without a clear subject: notice + Blur only (depth-only refocus still works). */
    data object NoSubject : BackgroundPanelState
    data object Separating : BackgroundPanelState

    /**
     * Focus & Blur after the subject outline arrived, while depth is still estimated. PROPOSED copy "Estimating
     * depth…" (owner approval pending, 2026-10-07): "Finding the subject…" would be untrue once the outline is done.
     */
    data object EstimatingDepth : BackgroundPanelState

    /** The approved failure: "Couldn't separate the subject. Your other edits are kept." with Try again. */
    data object Failed : BackgroundPanelState

    /**
     * Depth failed while the subject outline is fine: only blurring is unavailable. PROPOSED copy, owner approval
     * pending (no approved depth-specific message exists; the subject message would be untrue).
     */
    data object DepthFailed : BackgroundPanelState
    data object Refine : BackgroundPanelState
    data class Change(val kind: ReplacementKind) : BackgroundPanelState
    data object Focus : BackgroundPanelState

    companion object {
        /**
         * The approved states, never a substitute: Focus & Blur needs depth, Change background and
         * Refine edges need the subject matte; whatever this build or photo cannot provide shows the
         * approved failure state rather than a mask-only or faked effect (depth-evaluation.md §R8).
         */
        fun of(ui: BackgroundUi, separation: SeparationState, replacement: Replacement?): BackgroundPanelState = when (separation) {
            SeparationState.NotStarted, SeparationState.Separating -> Separating
            // Cancel returns to the panel's controls (prototype `cancelOp`); the next edit runs the analysis again.
            SeparationState.Cancelled -> body(ui, replacement)
            is SeparationState.Finished -> {
                val depthUsable = separation.depthAvailable || separation.depthCancelled
                when {
                    // No subject: the approved notice and Blur slider at once, in either mode (prototype `backgroundPanel`
                    // returns them first). v3 differs (2026-10-07): it waited here for depth, so Change background
                    // showed "Finding the subject…" until the depth estimate finished.
                    separation.noClearSubject -> if (depthUsable || separation.depthPending) NoSubject else DepthFailed
                    ui.sub == BackgroundSub.REFINE -> if (separation.matteAvailable) Refine else Failed
                    ui.sub == BackgroundSub.CHANGE -> if (separation.matteAvailable) Change(ui.kind ?: kindOf(replacement)) else Failed
                    separation.depthPending -> EstimatingDepth
                    depthUsable -> Focus
                    separation.matteAvailable -> DepthFailed
                    else -> Failed
                }
            }
        }

        private fun body(ui: BackgroundUi, replacement: Replacement?): BackgroundPanelState = when (ui.sub) {
            BackgroundSub.REFINE -> Refine
            BackgroundSub.CHANGE -> Change(ui.kind ?: kindOf(replacement))
            else -> Focus
        }

        fun kindOf(replacement: Replacement?): ReplacementKind = when (replacement) {
            is Replacement.Colour -> ReplacementKind.COLOUR
            is Replacement.Gradient -> ReplacementKind.GRADIENT
            else -> ReplacementKind.IMAGE
        }
    }
}

/** Approved option values (docs/ui/app/data.js `SWATCHES`, `GRADIENTS`, `BACKGROUNDS`). */
object BackgroundOptions {
    val SWATCHES = listOf("#F4F1EC", "#D9D4CC", "#9AA3A8", "#3C4A55", "#1F2328", "#C9A27E", "#8A5A44", "#4E6B5A")

    /** CSS `linear-gradient(angle, a, b)` as stored in the recipe: angle, two stops at 0 and 1. */
    val GRADIENTS = listOf(160.0 to listOf("#F6D5B8", "#9EB7D6"), 180.0 to listOf("#20242C", "#5B6476"), 140.0 to listOf("#E9E4DA", "#BFC8C2"), 170.0 to listOf("#F0B7A4", "#6E5A86"))

    /** Bundled background photos: recipe AssetRef ids and asset file names. */
    val IMAGES = listOf("background.landscape_01" to "landscape_01", "background.sunset_03" to "sunset_03", "background.wellexposed_02" to "wellexposed_02", "background.backlit_02" to "backlit_02")

    val STYLES = listOf(FocusStyle.LENS to "Lens", FocusStyle.SOFT to "Soft", FocusStyle.SWIRL to "Swirl", FocusStyle.MOTION to "Motion")
    val BOKEH = listOf(Bokeh.ROUND to "round", Bokeh.HEX to "hex", Bokeh.HEART to "heart", Bokeh.STAR to "star")
}
