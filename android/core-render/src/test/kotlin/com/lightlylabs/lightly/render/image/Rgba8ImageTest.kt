package com.lightlylabs.lightly.render.image

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.test.assertFalse

class Rgba8ImageTest {
    @Test fun `platform pixels remain lazy and materialize once`() {
        var reads = 0
        val bytes = byteArrayOf(3, 17, 98, -1)
        val handle = Any()
        val image = Rgba8Image(1, 1, object : Rgba8Backing {
            override val platformHandle = handle
            override fun readPixels(): ByteArray { reads++; return bytes }
        })
        assertSame(handle, image.backing?.platformHandle)
        assertEquals(0, reads)
        assertSame(bytes, image.pixels)
        assertSame(bytes, image.pixels)
        assertEquals(1, reads)
    }

    @Test fun `opacity propagates without reading a platform image`() {
        assertTrue(Rgba8Image(1,1,byteArrayOf(0,1,2,-1)).isOpaque)
        assertFalse(Rgba8Image(1,1,byteArrayOf(0,1,2,127)).isOpaque)
        val image=Rgba8Image(1,1,object:Rgba8Backing {
            override val platformHandle=Any()
            override val isOpaque=true
            override fun readPixels():ByteArray=error("must stay on GPU")
        })
        assertTrue(image.isOpaque)
    }

    @Test fun `invalid CPU buffers fail at construction and platform buffers at materialization`() {
        assertFailsWith<IllegalArgumentException> { Rgba8Image(2, 2, ByteArray(4)) }
        val image = Rgba8Image(2, 2, object : Rgba8Backing {
            override val platformHandle = Any()
            override fun readPixels() = ByteArray(4)
        })
        assertFailsWith<IllegalArgumentException> { image.pixels }
        assertFailsWith<IllegalArgumentException> { Rgba8Image(0, 1, ByteArray(0)) }
    }
}
