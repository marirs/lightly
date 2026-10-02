package com.lightlylabs.lightly.editor

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

/** Where the photo and the control panel go (spec §6). */
sealed interface EditorLayout {
    /** Photo on top, panel below, panel capped so the photo stays visible. */
    data class Stacked(val panelMaxHeightFraction: Float) : EditorLayout

    /**
     * Photo on the left, panel on the right. [photoWidthDp] is set only when a vertical hinge decides
     * it (the photo pane ends at the hinge); otherwise the photo takes everything the panel does not.
     */
    data class SideBySide(val panelWidthDp: Float, val photoWidthDp: Float? = null, val hingeGapDp: Float = 0f) : EditorLayout

    /** Tabletop posture: photo above the horizontal hinge, controls below it. */
    data class AboveHinge(val photoHeightDp: Float, val hingeGapDp: Float) : EditorLayout
}

/**
 * Chooses controls-below ([EditorLayout.Stacked]) or a side panel ([EditorLayout.SideBySide]) by the
 * photo area each would DISPLAY for this window and this photo's aspect ratio, and takes the larger.
 *
 * v3 differs from d5690dd: the choice used to follow the window size class (medium width or
 * landscape → side panel). On a tablet in portrait that put a 320 dp panel beside a landscape photo
 * and left empty bands above and below it (review screenshot). A separating hinge still overrides
 * everything: the photo never crosses it.
 */
object EditorLayoutPolicy {
    /** Spec §6: the side panel is 320–380 dp wide. */
    const val PANEL_MIN_WIDTH_DP = 320f
    const val PANEL_MAX_WIDTH_DP = 380f
    private const val PANEL_WIDTH_SHARE = 0.32f

    /** The photo keeps at least this much width beside a panel, whatever the panel's minimum says. */
    private const val PHOTO_MIN_WIDTH_SHARE = 0.4f

    /**
     * A portrait window narrower than this would squeeze the side panel below [PANEL_MIN_WIDTH_DP]
     * (the photo keeps 40% of the width), so it never gets a side panel. Landscape windows always
     * may: their stacked panel would be far too short anyway.
     */
    private const val SIDE_PANEL_MIN_WINDOW_WIDTH_DP = PANEL_MIN_WIDTH_DP / (1f - PHOTO_MIN_WIDTH_SHARE)

    /**
     * Spec §6 says the compact panel is at most 35% of the height and the photo keeps at least 40%
     * at large text. The panel scrolls inside its cap (Save copy is pinned below the scrolling part),
     * so the cap only decides how much is visible without scrolling: 40% at normal text, 58% from
     * 1.3× (so the photo always keeps over 40%).
     * v3 differs from the spec's 35%: at 35% the Look slider and Save copy did not both fit
     * without scrolling on a 6.3" phone; recorded in docs/m2/android-foundation.md.
     */
    const val STACKED_PANEL_FRACTION = 0.40f
    const val STACKED_PANEL_FRACTION_LARGE_TEXT = 0.58f
    const val LARGE_FONT_SCALE = 1.3f

    /**
     * Controls below the photo need this much panel height to show the stop caption, the slider and
     * the pinned Save copy without scrolling to them. A shorter stacked panel (a phone in landscape)
     * is not offered, however much photo it would show.
     */
    const val STACKED_PANEL_MIN_HEIGHT_DP = 280f

    /**
     * Until the photo has decoded its shape is unknown. 4:3 landscape is the usual camera frame;
     * the layout is chosen again as soon as the preview arrives.
     */
    const val DEFAULT_PHOTO_ASPECT_RATIO = 4f / 3f

    fun decide(widthDp: Float, heightDp: Float, fontScale: Float, hinge: EditorHinge?, photoAspectRatio: Float? = null): EditorLayout {
        if (hinge != null && hinge.separatesContent && hinge.isInside(widthDp, heightDp)) return hingeLayout(hinge, widthDp)
        val aspect = photoAspectRatio?.takeIf { it.isFinite() && it > 0f } ?: DEFAULT_PHOTO_ASPECT_RATIO
        // maxBy keeps the first of equal areas, and Stacked comes first: on a tie the photo gets the full width.
        return candidates(widthDp, heightDp, fontScale).maxBy { displayedPhotoAreaDp2(it, widthDp, heightDp, aspect) }
    }

    /**
     * The placements this window allows, before comparing photo areas. Never empty: when neither
     * meets its minimum (a small split-screen window) controls go below, where the photo still keeps
     * at least 40% of the height.
     */
    fun candidates(widthDp: Float, heightDp: Float, fontScale: Float): List<EditorLayout> {
        val stacked = EditorLayout.Stacked(stackedPanelFraction(fontScale))
        val stackedAllowed = heightDp * stacked.panelMaxHeightFraction >= STACKED_PANEL_MIN_HEIGHT_DP
        val sideAllowed = widthDp > heightDp || widthDp >= SIDE_PANEL_MIN_WINDOW_WIDTH_DP
        val allowed = listOfNotNull(
            stacked.takeIf { stackedAllowed },
            EditorLayout.SideBySide(panelWidthDp = sidePanelWidth(widthDp)).takeIf { sideAllowed },
        )
        return allowed.ifEmpty { listOf(stacked) }
    }

    /**
     * Area (dp²) of a photo of [photoAspectRatio] fitted (ContentScale.Fit) into the photo box that
     * [layout] leaves in a [widthDp] × [heightDp] editor. The stacked panel is counted at its cap:
     * it may wrap shorter, which only gives the photo more, so the comparison is conservative.
     */
    fun displayedPhotoAreaDp2(layout: EditorLayout, widthDp: Float, heightDp: Float, photoAspectRatio: Float): Float {
        val (boxWidth, boxHeight) = when (layout) {
            is EditorLayout.Stacked -> widthDp to heightDp * (1f - layout.panelMaxHeightFraction)
            is EditorLayout.SideBySide -> (layout.photoWidthDp ?: (widthDp - layout.panelWidthDp - layout.hingeGapDp)) to heightDp
            is EditorLayout.AboveHinge -> widthDp to layout.photoHeightDp
        }
        if (boxWidth <= 0f || boxHeight <= 0f) return 0f
        val fittedWidth = minOf(boxWidth, boxHeight * photoAspectRatio)
        return fittedWidth * (fittedWidth / photoAspectRatio)
    }

    private fun stackedPanelFraction(fontScale: Float): Float =
        if (fontScale >= LARGE_FONT_SCALE) STACKED_PANEL_FRACTION_LARGE_TEXT else STACKED_PANEL_FRACTION

    /** Book posture: photo in the left pane. Tabletop: photo above the hinge. Neither crosses it. */
    private fun hingeLayout(hinge: EditorHinge, widthDp: Float): EditorLayout =
        if (hinge.isVertical) {
            EditorLayout.SideBySide(panelWidthDp = widthDp - hinge.rightDp, photoWidthDp = hinge.leftDp, hingeGapDp = hinge.rightDp - hinge.leftDp)
        } else {
            EditorLayout.AboveHinge(photoHeightDp = hinge.topDp, hingeGapDp = hinge.bottomDp - hinge.topDp)
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
