package com.lightlylabs.lightly.session

import kotlinx.serialization.Serializable

/**
 * The committed edit history of one photo, plus the revision counter. Pure and immutable: every
 * operation returns a new session, so the ViewModel can hold it in a StateFlow and persist it as-is.
 *
 * Commit rules (spec §3, edit recipe v1): one step per committed change of the WHOLE recipe (a ruler
 * release, an Amount release, an Auto toggle, any later tool's commit); redo is cleared on commit; a
 * change that leaves the state identical is NOT a step (re-selecting the current stop must not create
 * an undo entry that appears to do nothing). Undo and Redo restore complete EditStates, so every tool
 * goes back together.
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

    /** Amount release for the active Look (strength = Amount / 100). Without a Look there is no Amount. */
    fun setLookStrength(strength: Float): EditSession {
        val activeLook = checkNotNull(current.look) { "Amount is only available while a Look is active" }
        return commitIfChanged(current.copy(look = activeLook.copy(strength = strength)))
    }

    /**
     * Commits any change of the recipe as one step (the Auto switch, and the later tools). The revision
     * is assigned here; [change] must not edit it.
     */
    fun commit(change: (EditState) -> EditState): EditSession = commitIfChanged(change(current))

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
        /** Starts a session from the developed Auto baseline (every tool neutral). The baseline is revision 0. */
        fun start(source: SourceRef, auto: AutoResult, capacity: Int = UndoStack.DEFAULT_CAPACITY): EditSession {
            val baseline = EditState.initial(source, auto)
            return EditSession(history = UndoStack.startingAt(baseline, capacity), lastIssuedRevision = 0)
        }
    }
}
