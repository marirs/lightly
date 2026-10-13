package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.vision.sunglasses.SunglassesPack
import com.lightlylabs.lightly.vision.sunglasses.SunglassesRaster

/**
 * The bundled sunglasses pack (assets/sunglassespack/, BundleSunglassesPackTask; format "lightly-sunglasses-pack" 1) and its
 * decoded textures for Portrait › Sunglasses (rendering-v2 §7.5). Every file is checked against the manifest's SHA-256 by
 * [SunglassesPack] before use. [pack] is null when the build has none or it is malformed: Sunglasses then offers only None.
 */
class SunglassesLibrary(val pack: SunglassesPack?, private val decode: (ByteArray) -> SunglassesRaster.Texture?) {

    private val textures = object : LinkedHashMap<String, SunglassesRaster.Texture?>(16, 0.75f, true) {
        // A pair holds at most six textures of 1024 px (4 MB each decoded): two pairs' worth stays in memory.
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, SunglassesRaster.Texture?>?): Boolean = size > 12
    }

    /** A pack texture by its manifest path, verified and decoded once (null when missing or undecodable). */
    @Synchronized
    fun texture(path: String): SunglassesRaster.Texture? = textures.getOrPut(path) {
        val pack = pack ?: return@getOrPut null
        val material = pack.pairs.asSequence().flatMap { it.materials.asSequence() }.firstOrNull { it.base == path || it.normal == path }
            ?: return@getOrPut null
        val sha = if (material.base == path) material.baseSha256 else material.normalSha256
        runCatching { pack.verified(path, sha ?: "")?.let(decode) }.getOrNull()
    }

    companion object {
        const val ASSET_ROOT = "sunglassespack/"

        /** No pack: JVM tests and builds without one. */
        val NONE = SunglassesLibrary(null) { null }

        fun fromAssets(assets: android.content.res.AssetManager, warn: (String) -> Unit = {}): SunglassesLibrary {
            val manifest = runCatching { assets.open(ASSET_ROOT + "sunglasses.json").use { it.readBytes().toString(Charsets.UTF_8) } }.getOrNull()
                ?: return NONE.also { warn("no sunglasses pack in this build: Sunglasses offers only None") }
            val pack = runCatching {
                SunglassesPack.load(manifest) { path -> runCatching { assets.open(ASSET_ROOT + path).use { it.readBytes() } }.getOrNull() }
            }.getOrElse { failure -> return NONE.also { warn("sunglasses pack rejected: $failure") } }
            return SunglassesLibrary(pack, ::decodeTexture)
        }

        /** PNG or JPEG → RGBA8 as stored (straight alpha), sRGB values unchanged: the rasteriser decodes sRGB itself. */
        fun decodeTexture(bytes: ByteArray): SunglassesRaster.Texture? {
            val options = android.graphics.BitmapFactory.Options().apply {
                inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888
                inPremultiplied = false
                inPreferredColorSpace = android.graphics.ColorSpace.get(android.graphics.ColorSpace.Named.SRGB)
            }
            val bitmap = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
            val argb = if (bitmap.config == android.graphics.Bitmap.Config.ARGB_8888) bitmap else bitmap.copy(android.graphics.Bitmap.Config.ARGB_8888, false)
            val buffer = java.nio.ByteBuffer.allocate(argb.byteCount)
            argb.copyPixelsToBuffer(buffer)
            return SunglassesRaster.Texture(argb.width, argb.height, buffer.array())
        }
    }
}
