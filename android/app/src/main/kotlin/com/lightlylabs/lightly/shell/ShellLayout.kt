package com.lightlylabs.lightly.shell

import android.content.pm.ActivityInfo

/**
 * A fold as WindowManager reports it, in this window's dp coordinates. Kept free of androidx.window
 * types so [ShellLayout.decide] is a plain function.
 */
data class FoldGeometry(val isVertical: Boolean, val centerDp: Float)

/**
 * How the slice-1 screens (Welcome, messages, More) are arranged. Mirrors the prototype's
 * `layoutFor` and `L.w > 700` rules, decided from the window's size and fold, never from a model
 * name:
 * - [Compact]: phones and folded foldables. More pages are full screen.
 * - [Large]: tablets (and any window wider than 700 dp with no fold). More is a centred form sheet.
 * - [SplitVertical] / [SplitHorizontal]: an unfolded foldable. Content sits in the panes either side
 *   of the fold, and Lightly's own sheets stay inside one pane (never across the fold).
 */
sealed interface ShellLayout {
    data object Compact : ShellLayout
    data object Large : ShellLayout

    /** Vertical fold at [foldXDp]: brand / message left, actions and sheets right. */
    data class SplitVertical(val foldXDp: Float) : ShellLayout

    /** Horizontal fold at [foldYDp]: brand / message above, actions and sheets below. */
    data class SplitHorizontal(val foldYDp: Float) : ShellLayout

    val isSplit: Boolean get() = this is SplitVertical || this is SplitHorizontal

    companion object {
        /** Prototype: `L.w > 700` switches pages to sheets and the picker grid to five columns. */
        const val LARGE_WIDTH_DP = 700f

        /**
         * Any fold that crosses the window splits it, flat or half-open: the approved fold layouts put
         * nothing on the fold line in either posture.
         */
        fun decide(widthDp: Float, heightDp: Float, fold: FoldGeometry?): ShellLayout = when {
            fold != null && fold.isVertical && fold.centerDp in 1f..(widthDp - 1f) -> SplitVertical(fold.centerDp)
            fold != null && !fold.isVertical && fold.centerDp in 1f..(heightDp - 1f) -> SplitHorizontal(fold.centerDp)
            widthDp > LARGE_WIDTH_DP -> Large
            else -> Compact
        }
    }
}

/**
 * Orientation rule (Lightly 1.0): phones and folded foldables are portrait only; unfolded
 * foldables and tablets follow the device. Decided from the largest window the current display can
 * give the app (WindowMetricsCalculator.computeMaximumWindowMetrics), so it changes with
 * fold/unfold, which recreates the Activity.
 */
object OrientationPolicy {
    /** Android's own large-screen threshold (sw600dp): below it, a device is phone-sized. */
    const val PHONE_MAX_SMALLEST_WIDTH_DP = 600f

    fun requestedOrientation(displaySmallestWidthDp: Float, inMultiWindow: Boolean): Int = when {
        // A split-screen window must never force the device to rotate.
        inMultiWindow -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        displaySmallestWidthDp < PHONE_MAX_SMALLEST_WIDTH_DP -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }
}
