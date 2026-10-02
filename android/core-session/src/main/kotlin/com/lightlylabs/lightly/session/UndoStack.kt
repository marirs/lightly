package com.lightlylabs.lightly.session

import kotlinx.serialization.Serializable

/**
 * Linear, session-scoped undo history (spec §3, D10): a list of committed [EditState]s and a cursor
 * pointing at the current one. Immutable so it can be published through a StateFlow and written to
 * SavedStateHandle / the recovery snapshot without defensive copies.
 *
 * Invariants (checked in init, so a corrupted snapshot fails to decode instead of misbehaving):
 * - at least one entry (the Auto baseline the session starts from);
 * - `cursor` indexes an entry;
 * - at most [capacity] entries.
 */
@Serializable
data class UndoStack(
    val entries: List<EditState>,
    val cursor: Int,
    val capacity: Int = DEFAULT_CAPACITY,
) {
    init {
        require(capacity >= 1) { "capacity must be >= 1, was $capacity" }
        require(entries.isNotEmpty()) { "UndoStack needs at least the baseline entry" }
        require(entries.size <= capacity) { "UndoStack holds ${entries.size} entries, over capacity $capacity" }
        require(cursor in entries.indices) { "cursor $cursor outside 0..${entries.lastIndex}" }
    }

    val current: EditState get() = entries[cursor]
    val canUndo: Boolean get() = cursor > 0
    val canRedo: Boolean get() = cursor < entries.lastIndex

    /**
     * Pushes one step. Redo entries beyond the cursor are discarded (a new commit forks history),
     * and when the cap is exceeded the oldest entry is dropped, which also drops the ability to
     * undo back to it — the spec accepts that for a 50-step cap.
     */
    fun commit(next: EditState): UndoStack {
        val kept = entries.subList(0, cursor + 1) + next
        val trimmed = if (kept.size > capacity) kept.drop(kept.size - capacity) else kept
        return copy(entries = trimmed, cursor = trimmed.lastIndex)
    }

    /** Returns the stack with the cursor one step back, or `this` when there is nothing to undo. */
    fun undo(): UndoStack = if (canUndo) copy(cursor = cursor - 1) else this

    fun redo(): UndoStack = if (canRedo) copy(cursor = cursor + 1) else this

    companion object {
        const val DEFAULT_CAPACITY = 50

        fun startingAt(baseline: EditState, capacity: Int = DEFAULT_CAPACITY): UndoStack =
            UndoStack(entries = listOf(baseline), cursor = 0, capacity = capacity)
    }
}
