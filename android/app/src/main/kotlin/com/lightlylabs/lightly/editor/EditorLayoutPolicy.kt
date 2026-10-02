package com.lightlylabs.lightly.editor

import androidx.window.core.layout.WindowSizeClass
import androidx.window.core.layout.computeWindowSizeClass

/**
 * A hinge or fold in the editor's own coordinates (dp, origin at the editor's top-left), as reported
 * by WindowManager's FoldingFeature. Kept free of androidx.window types so the policy is a plain
 * function that the JVM tests can drive with any geometry.
 */
data class EditorHinge(
    val leftDp: Float,
    val topDp: Float,
    val rightDp: Float,
    val bottomDp: Float,
    val isVertical: Boolean,
    /**
     * FoldingFeature.isSeparating, or HALF_OPENED (book / tabletop posture). A flat, non-separating
     * fold is ignored: the photo may cross it because nothing physically interrupts the screen.
     */
    val separatesContent: Boolean,
)

/** Where the photo and the control panel go (spec §6). The photo always gets the larger share. */
sealed interface EditorLayout {
    /** Compact portrait: photo on top, panel below, panel capped so the photo stays visible. */
    data class Stacked(val panelMaxHeightFraction: Float) : EditorLayout

    /**
     * Photo on the left, panel on the right. [photoWidthDp] is set only when a vertical hinge decides
     * it (the photo pane ends at the hinge); otherwise the photo takes everything the panel does not.
     */
    data class SideBySide(val panelWidthDp: Float, val photoWidthDp: Float? = null, val hingeGapDp: Float = 0f) : EditorLayout

    /** Tabletop posture: photo above the horizontal hinge, controls below it. */
    data class AboveHinge(val photoHeightDp: Float, val hingeGapDp: Float) : EditorLayout
}

object EditorLayoutPolicy {
    /** Spec §6: the side panel is 320–380 dp wide. */
    const val PANEL_MIN_WIDTH_DP = 320f
    const val PANEL_MAX_WIDTH_DP = 380f
    private const val PANEL_WIDTH_SHARE = 0.32f

    /** The photo keeps at least this much width beside a panel, whatever the panel's minimum says. */
    private const val PHOTO_MIN_WIDTH_SHARE = 0.4f

    /**
     * Spec §6 says the compact panel is at most 35% of the height and the photo keeps at least 40%
     * at large text. The panel scrolls inside its cap, so the cap only decides how much is visible
     * without scrolling: 40% at normal text, 58% from 1.3× (so the photo always keeps over 40%).
     * v3 differs from the spec's 35%: at 35% the Look slider and Save copy did not both fit
     * without scrolling on a 6.3" phone; recorded in docs/m2/android-foundation.md.
     */
    const val STACKED_PANEL_FRACTION = 0.40f
    const val STACKED_PANEL_FRACTION_LARGE_TEXT = 0.58f
    const val LARGE_FONT_SCALE = 1.3f

    fun decide(widthDp: Float, heightDp: Float, fontScale: Float, hinge: EditorHinge?): EditorLayout {
        if (hinge != null && hinge.separatesContent && hinge.isInside(widthDp, heightDp)) {
            return if (hinge.isVertical) {
                // Book posture: the photo fills the left pane and never crosses the hinge.
                EditorLayout.SideBySide(
                    panelWidthDp = widthDp - hinge.rightDp,
                    photoWidthDp = hinge.leftDp,
                    hingeGapDp = hinge.rightDp - hinge.leftDp,
                )
            } else {
                EditorLayout.AboveHinge(photoHeightDp = hinge.topDp, hingeGapDp = hinge.bottomDp - hinge.topDp)
            }
        }
        val sizeClass = WindowSizeClass.BREAKPOINTS_V1.computeWindowSizeClass(widthDp, heightDp)
        val wide = sizeClass.isWidthAtLeastBreakpoint(WindowSizeClass.WIDTH_DP_MEDIUM_LOWER_BOUND)
        val landscape = widthDp > heightDp
        if (wide || landscape) return EditorLayout.SideBySide(panelWidthDp = sidePanelWidth(widthDp))
        val fraction = if (fontScale >= LARGE_FONT_SCALE) STACKED_PANEL_FRACTION_LARGE_TEXT else STACKED_PANEL_FRACTION
        return EditorLayout.Stacked(panelMaxHeightFraction = fraction)
    }

    private fun sidePanelWidth(widthDp: Float): Float {
        val preferred = (widthDp * PANEL_WIDTH_SHARE).coerceIn(PANEL_MIN_WIDTH_DP, PANEL_MAX_WIDTH_DP)
        // A very narrow landscape window: the photo still gets its share; the panel scrolls and wraps.
        return minOf(preferred, widthDp * (1f - PHOTO_MIN_WIDTH_SHARE))
    }

    /** A hinge outside the editor's area (e.g. reported for another window region) is ignored. */
    private fun EditorHinge.isInside(widthDp: Float, heightDp: Float): Boolean =
        if (isVertical) leftDp > 0f && rightDp < widthDp else topDp > 0f && bottomDp < heightDp
}
