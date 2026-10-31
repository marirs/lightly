package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.develop.GreyImage
import com.lightlylabs.lightly.develop.InkPack
import com.lightlylabs.lightly.develop.InkPackEntry
import com.lightlylabs.lightly.render.image.Rgba8Image

/**
 * The bundled ink pack (Effects › Ink, rendering-v2 revision 10, owner-approved 2026-10-31; app/build.gradle.kts
 * BundleInkPackTask) and its decoded images, as [LeakLibrary] holds the leak pack. The manifest is parsed once, when the
 * editor environment is created; images and thumbnails are decoded on first use and cached, so the preview, every Save
 * copy tile and the gallery share one decode.
 */
class InkLibrary(
    val pack: InkPack,
    /** Reads a pack-relative file (`img/<id>.png`, `thumb/<id>.jpg`, …); null when it cannot be read. */
    private val readFile: (String) -> ByteArray?,
    /** Decodes PNG or JPEG bytes to sRGB-encoded RGBA, unchanged; null on failure. */
    private val decode: (ByteArray) -> Rgba8Image?,
) {
    // A full mask is ~1.2 MB as grey (1600 × 745): keep the one in the edit and the one before it. Thumbnails stay.
    private val images = lruCache<String, GreyImage>(FULL_IMAGES_KEPT)
    private val thumbnails = lruCache<String, Rgba8Image>(Int.MAX_VALUE)

    /** The ink's full image as grey for the renderer, or null when this build has no such ink or it cannot be decoded. */
    fun image(inkId: String): GreyImage? = pack.entry(inkId)?.let { entry ->
        synchronized(images) { images[entry.id] }?.let { return it }
        // Decoded outside the lock, as LeakLibrary: a duplicate decode is harmless and neither thread blocks.
        val decoded = readFile(entry.image)?.let(decode)?.let(::grey) ?: return null
        synchronized(images) { images[entry.id] = decoded }
        decoded
    }

    /** The ink's gallery thumbnail as RGBA (grey in every channel), or null when it is unavailable. */
    fun thumbnail(inkId: String): Rgba8Image? = pack.entry(inkId)?.let { entry ->
        synchronized(thumbnails) { thumbnails[entry.id] }?.let { return it }
        val decoded = readFile(entry.thumbnail)?.let(decode) ?: return null
        synchronized(thumbnails) { thumbnails[entry.id] = decoded }
        decoded
    }

    val inks: List<InkPackEntry> get() = pack.inks

    companion object {
        private const val FULL_IMAGES_KEPT = 2

        /** No pack: the gallery offers only None and an ink id draws nothing. JVM tests and builds without a pack. */
        val NONE = InkLibrary(InkPack.EMPTY, { null }, { null })

        private fun <K, V> lruCache(capacity: Int) = object : LinkedHashMap<K, V>(16, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?): Boolean = size > capacity
        }

        /** The pack's files are grey: the red channel is the value (R = G = B). */
        fun grey(image: Rgba8Image): GreyImage =
            GreyImage(image.width, image.height, ByteArray(image.width * image.height) { image.pixels[it * 4] })

        /** The pack bundled under assets/inkpack/; [NONE] (with a warning) when the build has none or it is malformed. */
        fun fromAssets(assets: android.content.res.AssetManager, warn: (String) -> Unit = {}): InkLibrary {
            val manifest = runCatching { assets.open(InkPack.ASSET_MANIFEST).use { it.readBytes().toString(Charsets.UTF_8) } }.getOrNull()
                ?: return NONE.also { warn("no ink pack in this build: the Ink gallery offers only None") }
            val pack = runCatching { InkPack.parse(manifest) }.getOrElse { failure -> return NONE.also { warn("ink pack rejected: $failure") } }
            return InkLibrary(
                pack,
                readFile = { path -> runCatching { assets.open(InkPack.ASSET_ROOT + path).use { it.readBytes() } }.getOrNull() },
                // BitmapFactory decodes grey PNGs and JPEGs to ARGB_8888 with R = G = B, as stored.
                decode = LeakLibrary::decodeRgba,
            )
        }
    }
}
