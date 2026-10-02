package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.session.LookRef

/** One stop of a category's stepped slider (spec D6). Stop 0 of every category is "Auto" (no Look). */
class LookDefinition(
    val lookId: String,
    val lookVersion: Int,
    val category: String,
    /** 1-based: stop 0 is the implicit Auto stop. */
    val stopIndex: Int,
    val displayName: String,
    val lut: Lut3D,
) {
    fun ref(strength: Float = 1f) = LookRef(lookId, lookVersion, strength)
}

/**
 * Looks by category, with exact-ID lookup only (spec §4.5: no fuzzy, prefix or substring matching).
 * An unknown (lookId, lookVersion) resolves to null, which the editor shows as "Look unavailable".
 *
 * DEFERRED (core-looks, M3): loading the curated look-book JSON and sha256-checked LUT assets, and
 * the ID migration table.
 */
class LookBook(
    looks: List<LookDefinition>,
    /**
     * Shown next to the Look controls when these Looks are not validated product Looks (debug
     * builds only, see BundledLookBook). `null` for a curated, validated look-book.
     */
    val provisionalNotice: String? = null,
) {
    private val byKey = looks.associateBy { it.lookId to it.lookVersion }

    init {
        require(byKey.size == looks.size) { "Duplicate (lookId, lookVersion) in look-book" }
        looks.groupBy { it.category }.forEach { (category, stops) ->
            require(stops.map { it.stopIndex }.sorted() == (1..stops.size).toList()) { "$category stops must be 1..${stops.size}" }
        }
    }

    val categories: List<String> = looks.map { it.category }.distinct()

    /** Stops 1..n of [category], in slider order. */
    fun stops(category: String): List<LookDefinition> = byKey.values.filter { it.category == category }.sortedBy { it.stopIndex }

    fun find(look: LookRef): LookDefinition? = byKey[look.lookId to look.lookVersion]

    /** Slider position for [look] in [category]: 0 (Auto) when there is no Look or it belongs elsewhere. */
    fun stopIndexOf(category: String, look: LookRef?): Int =
        look?.let { find(it) }?.takeIf { it.category == category }?.stopIndex ?: 0
}
