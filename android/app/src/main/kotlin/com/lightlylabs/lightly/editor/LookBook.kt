package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.session.LookRef

/**
 * One curated preset from the Look pack (spec §4.5). Every field except [lut] is copied verbatim
 * from the pack manifest; nothing here is computed from the preset's name or category.
 */
class LookDefinition(
    val lookId: String,
    /** Opaque; changes whenever the LUT changes, so a restored edit cannot replay different pixels. */
    val lookVersion: String,
    /** The preset's own name, shown on the slider as is (spec U8 decides product names later). */
    val name: String,
    val lut: Lut3D,
    /** `lightroom-hald` or `lr-model-approximation` today; unknown values are treated as approximate. */
    val lutSource: String,
    /** `validated` only once the LUT has been checked against Lightroom's own render. */
    val validation: String,
    /** Spatial (and, for HALD LUTs, adaptive) settings the LUT cannot carry. Informational in M2. */
    val omittedOperators: List<String>,
    /** Adaptive settings the model folded into the LUT as a global approximation. */
    val approximatedGlobally: List<String>,
) {
    fun ref(strength: Float = 1f) = LookRef(lookId, lookVersion, strength)

    /** Anything short of a validated Lightroom render is labelled approximate in the UI. */
    val isApproximate: Boolean
        get() = lutSource == LUT_SOURCE_MODEL_APPROXIMATION || validation != VALIDATION_VALIDATED

    companion object {
        const val LUT_SOURCE_MODEL_APPROXIMATION = "lr-model-approximation"
        const val VALIDATION_VALIDATED = "validated"
    }
}

/**
 * A category of the stepped slider (spec D5, D6). [id] is the opaque key the editor saves; [label]
 * is display text only and may change between packs (today's labels are provisional).
 */
class LookCategory(
    val id: String,
    val label: String,
    /** Slider stops 1..n in pack order (browse order); stop 0, "Auto", is implicit. */
    val stops: List<LookDefinition>,
) {
    init {
        require(stops.isNotEmpty()) { "Category $id has no Looks" }
        require(stops.map { it.lookId }.distinct().size == stops.size) { "Category $id lists a Look twice" }
    }
}

/**
 * The Looks this build ships, as loaded from the Look pack ([LookPackLoader]). Categories and their
 * stops keep the pack's order; neither the editor nor this class knows any category name or count.
 *
 * Lookup is by exact (lookId, lookVersion) only (spec §4.5: no fuzzy, prefix or substring
 * matching). An unknown pair resolves to null, which the editor shows as "Look unavailable".
 *
 * DEFERRED (M3): the {oldId → newId} migration table from spec §4.5. Pack IDs depend only on the
 * preset, so relabelling or reordering categories does not need it.
 */
class LookBook(
    val categories: List<LookCategory>,
    /** Looks or categories the loader dropped, one human-readable line each. Empty when all loaded. */
    val problems: List<String> = emptyList(),
    /** Why the whole pack could not be used (missing, malformed, wrong format); null otherwise. */
    val unavailableReason: String? = null,
) {
    private val byKey: Map<Pair<String, String>, LookDefinition>
    private val byId: Map<String, LookDefinition>

    init {
        require(categories.map { it.id }.distinct().size == categories.size) { "Duplicate category id" }
        val looks = mutableMapOf<Pair<String, String>, LookDefinition>()
        categories.flatMap { it.stops }.forEach { look -> looks.putIfAbsent(look.lookId to look.lookVersion, look) }
        // A Look may sit in more than one category, but one lookId must always mean one LUT version.
        require(looks.keys.map { it.first }.distinct().size == looks.size) { "A lookId appears with two versions" }
        byKey = looks
        byId = looks.values.associateBy { it.lookId }
    }

    val isEmpty: Boolean get() = categories.isEmpty()

    fun category(id: String): LookCategory? = categories.firstOrNull { it.id == id }

    /** Stops 1..n of [categoryId], in slider order; empty for an unknown category. */
    fun stops(categoryId: String): List<LookDefinition> = category(categoryId)?.stops.orEmpty()

    fun find(look: LookRef): LookDefinition? = byKey[look.lookId to look.lookVersion]

    /**
     * Exact ID first, then exact version. A different version is reported as [LookResolution.Changed]
     * (with the pack's current Look, for "Use current version"), never rendered in its place.
     */
    fun resolve(look: LookRef): LookResolution {
        val current = byId[look.lookId] ?: return LookResolution.Unavailable(look)
        return if (current.lookVersion == look.lookVersion) LookResolution.Available(current) else LookResolution.Changed(look, current)
    }

    /** The first category listing [look], for labels; null when this build does not have it. */
    fun categoryOf(look: LookRef): LookCategory? =
        categories.firstOrNull { category -> category.stops.any { it.lookId == look.lookId && it.lookVersion == look.lookVersion } }

    /** Slider position for [look] in [categoryId]: 0 (Auto) when there is no Look or it is not a stop there. */
    fun stopIndexOf(categoryId: String, look: LookRef?): Int {
        if (look == null) return 0
        val index = stops(categoryId).indexOfFirst { it.lookId == look.lookId && it.lookVersion == look.lookVersion }
        return index + 1 // -1 (not found) becomes 0, Auto
    }

    /** True when any Look on offer is not a validated Lightroom render (all of them, today). */
    val hasApproximateLooks: Boolean get() = byKey.values.any { it.isApproximate }

    companion object {
        /** Same wording as iOS. */
        const val APPROXIMATE_NOTICE = "Looks are approximate conversions, not yet checked against Lightroom."
        const val NO_LOOKS_NOTICE = "No Looks are available in this build."

        fun unavailable(reason: String) = LookBook(categories = emptyList(), unavailableReason = reason)
    }
}
