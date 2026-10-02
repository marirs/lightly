package com.lightlylabs.lightly.session

import kotlinx.serialization.Serializable

/**
 * The committed edit history of one photo, plus the revision counter. Pure and immutable: every
 * operation returns a new session, so the ViewModel can hold it in a StateFlow and persist it as-is.
 *
 * Commit rules (spec §3): one step per committed Look change, Strength release or Reset; redo is
 * cleared on commit; a change that leaves the state identical is NOT a step (re-selecting the
 * current stop must not create an undo entry that appears to do nothing).
 *
 * Revisions: [EditState.revision] is the commit counter. It is monotonically increasing across the
 * whole session, including after undo-then-commit, so it is tracked separately in
 * [lastIssuedRevision] rather than derived from the (possibly truncated) stack. Undo/Redo move the
 * cursor back to an existing snapshot and do not mint a revision; the render scheduler issues its
 * own request revisions (core-render) so latest-wins still holds after an undo.
 */
@Serializable
data class EditSession(
    val history: UndoStack,
    val lastIssuedRevision: Long,
) {
    init {
        require(history.entries.all { it.revision <= lastIssuedRevision }) {
            "lastIssuedRevision $lastIssuedRevision is behind a stored entry"
        }
        val sources = history.entries.map { it.source }.distinct()
        require(sources.size == 1) { "A session edits exactly one Original; found ${sources.size}" }
    }

    val current: EditState get() = history.current
    val canUndo: Boolean get() = history.canUndo
    val canRedo: Boolean get() = history.canRedo

    /** Commits [look] as the only Look, replacing any previous one (Invariant R). `null` = Auto stop. */
    fun selectLook(look: LookRef?): EditSession =
        commitIfChanged(current.copy(look = look))

    /** Strength release for the active Look. Without an active Look there is no Strength control. */
    fun setLookStrength(strength: Float): EditSession {
        val activeLook = checkNotNull(current.look) { "Strength is only available while a Look is active" }
        return commitIfChanged(current.copy(look = activeLook.copy(strength = strength)))
    }

    /** "Reset to Auto": drops the Look. Undoable like any other commit. */
    fun resetToAuto(): EditSession = commitIfChanged(current.copy(look = null))

    fun undo(): EditSession = copy(history = history.undo())

    fun redo(): EditSession = copy(history = history.redo())

    /** What a transient (uncommitted) preview of [candidate] renders. Not recorded in history. */
    fun previewOf(candidate: LookRef?): EditState = current.withCandidateLook(candidate)

    private fun commitIfChanged(proposed: EditState): EditSession {
        // Compare ignoring revision: `proposed` still carries the current revision at this point.
        if (proposed == current) return this
        val revision = lastIssuedRevision + 1
        return EditSession(history = history.commit(proposed.copy(revision = revision)), lastIssuedRevision = revision)
    }

    companion object {
        /** Starts a session from the developed Auto baseline. The baseline is revision 0. */
        fun start(source: SourceRef, auto: AutoResult, capacity: Int = UndoStack.DEFAULT_CAPACITY): EditSession {
            val baseline = EditState(source = source, auto = auto, look = null, revision = 0)
            return EditSession(history = UndoStack.startingAt(baseline, capacity), lastIssuedRevision = 0)
        }
    }
}
