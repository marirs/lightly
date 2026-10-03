package com.lightlylabs.lightly.session

import com.lightlylabs.lightly.session.SessionFixtures.mono
import com.lightlylabs.lightly.session.SessionFixtures.newSession
import com.lightlylabs.lightly.session.SessionFixtures.portra
import com.lightlylabs.lightly.session.SessionFixtures.warmGolden
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class EditSessionTest {

    @Test
    fun `selecting a second Look replaces the first instead of stacking`() {
        val session = newSession().selectLook(portra).selectLook(warmGolden)

        assertEquals(warmGolden, session.current.look)
        // Three entries: baseline, portra, warm. Each is a single-Look state.
        assertEquals(listOf(null, portra, warmGolden), session.history.entries.map { it.look })
    }

    @Test
    fun `preview of a candidate replaces the committed Look and is not recorded`() {
        val committed = newSession().selectLook(portra)

        val preview = committed.previewOf(warmGolden)

        assertEquals(warmGolden, preview.look, "preview must be committed.with(look = candidate), never portra∘warm")
        assertEquals(committed.current.auto, preview.auto)
        assertEquals(committed.current.revision, preview.revision, "a preview is not a commit")
        assertEquals(2, committed.history.entries.size, "preview must not push history")
    }

    @Test
    fun `undo and redo walk the linear history one commit at a time`() {
        val session = newSession().selectLook(portra).setLookStrength(0.4f).selectLook(mono)

        val back1 = session.undo()
        assertEquals(portra.copy(strength = 0.4f), back1.current.look)
        val back2 = back1.undo()
        assertEquals(portra, back2.current.look)
        val back3 = back2.undo()
        assertNull(back3.current.look)
        assertFalse(back3.canUndo)
        assertSame(back3.history, back3.undo().history, "undo at the baseline is a no-op")

        val forward = back3.redo().redo().redo()
        assertEquals(mono, forward.current.look)
        assertFalse(forward.canRedo)
    }

    @Test
    fun `a new commit after undo clears redo`() {
        val session = newSession().selectLook(portra).selectLook(mono).undo()
        assertTrue(session.canRedo)

        val forked = session.selectLook(warmGolden)

        assertFalse(forked.canRedo)
        assertEquals(listOf(null, portra, warmGolden), forked.history.entries.map { it.look })
    }

    // v3 differs: the approved Develop has no Reset control (docs/v1/slice2-android.md › UX conflicts),
    // so `resetToAuto` is gone. Choosing stop 0 on the ruler is the same commit (selectLook(null)).
    @Test
    fun `choosing stop zero is one undoable step`() {
        val withLook = newSession().selectLook(portra)

        val cleared = withLook.selectLook(null)
        assertNull(cleared.current.look)
        assertEquals(3, cleared.history.entries.size)

        val undone = cleared.undo()
        assertEquals(portra, undone.current.look)
    }

    @Test
    fun `undo restores the whole recipe, every tool together`() {
        val base = newSession()
        val edited = base.commit { state ->
            state.copy(look = portra, tools = state.tools.copy(border = state.tools.border.copy(type = BorderType.SOLID)))
        }
        assertEquals(BorderType.SOLID, edited.current.tools.border.type)

        val undone = edited.undo()
        assertEquals(base.current, undone.current)
        assertEquals(edited.current, undone.redo().current)
    }

    @Test
    fun `changes that leave the state identical are not steps`() {
        val withLook = newSession().selectLook(portra)

        assertSame(withLook, withLook.selectLook(portra))
        assertSame(withLook, withLook.setLookStrength(portra.strength))
        val baseline = newSession()
        assertSame(baseline, baseline.selectLook(null), "stop zero with no Look is no change")
        assertSame(baseline, baseline.commit { it }, "an identical recipe is no change")
    }

    @Test
    fun `strength without an active Look is rejected`() {
        assertFailsWith<IllegalStateException> { newSession().setLookStrength(0.5f) }
    }

    @Test
    fun `revisions keep increasing across undo then commit`() {
        val session = newSession().selectLook(portra).selectLook(mono) // revisions 1, 2
            .undo().undo()
            .selectLook(warmGolden)

        assertEquals(3, session.current.revision, "revision 1 and 2 were already issued; the fork must not reuse them")
        assertEquals(3, session.lastIssuedRevision)
        val revisions = session.history.entries.map { it.revision }
        assertEquals(revisions.sorted(), revisions)
    }
}
