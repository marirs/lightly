package com.lightlylabs.lightly.render.image

/** Optional platform storage. Reading pixels materializes an exact RGBA copy only when needed. */
interface Rgba8Backing {
    val platformHandle: Any
    val isOpaque: Boolean? get() = null
    fun readPixels(): ByteArray
}

/** Immutable RGBA image, backed by tightly packed CPU bytes or a platform image. */
class Rgba8Image private constructor(val width: Int, val height: Int,
    initialPixels: ByteArray?, val backing: Rgba8Backing?) {
    constructor(width: Int, height: Int, pixels: ByteArray) : this(width, height, pixels, null)
    constructor(width: Int, height: Int, backing: Rgba8Backing) : this(width, height, null, backing)

    val pixels: ByteArray by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        (initialPixels ?: requireNotNull(backing).readPixels()).also { validate(it) }
    }

    init {
        require(width > 0 && height > 0) { "Image size must be positive, was ${width}x$height" }
        initialPixels?.let { validate(it) }
    }

    private fun validate(pixels: ByteArray) {
        require(pixels.size.toLong() == width.toLong() * height * CHANNELS) {
            "Expected ${width.toLong() * height * CHANNELS} bytes for ${width}x$height RGBA, got ${pixels.size}"
        }
    }

    // Computed once for CPU input; platform stages that preserve alpha propagate it.
    val isOpaque: Boolean by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        backing?.isOpaque ?: run {
            val bytes=pixels
            (3 until bytes.size step CHANNELS).all { bytes[it] == (-1).toByte() }
        }
    }

    val pixelCount: Int get() = width * height

    companion object {
        const val CHANNELS = 4
    }
}
