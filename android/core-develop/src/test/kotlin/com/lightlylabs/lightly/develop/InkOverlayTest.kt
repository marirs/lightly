package com.lightlylabs.lightly.develop

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

/** Effects › Ink (rendering-v2 revision 10 §Ink): the same geometry checks as iOS InkTests. */
class InkOverlayTest {
    private fun full(width: Int, height: Int, value: Int = 255) = GreyImage(width, height, ByteArray(width * height) { value.toByte() })
    private fun stroke(size: Double = 100.0, x: Double = 50.0, y: Double = 50.0, rotation: Double = 0.0, image: GreyImage = full(200, 100)) =
        InkParams(InkKind.STROKE, image, x, y, size, rotation, paper = "#FF0000")

    private fun at(overlay: InkOverlay, x: Int, y: Int, photo: FloatArray = floatArrayOf(0.2f, 0.4f, 0.6f)): FloatArray =
        photo.copyOf().also { overlay.apply(it, x, y) }

    private val paper = floatArrayOf(1f, 0f, 0f)
    private val photo = floatArrayOf(0.2f, 0.4f, 0.6f)

    @Test
    fun `a stroke shows the photo inside and paper outside, with the 6 percent margin`() {
        val overlay = InkOverlay.of(stroke(), 100, 100)!!
        assertContentEquals(photo, at(overlay, 50, 50))
        assertContentEquals(paper, at(overlay, 50, 10))
        assertContentEquals(paper, at(overlay, 2, 50))
        assertContentEquals(photo, at(overlay, 10, 50))
    }

    @Test
    fun `size scales the stroke, rotation turns it, and a portrait frame turns it with the photo`() {
        assertContentEquals(paper, at(InkOverlay.of(stroke(size = 50.0), 100, 100)!!, 10, 50))
        val turned = InkOverlay.of(stroke(rotation = 90.0), 100, 100)!!
        assertContentEquals(photo, at(turned, 50, 10))
        assertContentEquals(paper, at(turned, 10, 50))
        val portrait = InkOverlay.of(stroke(), 100, 200)!!
        assertContentEquals(photo, at(portrait, 50, 20))
        assertContentEquals(paper, at(portrait, 5, 100))
    }

    @Test
    fun `moving the stroke moves where the photo shows`() {
        val moved = InkOverlay.of(stroke(size = 50.0, x = 25.0, y = 25.0), 100, 100)!!
        assertContentEquals(photo, at(moved, 25, 25))
        assertContentEquals(paper, at(moved, 75, 75))
    }

    @Test
    fun `an overlay multiplies by intensity and draws nothing at zero`() {
        val overlay = InkOverlay.of(InkParams(InkKind.OVERLAY, full(10, 10, 0), intensity = 50.0), 40, 40)!!
        val out = at(overlay, 20, 20, floatArrayOf(0.8f, 0.4f, 0.2f))
        assertEquals(0.4f, out[0], 1e-6f); assertEquals(0.2f, out[1], 1e-6f); assertEquals(0.1f, out[2], 1e-6f)
        assertNull(InkOverlay.of(InkParams(InkKind.OVERLAY, full(10, 10, 0), intensity = 0.0), 40, 40))
    }

    @Test
    fun `the manifest must name only the ink's own files`() {
        val good = """{"format":"lightly-ink-pack","formatVersion":1,"inks":[{"id":"ink-000000000001","name":"A","kind":"stroke","image":"img/ink-000000000001.png","thumbnail":"thumb/ink-000000000001.png","imageSha256":"${"0".repeat(64)}","width":2,"height":1}]}"""
        assertEquals(InkKind.STROKE, InkPack.parse(good).entry("ink-000000000001")?.kind)
        assertFailsWith<IllegalArgumentException> { InkPack.parse(good.replace("img/ink-000000000001.png", "../x.png")) }
        assertFailsWith<IllegalArgumentException> { InkPack.parse(good.replace("\"stroke\"", "\"brush\"")) }
        assertFailsWith<IllegalArgumentException> { InkPack.parse(good.replace("lightly-ink-pack", "lightly-leak-pack")) }
    }
}
