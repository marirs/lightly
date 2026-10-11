package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.develop.DevelopGlobal
import com.lightlylabs.lightly.develop.DevelopModel
import com.lightlylabs.lightly.develop.DevelopRenderPlan
import com.lightlylabs.lightly.develop.LookGlobalTable
import com.lightlylabs.lightly.develop.LookPack
import com.lightlylabs.lightly.develop.LookPreset
import com.lightlylabs.lightly.develop.LookTableDecoder
import com.lightlylabs.lightly.develop.LookTableSource
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
 *
 * Table looks ([LookPreset.globalTable]) are not baked: their 33³ file is read through [tableSource], decoded into
 * the same Lut3D and cached under the same key, so strength, preview, thumbnails and export cannot tell them apart.
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
    /** Reads table-look files by their manifest-relative path (APK assets under `lookpack/` in the app). */
    private val tableSource: LookTableSource = LookTableSource.UNAVAILABLE,
) {
    private val cache = object : LinkedHashMap<String, Lut3D>(capacity, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Lut3D>?) = size > capacity
    }

    /**
     * Table digests already checked against the manifest. A table is hashed on its first load only; a reload after an
     * LRU eviction, or at another dimension, reads the same immutable asset and skips the hash.
     */
    private val verifiedTableDigests: MutableSet<String> = java.util.Collections.synchronizedSet(mutableSetOf())

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
        preset.globalTable?.let { table -> return tableLut(table, dimension).also { synchronized(cache) { cache[key] = it } } }
        val start = System.nanoTime()
        val lut = LutBaker.bake(DevelopGlobal(preset.recipe.global, model), dimension, bakePool, bakeParallelism)
        val millis = (System.nanoTime() - start) / 1e6
        bakeMillis += millis
        if (dimension == Lut3D.CONTRACT_DIMENSION) onBake(millis)
        synchronized(cache) { cache[key] = lut }
        return lut
    }

    /**
     * A table look's develop.global at [dimension]: the decoded file at 33³, or its trilinear resample on a smaller grid
     * (thumbnails, drags). Not reported to [onBake] or [bakeMillis]: nothing is baked, and the bake timings are a
     * performance record of the model's bake alone.
     */
    private fun tableLut(table: LookGlobalTable, dimension: Int): Lut3D {
        val digestToVerify = table.lutSha256.takeUnless { it in verifiedTableDigests }
        val full = LookTableDecoder.decode(tableSource.read(table.lutFile), table.lutDimension, digestToVerify)
        verifiedTableDigests += table.lutSha256
        return LookTableDecoder.resample(full, dimension)
    }

    fun isCached(preset: LookPreset, dimension: Int = Lut3D.CONTRACT_DIMENSION): Boolean = synchronized(cache) { cache.containsKey("${preset.lookVersion}@$dimension") }

    /**
     * The render plan of [state]. [autoLut]: the photo's Auto LUT (stage 1), applied at the recipe's Auto strength; null
     * when the photo has none. A Look whose id is not in this pack, or whose version differs, is left out and never
     * substituted (edit-recipe README › resolution rules).
     */
    /** [lutDimension] overrides the Look LUT's size (preset thumbnails use [THUMBNAIL_DIMENSION]). */
    fun planFor(state: EditState, globalOnly: Boolean = false, autoLut: Lut3D? = null, lutDimension: Int? = null): DevelopRenderPlan {
        val preset = preset(state.look)
        val dimension = lutDimension ?: if (globalOnly) DRAG_DIMENSION else Lut3D.CONTRACT_DIMENSION
        val plan = DevelopRenderPlan.of(model, autoLut = autoLut, autoStrength = if (autoLut != null) state.auto.strength else 0f, lookLut = preset?.let { lutFor(it, dimension) }, recipe = preset?.recipe, strength = state.look?.strength ?: 0f)
        return if (globalOnly) plan.globalOnly() else plan
    }

    companion object {
        /** Transient drag previews only; never committed, saved or exported (docs/v1/slice2-android.md › Rendering). */
        const val DRAG_DIMENSION = 17

        /**
         * Preset thumbnails (62 dp compact, 142 dp expanded, rendered at 200 px): a 17³ bake is ~8x cheaper than the
         * contract's 33³ (~85 ms each on the motorola edge 60) and indistinguishable at that size. Never saved or exported.
         */
        const val THUMBNAIL_DIMENSION = 17

        const val ASSET_MANIFEST = "lookpack/manifest.json"
        const val ASSET_CONTRACT = "lookpack/rendering-v2.json"

        /** The manifest's directory in the APK assets: table-look files (`luts/<name>.f16`) are read relative to it. */
        const val ASSET_PACK_ROOT = "lookpack/"

        /**
         * The rendering-v2 revision this app implements (8: light leak images from the leak pack; 7: stage 11 `text` and
         * `portrait.smile`; owner amendments 2026-10-11).
         */
        const val SUPPORTED_CONTRACT_REVISION = 8

        /** Parses the bundled files; [parseMillis] receives the manifest parse + index time. */
        /** [tableSource] reads table-look files (`luts/<name>.f16`) relative to the manifest's directory. */
        fun load(manifest: String, contract: String, bakePool: ExecutorService, parallelism: Int, parseMillis: (Double) -> Unit = {}, onBake: (Double) -> Unit = {}, displayNames: Map<String, String> = emptyMap(), tableSource: LookTableSource = LookTableSource.UNAVAILABLE): DevelopLibrary {
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
            return DevelopLibrary(model, pack, bakePool, parallelism, onBake = onBake, watermarkSizes = watermarkSizes, tableSource = tableSource)
        }
    }
}
