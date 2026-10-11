package com.lightlylabs.lightly.session

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * `effects.lightLeak.style` (edit-recipe-v1, rendering-v2 revision 8, owner 2026-10-11): a leak-pack id or one of the four
 * drawn styles, both written as the bare string. Earlier edits keep their drawn style.
 */
class LeakStyleCodecTest {
    private val legacyLeak = """"lightLeak":{"enabled":false,"style":"warm","intensity":55,"x":18,"y":14,"rotation":0}"""

    private fun recipeWithLeak(leakJson: String): String {
        val text = SharedEditStateFixtures.readRecipe("neutral.json")
        check(legacyLeak in text) { "neutral.json no longer carries the default leak" }
        return text.replace(legacyLeak, leakJson)
    }

    @Test
    fun `a leak id decodes to an image style and re-encodes to the same bytes`() {
        val text = recipeWithLeak(""""lightLeak":{"enabled":true,"style":"leak-edf0a0ecd85d","intensity":50,"x":50,"y":50,"rotation":-30}""")
        val state = SavedEdits.decodeEditState(text)
        assertEquals(LeakStyle.Image("leak-edf0a0ecd85d"), state.tools.effects.lightLeak.style)
        assertRoundTrips(state, """"style":"leak-edf0a0ecd85d"""")
    }

    @Test
    fun `every legacy drawn style still decodes and re-encodes unchanged`() {
        for (style in LeakStyle.Drawn.entries) {
            val text = recipeWithLeak(""""lightLeak":{"enabled":true,"style":"${style.wireName}","intensity":40,"x":18,"y":14,"rotation":0}""")
            val state = SavedEdits.decodeEditState(text)
            assertEquals(style, state.tools.effects.lightLeak.style)
            assertRoundTrips(state, """"style":"${style.wireName}"""")
        }
        assertEquals(listOf("warm", "amber", "rose", "prism"), LeakStyle.Drawn.entries.map { it.wireName })
    }

    /** The style is written as the bare string, and the written recipe reads back to the same state. */
    private fun assertRoundTrips(state: EditState, expectedStyleJson: String) {
        val encoded = SavedEdits.encodeEditState(state)
        kotlin.test.assertTrue(expectedStyleJson in encoded, "expected $expectedStyleJson in $encoded")
        assertEquals(state, SavedEdits.decodeEditState(encoded))
        assertEquals(encoded, SavedEdits.encodeEditState(SavedEdits.decodeEditState(encoded)))
    }

    @Test
    fun `a style that is neither a drawn style nor a leak id fails to decode, as the schema does`() {
        for (bad in listOf("sunset", "leak-EDF0A0ECD85D", "leak-edf0a0ecd85", "leak-edf0a0ecd85d0", "Warm")) {
            assertFailsWith<IllegalArgumentException>(bad) {
                SavedEdits.decodeEditState(recipeWithLeak(""""lightLeak":{"enabled":true,"style":"$bad","intensity":40,"x":18,"y":14,"rotation":0}"""))
            }
        }
    }
}
