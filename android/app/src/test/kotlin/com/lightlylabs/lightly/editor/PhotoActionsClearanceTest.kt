package com.lightlylabs.lightly.editor

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Owner amendment (2026-10-20, layout approved 2026-10-21): a Polaroid print keeps clear of Auto and Reset all. Same cases
 * as iOS PhotoStagePlacementTests, so both platforms place the print identically.
 */
class PhotoActionsClearanceTest {
    /** A 3:2 landscape photo in a Polaroid (sides and top 0.055, bottom 0.24 of the width): 1.11 × 0.962. */
    private val landscapePolaroid = 1.11f / (2f / 3f + 0.055f + 0.24f)
    /** Auto (38) + 6 + Reset all: 150 dp in all. */
    private val autoAndResetAll = 150f

    @Test fun aPrintThatOverlapsTheButtonsIsRaisedWhenThatIsEnough() {
        val (width, lift) = PhotoActionsClearance.placement(390f, 400f, landscapePolaroid, autoAndResetAll)
        assertEquals(390f, width, 0.01f, "raising keeps the size")
        assertEquals(400f - 60f, (400f + width / landscapePolaroid) / 2 + lift, 0.01f)
    }

    @Test fun aPrintShrinksOnlyAsMuchAsNeededToClearTheRow() {
        val (width, lift) = PhotoActionsClearance.placement(390f, 300f, landscapePolaroid, autoAndResetAll)
        assertEquals(240f, width / landscapePolaroid, 0.01f)
        assertEquals(0f, (300f - width / landscapePolaroid) / 2 + lift, 0.01f, "top-aligned at the inset")
    }

    @Test fun resetAllCountsTowardsTheOverlap() {
        assertEquals(0f, PhotoActionsClearance.placement(390f, 400f, 0.7f, 38f).second, "beside Auto alone")
        val (width, _) = PhotoActionsClearance.placement(390f, 400f, 0.7f, autoAndResetAll)
        assertEquals(340f, width / 0.7f, 0.01f)
    }

    @Test fun aNarrowPrintShrinksToSitBesideTheButtonsWhenThatKeepsItLarger() {
        assertEquals(390f - 2 * 54f to 0f, PhotoActionsClearance.placement(390f, 400f, 0.75f, 38f))
    }

    @Test fun withoutAPolaroidThePhotoKeepsThePlainFit() {
        assertEquals(390f to 0f, PhotoActionsClearance.placement(390f, 400f, landscapePolaroid, null))
    }
}
