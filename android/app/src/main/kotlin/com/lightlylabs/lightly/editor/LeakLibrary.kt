package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.develop.LeakPack
import com.lightlylabs.lightly.develop.LeakPackEntry
import com.lightlylabs.lightly.render.image.Rgba8Image

/**
 * The bundled light-leak pack (rendering-v2 revision 8, owner 2026-10-11; app/build.gradle.kts BundleLeakPackTask) and its
 * decoded images. The manifest is parsed once, when the editor environment is created; images and thumbnails are decoded
 * on first use and cached, so the preview, every Save copy tile and the gallery share one decode.
 */
class LeakLibrary(
    val pack: LeakPack,
    /** Reads a pack-relative file (`img/<id>.jpg`, `thumb/<id>.jpg`); null when it cannot be read. */
    private val readFile: (String) -> ByteArray?,
    /** Decodes JPEG bytes to sRGB-encoded RGBA, unchanged (no colour management, no scaling); null on failure. */
    private val decode: (ByteArray) -> Rgba8Image?,
) {
    // Full images are ~3.7 MB each decoded (1280 × 720 RGBA): keep the one in the edit and the one before it, so moving
    // between two leaks in the gallery does not decode again. Thumbnails are small (240 px), so all of them stay.
    private val images = lruCache<String, Rgba8Image>(FULL_IMAGES_KEPT)
    private val thumbnails = lruCache<String, Rgba8Image>(Int.MAX_VALUE)

    /** The leak's full image for the renderer, or null when this build has no such leak or it cannot be decoded. */
    fun image(leakId: String): Rgba8Image? = pack.entry(leakId)?.let { load(images, it.id, it.image) }

    /** The leak's gallery thumbnail, or null when it is unavailable. */
    fun thumbnail(leakId: String): Rgba8Image? = pack.entry(leakId)?.let { load(thumbnails, it.id, it.thumbnail) }

    val leaks: List<LeakPackEntry> get() = pack.leaks

    private fun load(cache: LinkedHashMap<String, Rgba8Image>, id: String, file: String): Rgba8Image? {
        synchronized(cache) { cache[id] }?.let { return it }
        // Decoded outside the lock: two threads may decode the same file once each, which is harmless, and neither blocks.
        val decoded = readFile(file)?.let(decode) ?: return null
        synchronized(cache) { cache[id] = decoded }
        return decoded
    }

    companion object {
        private const val FULL_IMAGES_KEPT = 2

        /** No pack: the gallery offers only None and a leak id renders no light. JVM tests and builds without a pack. */
        val NONE = LeakLibrary(LeakPack.EMPTY, { null }, { null })

        private fun <K, V> lruCache(capacity: Int) = object : LinkedHashMap<K, V>(16, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?): Boolean = size > capacity
        }

        /** The pack bundled under assets/leakpack/; [NONE] (with a warning) when the build has none or it is malformed. */
        fun fromAssets(assets: android.content.res.AssetManager, warn: (String) -> Unit = {}): LeakLibrary {
            val manifest = runCatching { assets.open(LeakPack.ASSET_MANIFEST).use { it.readBytes().toString(Charsets.UTF_8) } }.getOrNull()
                ?: return NONE.also { warn("no light-leak pack in this build: the gallery offers only None") }
            val pack = runCatching { LeakPack.parse(manifest) }.getOrElse { failure -> return NONE.also { warn("light-leak pack rejected: $failure") } }
            return LeakLibrary(
                pack,
                readFile = { path -> runCatching { assets.open(LeakPack.ASSET_ROOT + path).use { it.readBytes() } }.getOrNull() },
                decode = ::decodeRgba,
            )
        }

        /** JPEG → RGBA8 as stored (ARGB_8888's memory order is R, G, B, A), as the bundled backgrounds are read. */
        fun decodeRgba(bytes: ByteArray): Rgba8Image? {
            val options = android.graphics.BitmapFactory.Options().apply {
                inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888
                // The pack is sRGB (build_leaks.py); decode the values as they are, the renderer works on encoded sRGB.
                inPreferredColorSpace = android.graphics.ColorSpace.get(android.graphics.ColorSpace.Named.SRGB)
            }
            val bitmap = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
            val argb = if (bitmap.config == android.graphics.Bitmap.Config.ARGB_8888) bitmap else bitmap.copy(android.graphics.Bitmap.Config.ARGB_8888, false)
            val buffer = java.nio.ByteBuffer.allocate(argb.byteCount)
            argb.copyPixelsToBuffer(buffer)
            return Rgba8Image(argb.width, argb.height, buffer.array())
        }
    }
}
