package com.lightlylabs.lightly.editor

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** Spec §6 placement rules, with the window sizes of the AVDs used for the evidence screenshots. */
class EditorLayoutPolicyTest {

    private fun decide(width: Float, height: Float, fontScale: Float = 1f, hinge: EditorHinge? = null) =
        EditorLayoutPolicy.decide(width, height, fontScale, hinge)

    @Test
    fun `a phone in portrait stacks the panel below the photo`() {
        val layout = assertIs<EditorLayout.Stacked>(decide(412f, 860f))
        assertEquals(EditorLayoutPolicy.STACKED_PANEL_FRACTION, layout.panelMaxHeightFraction)
    }

    @Test
    fun `large text lets the panel take more height but the photo keeps at least 40 percent`() {
        val layout = assertIs<EditorLayout.Stacked>(decide(412f, 860f, fontScale = 2f))
        assertTrue(1f - layout.panelMaxHeightFraction >= 0.4f)
    }

    @Test
    fun `a phone in landscape puts a 320 to 380 dp panel beside the photo`() {
        val layout = assertIs<EditorLayout.SideBySide>(decide(860f, 412f))
        assertTrue(layout.panelWidthDp in 320f..380f, "panel ${layout.panelWidthDp}")
        assertEquals(null, layout.photoWidthDp)
    }

    @Test
    fun `a tablet uses the side panel in portrait and landscape`() {
        listOf(800f to 1280f, 1280f to 800f).forEach { (width, height) ->
            val layout = assertIs<EditorLayout.SideBySide>(decide(width, height), "$width×$height")
            assertTrue(layout.panelWidthDp in 320f..380f)
        }
    }

    @Test
    fun `an unfolded foldable lying flat uses the side panel and may span the flat fold`() {
        val flatFold = EditorHinge(leftDp = 420f, topDp = 0f, rightDp = 420f, bottomDp = 880f, isVertical = true, separatesContent = false)
        val layout = assertIs<EditorLayout.SideBySide>(decide(840f, 880f, hinge = flatFold))
        assertEquals(null, layout.photoWidthDp, "a non-separating fold does not split the photo")
    }

    @Test
    fun `book posture keeps the whole photo on one side of the hinge`() {
        val hinge = EditorHinge(leftDp = 418f, topDp = 0f, rightDp = 422f, bottomDp = 880f, isVertical = true, separatesContent = true)
        val layout = assertIs<EditorLayout.SideBySide>(decide(840f, 880f, hinge = hinge))
        assertEquals(418f, layout.photoWidthDp)
        assertEquals(4f, layout.hingeGapDp)
        assertEquals(418f, layout.panelWidthDp, "the panel takes the other pane")
        assertTrue(layout.photoWidthDp!! <= hinge.leftDp)
    }

    @Test
    fun `tabletop posture puts the photo above the hinge and the controls below`() {
        val hinge = EditorHinge(leftDp = 0f, topDp = 440f, rightDp = 840f, bottomDp = 444f, isVertical = false, separatesContent = true)
        val layout = assertIs<EditorLayout.AboveHinge>(decide(840f, 880f, hinge = hinge))
        assertEquals(440f, layout.photoHeightDp)
        assertEquals(4f, layout.hingeGapDp)
    }

    @Test
    fun `a hinge outside the editor area is ignored`() {
        val outside = EditorHinge(leftDp = 900f, topDp = 0f, rightDp = 904f, bottomDp = 880f, isVertical = true, separatesContent = true)
        assertIs<EditorLayout.SideBySide>(decide(840f, 880f, hinge = outside)).also { assertEquals(null, it.photoWidthDp) }
    }

    @Test
    fun `a narrow landscape window never gives the panel more than 60 percent`() {
        val layout = assertIs<EditorLayout.SideBySide>(decide(500f, 300f))
        assertTrue(layout.panelWidthDp <= 300f)
    }
}
