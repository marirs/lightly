package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.develop.LeakPack
import com.lightlylabs.lightly.develop.LeakPackEntry
import com.lightlylabs.lightly.render.image.Rgba8Image

/** A small stand-in leak pack for JVM tests: three leaks, each a solid colour (full image and thumbnail alike). */
object TestLeaks {
    val ids = listOf("leak-000000000001", "leak-000000000002", "leak-000000000003")
    private val names = listOf("Gold Fringe", "Amber Edge", "Rose Glow")
    private val colours = listOf(intArrayOf(255, 200, 80), intArrayOf(230, 120, 40), intArrayOf(240, 110, 150))

    private fun solid(width: Int, height: Int, rgb: IntArray) =
        Rgba8Image(width, height, ByteArray(width * height * 4) { if (it % 4 == 3) -1 else rgb[it % 4].toByte() })

    val library: LeakLibrary by lazy {
        val pack = LeakPack(ids.mapIndexed { i, id -> LeakPackEntry(id, names[i], "img/$id.jpg", "thumb/$id.jpg", "0".repeat(64), 32, 18) })
        // The "file" is the leak's index; decoding makes its solid colour.
        LeakLibrary(pack, readFile = { path -> byteArrayOf(ids.indexOfFirst { path.contains(it) }.toByte()) }, decode = { bytes -> solid(32, 18, colours[bytes[0].toInt()]) })
    }
}
