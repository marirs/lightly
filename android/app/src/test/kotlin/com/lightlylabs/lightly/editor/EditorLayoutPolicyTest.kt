package com.lightlylabs.lightly.editor

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * Spec §6 placement rules, with the window sizes of the AVDs used for the evidence screenshots.
 * Controls-below vs side panel is chosen by the photo area each one displays for this window and
 * this photo's aspect ratio, not by the window's size class (d5690dd review).
 */
class EditorLayoutPolicyTest {

    private val landscapePhoto = 3f / 2f
    private val portraitPhoto = 2f / 3f

    // Window sizes in dp (safe-drawing area, approximately as on the AVDs).
    private val phonePortrait = 412f to 860f
    private val phoneLandscape = 860f to 412f
    private val tabletPortrait = 800f to 1230f
    private val tabletLandscape = 1280f to 750f
    private val foldableUnfolded = 852f to 860f

    private fun decide(window: Pair<Float, Float>, aspect: Float?, fontScale: Float = 1f, hinge: EditorHinge? = null) =
        EditorLayoutPolicy.decide(window.first, window.second, fontScale, hinge, aspect)

    // --- Phone -----------------------------------------------------------------------------------

    @Test
    fun `phone portrait stacks the panel below the photo for both photo shapes`() {
        listOf(landscapePhoto, portraitPhoto, null).forEach { aspect ->
            val layout = assertIs<EditorLayout.Stacked>(decide(phonePortrait, aspect), "aspect $aspect")
            assertEquals(EditorLayoutPolicy.STACKED_PANEL_FRACTION, layout.panelMaxHeightFraction)
        }
    }

    @Test
    fun `phone portrait never gets a side panel narrower than its minimum, even for a very tall photo`() {
        assertIs<EditorLayout.Stacked>(decide(phonePortrait, 1f / 3f, fontScale = 2f))
    }

    @Test
    fun `large text lets the panel take more height but the photo keeps at least 40 percent`() {
        val layout = assertIs<EditorLayout.Stacked>(decide(phonePortrait, landscapePhoto, fontScale = 2f))
        assertTrue(1f - layout.panelMaxHeightFraction >= 0.4f)
    }

    @Test
    fun `phone landscape puts a 320 to 380 dp panel beside the photo for both photo shapes`() {
        listOf(landscapePhoto, portraitPhoto).forEach { aspect ->
            val layout = assertIs<EditorLayout.SideBySide>(decide(phoneLandscape, aspect), "aspect $aspect")
            assertTrue(layout.panelWidthDp in 320f..380f, "panel ${layout.panelWidthDp}")
            assertEquals(null, layout.photoWidthDp)
        }
    }

    @Test
    fun `phone landscape keeps the side panel for a panorama because a stacked panel would be too short`() {
        assertIs<EditorLayout.SideBySide>(decide(phoneLandscape, 4f))
    }

    // --- Tablet ----------------------------------------------------------------------------------

    @Test
    fun `tablet portrait with a landscape photo puts the controls below`() {
        assertIs<EditorLayout.Stacked>(decide(tabletPortrait, landscapePhoto))
    }

    @Test
    fun `tablet portrait with a portrait photo puts the controls below - it shows the photo larger there too`() {
        // Stacked: box 800 x 738 → 492 x 738; side: box 480 x 1230 → 480 x 720.
        assertIs<EditorLayout.Stacked>(decide(tabletPortrait, portraitPhoto))
    }

    @Test
    fun `tablet portrait with a very tall photo uses the side panel`() {
        assertIs<EditorLayout.SideBySide>(decide(tabletPortrait, 9f / 21f))
    }

    @Test
    fun `tablet landscape uses the side panel for landscape and portrait photos`() {
        listOf(landscapePhoto, portraitPhoto).forEach { aspect ->
            val layout = assertIs<EditorLayout.SideBySide>(decide(tabletLandscape, aspect), "aspect $aspect")
            assertTrue(layout.panelWidthDp in 320f..380f)
        }
    }

    @Test
    fun `tablet landscape with a panorama puts the controls below`() {
        assertIs<EditorLayout.Stacked>(decide(tabletLandscape, 4f))
    }

    // --- Foldable --------------------------------------------------------------------------------

    private val flatFold = EditorHinge(leftDp = 426f, topDp = 0f, rightDp = 426f, bottomDp = 860f, isVertical = true, separatesContent = false)
    private val bookHinge = EditorHinge(leftDp = 424f, topDp = 0f, rightDp = 428f, bottomDp = 860f, isVertical = true, separatesContent = true)

    @Test
    fun `an unfolded foldable lying flat picks by photo shape and may span the flat fold`() {
        assertIs<EditorLayout.Stacked>(decide(foldableUnfolded, landscapePhoto, hinge = flatFold))
        val side = assertIs<EditorLayout.SideBySide>(decide(foldableUnfolded, portraitPhoto, hinge = flatFold))
        assertEquals(null, side.photoWidthDp, "a non-separating fold does not split the photo")
    }

    @Test
    fun `book posture keeps the whole photo on one side of the hinge whatever the photo shape`() {
        listOf(landscapePhoto, portraitPhoto, 4f).forEach { aspect ->
            val layout = assertIs<EditorLayout.SideBySide>(decide(foldableUnfolded, aspect, hinge = bookHinge), "aspect $aspect")
            assertEquals(424f, layout.photoWidthDp)
            assertEquals(4f, layout.hingeGapDp)
            assertEquals(852f - 428f, layout.panelWidthDp, "the panel takes the other pane")
        }
    }

    @Test
    fun `tabletop posture puts the photo above the hinge and the controls below`() {
        val hinge = EditorHinge(leftDp = 0f, topDp = 440f, rightDp = 852f, bottomDp = 444f, isVertical = false, separatesContent = true)
        val layout = assertIs<EditorLayout.AboveHinge>(decide(foldableUnfolded, portraitPhoto, hinge = hinge))
        assertEquals(440f, layout.photoHeightDp)
        assertEquals(4f, layout.hingeGapDp)
    }

    @Test
    fun `a hinge outside the editor area is ignored`() {
        val outside = EditorHinge(leftDp = 900f, topDp = 0f, rightDp = 904f, bottomDp = 860f, isVertical = true, separatesContent = true)
        assertIs<EditorLayout.SideBySide>(decide(foldableUnfolded, portraitPhoto, hinge = outside)).also { assertEquals(null, it.photoWidthDp) }
    }

    // --- The rule itself ---------------------------------------------------------------------------

    @Test
    fun `a narrow landscape window never gives the panel more than 60 percent`() {
        val layout = assertIs<EditorLayout.SideBySide>(decide(500f to 300f, landscapePhoto))
        assertTrue(layout.panelWidthDp <= 300f)
    }

    @Test
    fun `whenever both placements are allowed, the chosen one displays at least as much photo`() {
        val widths = listOf(360f, 412f, 600f, 700f, 800f, 852f, 1000f, 1280f)
        val heights = listOf(400f, 600f, 750f, 860f, 1000f, 1230f)
        val aspects = listOf(0.33f, 0.5625f, 0.75f, 1f, 1.333f, 1.5f, 1.778f, 3f)
        for (width in widths) for (height in heights) for (aspect in aspects) for (fontScale in listOf(1f, 2f)) {
            val chosen = EditorLayoutPolicy.decide(width, height, fontScale, hinge = null, photoAspectRatio = aspect)
            val candidates = EditorLayoutPolicy.candidates(width, height, fontScale)
            val chosenArea = EditorLayoutPolicy.displayedPhotoAreaDp2(chosen, width, height, aspect)
            candidates.forEach { candidate ->
                val area = EditorLayoutPolicy.displayedPhotoAreaDp2(candidate, width, height, aspect)
                assertTrue(chosenArea >= area, "$width×$height font $fontScale aspect $aspect: chose $chosen ($chosenArea) over $candidate ($area)")
            }
            if (chosen is EditorLayout.Stacked) assertTrue(1f - chosen.panelMaxHeightFraction >= 0.4f)
            if (chosen is EditorLayout.SideBySide) assertTrue(chosen.panelWidthDp <= width * 0.6f + 0.01f)
        }
    }

    @Test
    fun `without a photo yet the layout assumes a 4 by 3 landscape photo`() {
        assertEquals(decide(foldableUnfolded, 4f / 3f), decide(foldableUnfolded, null))
    }
}
