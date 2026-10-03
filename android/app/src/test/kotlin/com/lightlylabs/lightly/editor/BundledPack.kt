package com.lightlylabs.lightly.editor

import java.io.File
import java.util.concurrent.Executors

/**
 * The real format-3 pack and rendering contract, read in place (app/build.gradle.kts sets the paths).
 * The app cannot be built without the pack, so a missing pack FAILS rather than skips.
 */
object BundledPack {
    private val pool = Executors.newFixedThreadPool(2) { r -> Thread(r, "test-bake").apply { isDaemon = true } }

    val library: DevelopLibrary by lazy {
        val packDir = checkNotNull(System.getProperty("lightly.lookPackDir")) { "lightly.lookPackDir is not set: build shared/look-pack/out first" }
        val contract = checkNotNull(System.getProperty("lightly.renderingContract")) { "lightly.renderingContract is not set" }
        DevelopLibrary.load(File(packDir, "manifest.json").readText(), File(contract).readText(), pool, 2)
    }

    fun preset(category: String, stop: Int) = library.pack.category(category)!!.presets[stop - 1]
}
