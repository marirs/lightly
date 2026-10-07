package com.lightlylabs.lightly.background

/** The drag frame's renderWorking call as the app makes it (kept apart so the probe compiles against older code). */
object DragFrameCall {
    fun renderWorking(developed: ByteArray, analysis: BackgroundAnalysis, plan: BackgroundPlan) =
        BackgroundStage.renderWorking(developed, analysis, plan, Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW, dragFrame = true)
}
