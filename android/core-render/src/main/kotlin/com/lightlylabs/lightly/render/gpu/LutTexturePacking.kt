package com.lightlylabs.lightly.render.gpu

import com.lightlylabs.lightly.render.lut.Lut3D
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * Layout of a LUT as a GL 3D texture: internal format RGBA32F, format RGBA, type FLOAT,
 * width = height = depth = N, texel (x, y, z) = LUT entry (r = x, g = y, b = z).
 *
 * The contract layout (red fastest, `index = r + N·g + N²·b`) is exactly GL's 3D upload order
 * (x fastest, then y, then z), so packing is a straight copy into a direct, native-order buffer.
 * RGBA32F (not RGBA16F) because the entries leave [0,1] and the manual trilinear in
 * [LutShaderSource] reads them with texelFetch; RGBA32F is not filterable in core ES 3.0, which is
 * fine because hardware filtering is not used.
 */
object LutTexturePacking {
    const val BYTES_PER_TEXEL = 16

    /** Texel offset (in floats) of (x, y, z) in the packed buffer. */
    fun texelFloatOffset(dimension: Int, x: Int, y: Int, z: Int): Int = ((z * dimension + y) * dimension + x) * 4

    fun byteSize(dimension: Int): Int = dimension * dimension * dimension * BYTES_PER_TEXEL

    /** Returns a direct buffer positioned at 0, ready for glTexImage3D. */
    fun pack(lut: Lut3D): FloatBuffer {
        val bytes = ByteBuffer.allocateDirect(byteSize(lut.dimension)).order(ByteOrder.nativeOrder())
        val floats = bytes.asFloatBuffer()
        floats.put(lut.rgba)
        floats.position(0)
        return floats
    }

    /** Fails before any GL call if the device cannot hold the LUT as a 3D texture. */
    fun requireFits(lut: Lut3D, maxTexture3dSize: Int) {
        require(lut.dimension <= maxTexture3dSize) {
            "LUT dimension ${lut.dimension} exceeds GL_MAX_3D_TEXTURE_SIZE $maxTexture3dSize"
        }
    }
}
