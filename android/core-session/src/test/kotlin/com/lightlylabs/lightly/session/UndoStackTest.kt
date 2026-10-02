package com.lightlylabs.lightly.session

import com.lightlylabs.lightly.session.SessionFixtures.newSession
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class UndoStackTest {

    private fun lookNumber(index: Int) = LookRef(lookId = "natural.$index", lookVersion = "v1", strength = 1f)

    @Test
    fun `one step per committed change`() {
        var session = newSession()
        repeat(5) { index -> session = session.selectLook(lookNumber(index)) }

        assertEquals(6, session.history.entries.size)
        assertEquals(5, session.history.cursor)
    }

    @Test
    fun `history is capped at 50 entries and drops the oldest`() {
        var session = newSession()
        // 60 commits on top of the baseline = 61 states; only the newest 50 survive.
        repeat(60) { index -> session = session.selectLook(lookNumber(index)) }

        val entries = session.history.entries
        assertEquals(UndoStack.DEFAULT_CAPACITY, entries.size)
        assertEquals(lookNumber(59), session.current.look)
        assertEquals(lookNumber(10), entries.first().look, "baseline and looks 0..9 were dropped")

        // Undo is bounded by the cap: 49 steps back reaches the oldest kept entry and stops there.
        repeat(49) { session = session.undo() }
        assertFalse(session.canUndo)
        assertEquals(lookNumber(10), session.current.look)
    }

    @Test
    fun `cap is enforced with a small capacity too`() {
        var session = newSession(capacity = 3)
        repeat(4) { index -> session = session.selectLook(lookNumber(index)) }

        assertEquals(listOf(1, 2, 3).map(::lookNumber), session.history.entries.map { it.look })
        assertTrue(session.canUndo)
    }

    @Test
    fun `invariants reject an inconsistent stack`() {
        val baseline = newSession().current
        assertFailsWith<IllegalArgumentException> { UndoStack(entries = emptyList(), cursor = 0) }
        assertFailsWith<IllegalArgumentException> { UndoStack(entries = listOf(baseline), cursor = 1) }
        assertFailsWith<IllegalArgumentException> { UndoStack(entries = List(3) { baseline }, cursor = 0, capacity = 2) }
    }
}
