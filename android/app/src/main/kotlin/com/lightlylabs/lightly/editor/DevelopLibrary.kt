package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.develop.DevelopGlobal
import com.lightlylabs.lightly.develop.DevelopModel
import com.lightlylabs.lightly.develop.DevelopRenderPlan
import com.lightlylabs.lightly.develop.LookPack
import com.lightlylabs.lightly.develop.LookPreset
import com.lightlylabs.lightly.develop.LutBaker
import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.session.EditState
import com.lightlylabs.lightly.session.LookRef
import java.util.concurrent.ExecutorService

/**
 * The bundled format-3 pack and Develop model, plus the per-preset 33³ bakes, cached by lookVersion
 * (a Look's pixels are a function of its lookVersion alone, so the version is the whole cache key).
 *
 * Bakes run on [bakePool] split by blue plane. The cache is a small LRU: browsing returns to recently
 * seen presets, and 32 LUTs are 18 MB.
 */
class DevelopLibrary(
    val model: DevelopModel,
    val pack: LookPack,
    private val bakePool: ExecutorService,
    private val bakeParallelism: Int,
    private val capacity: Int = 32,
    /** Called with each bake's wall-clock milliseconds (logged by the app for the performance record). */
    private val onBake: (Double) -> Unit = {},
    /** rendering-v2 `stages[watermark]` size constants (revision 2), read from the bundled contract. */
    val watermarkSizes: WatermarkSizes = WatermarkSizes.REVISION_2,
) {
    private val cache = object : LinkedHashMap<String, Lut3D>(capacity, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Lut3D>?) = size > capacity
    }

    /** Timings of every bake, for the debug benchmark (docs/v1/slice2-android.md › Performance). */
    val bakeMillis: MutableList<Double> = java.util.Collections.synchronizedList(mutableListOf())

    fun preset(look: LookRef?): LookPreset? = look?.let { pack.preset(it.lookId) }?.takeIf { it.lookVersion == look.lookVersion }

    /**
     * The preset's develop.global bake: from the cache, or baked now on the calling thread plus the pool.
     * [dimension] is the contract's 33 for every committed preview and export; the transient drag
     * preview uses [DRAG_DIMENSION] so a new stop shows within a frame or two.
     */
    fun lutFor(preset: LookPreset, dimension: Int = Lut3D.CONTRACT_DIMENSION): Lut3D {
        val key = "${preset.lookVersion}@$dimension"
        synchronized(cache) { cache[key] }?.let { return it }
        val start = System.nanoTime()
        val lut = LutBaker.bake(DevelopGlobal(preset.recipe.global, model), dimension, bakePool, bakeParallelism)
        val millis = (System.nanoTime() - start) / 1e6
        bakeMillis += millis
        if (dimension == Lut3D.CONTRACT_DIMENSION) onBake(millis)
        synchronized(cache) { cache[key] = lut }
        return lut
    }

    fun isCached(preset: LookPreset, dimension: Int = Lut3D.CONTRACT_DIMENSION): Boolean = synchronized(cache) { cache.containsKey("${preset.lookVersion}@$dimension") }

    /**
     * The render plan of [state] (Auto off: no model ships, D1). A Look whose id is not in this pack, or
     * whose version differs, is left out and never substituted (edit-recipe README › resolution rules).
     */
    fun planFor(state: EditState, globalOnly: Boolean = false): DevelopRenderPlan {
        val preset = preset(state.look)
        val dimension = if (globalOnly) DRAG_DIMENSION else Lut3D.CONTRACT_DIMENSION
        val plan = DevelopRenderPlan.of(model, autoLut = null, autoStrength = 0f, lookLut = preset?.let { lutFor(it, dimension) }, recipe = preset?.recipe, strength = state.look?.strength ?: 0f)
        return if (globalOnly) plan.globalOnly() else plan
    }

    companion object {
        /** Transient drag previews only; never committed, saved or exported (docs/v1/slice2-android.md › Rendering). */
        const val DRAG_DIMENSION = 17

        const val ASSET_MANIFEST = "lookpack/manifest.json"
        const val ASSET_CONTRACT = "lookpack/rendering-v2.json"

        /** The rendering-v2 revision this app implements. */
        const val SUPPORTED_CONTRACT_REVISION = 5

        /** Parses the bundled files; [parseMillis] receives the manifest parse + index time. */
        fun load(manifest: String, contract: String, bakePool: ExecutorService, parallelism: Int, parseMillis: (Double) -> Unit = {}, onBake: (Double) -> Unit = {}, displayNames: Map<String, String> = emptyMap()): DevelopLibrary {
            // rendering-v2 revision 2 (contract fixes 2: stage order, perspective, light leak; revision 1's
            // background.focus constants unchanged): the background.focus constants this app renders
            // with (Refocus.FocusConstants) are that revision's; the build checks the same (RenderingContractFacts).
            val revision = kotlinx.serialization.json.Json.parseToJsonElement(contract).let { root ->
                (root as? kotlinx.serialization.json.JsonObject)?.get("revision")?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content?.toIntOrNull() }
            }
            require(revision == SUPPORTED_CONTRACT_REVISION) { "rendering-v2 revision $revision; this app implements $SUPPORTED_CONTRACT_REVISION" }
            val model = DevelopModel.parse(contract)
            val start = System.nanoTime()
            val pack = LookPack.parse(manifest, model, displayNames)
            parseMillis((System.nanoTime() - start) / 1e6)
            val watermarkSizes = requireNotNull(WatermarkSizes.fromContract(contract)) { "rendering-v2 has no watermark size constants" }
            return DevelopLibrary(model, pack, bakePool, parallelism, onBake = onBake, watermarkSizes = watermarkSizes)
        }
    }
}
