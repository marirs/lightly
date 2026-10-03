package com.lightlylabs.lightly.background

import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Base64
import java.util.zip.CRC32
import java.util.zip.Deflater
import kotlin.math.abs
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Embedded depth (Dynamic Depth 1.0, GDepth) on containers written like
 * experiments/depth/embedded/dynamic_depth.py `write_fixture`, plus the evaluation's own fixtures when
 * they exist in this checkout; and the plane operations the depth pipeline relies on.
 */
class DepthReadersTest {
    private val w = 40
    private val h = 30
    private val near = 0.5
    private val far = 20.0
    private val disparity = FloatPlane(w, h, FloatArray(w * h) { p -> ((p % w) / (w - 1f)) * 0.8f + (p / w) / (h - 1f) * 0.2f })
    private val depth = disparity.map { (1.0 / (it * (1 / near - 1 / far) + 1 / far)).toFloat() }

    /** A structurally valid JPEG (SOI, optional APP1s, a scan with a stuffed 0xFF, EOI). */
    private fun jpeg(app1: List<ByteArray>): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(byteArrayOf(-1, -40))
        app1.forEach { payload -> out.write(byteArrayOf(-1, -31)); out.write(byteArrayOf(((payload.size + 2) shr 8).toByte(), (payload.size + 2).toByte())); out.write(payload) }
        out.write(byteArrayOf(-1, -38, 0, 4, 1, 2)) // SOS with a 2-byte header body
        out.write(byteArrayOf(10, 20, -1, 0, 30, -1, -48, 40)) // entropy data with 0xFF00 and RST0
        out.write(byteArrayOf(-1, -39))
        return out.toByteArray()
    }

    private fun png16(values: FloatPlane): ByteArray {
        val raw = ByteArrayOutputStream()
        for (y in 0 until values.height) {
            raw.write(0)
            for (x in 0 until values.width) { val v = (values[x, y] * 65535).toInt().coerceIn(0, 65535); raw.write(v shr 8); raw.write(v and 0xff) }
        }
        val deflater = Deflater()
        deflater.setInput(raw.toByteArray()); deflater.finish()
        val compressed = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (!deflater.finished()) compressed.write(buffer, 0, deflater.deflate(buffer))
        val out = ByteArrayOutputStream()
        out.write(byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10))
        fun chunk(type: String, data: ByteArray) {
            out.write(ByteBuffer.allocate(4).putInt(data.size).array())
            val typeBytes = type.toByteArray(Charsets.US_ASCII)
            out.write(typeBytes); out.write(data)
            val crc = CRC32().apply { update(typeBytes); update(data) }
            out.write(ByteBuffer.allocate(4).putInt(crc.value.toInt()).array())
        }
        chunk("IHDR", ByteBuffer.allocate(13).putInt(values.width).putInt(values.height).put(16).put(0).put(0).put(0).put(0).array())
        chunk("IDAT", compressed.toByteArray())
        chunk("IEND", ByteArray(0))
        return out.toByteArray()
    }

    private val dmin = depth.values.min().toDouble()
    private val dmax = depth.values.max().toDouble()
    private val encoded = png16(depth.map { d -> ((dmax * (d - dmin)) / (d * (dmax - dmin))).toFloat() })
    private val standardHeader = "http://ns.adobe.com/xap/1.0/\u0000".toByteArray(Charsets.ISO_8859_1)

    @Test
    fun `Dynamic Depth container decodes back to the written depth`() {
        val xmp = """<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF><rdf:Description xmlns:Device="http://ns.google.com/photos/dd/1.0/device/">
<Device:Container><Container:Directory><rdf:Seq>
 <rdf:li><Container:Item Item:Mime="image/jpeg" Item:Length="0" Item:Padding="0" Item:DataURI="primary_image"/></rdf:li>
 <rdf:li><Container:Item Item:Mime="image/jpeg" Item:Length="7" Item:DataURI="android/gainmap"/></rdf:li>
 <rdf:li><Container:Item Item:Mime="image/png" Item:Length="${encoded.size}" Item:DataURI="android/depthmap"/></rdf:li>
</rdf:Seq></Container:Directory></Device:Container>
<Camera:DepthMap DepthMap:Format="RangeInverse" DepthMap:Near="$dmin" DepthMap:Far="$dmax" DepthMap:Units="Meters" DepthMap:DepthURI="android/depthmap"/>
</rdf:Description></rdf:RDF></x:xmpmeta>"""
        val file = jpeg(listOf(standardHeader + xmp.toByteArray())) + ByteArray(7) { 9 } + encoded
        val map = assertNotNull(EmbeddedDepthReader.read(file))
        assertEquals(EmbeddedDepthMap.Source.DYNAMIC_DEPTH_1_0, map.source)
        val worst = depth.values.indices.maxOf { abs(map.depth.values[it] - depth.values[it]) / depth.values[it] }
        assertTrue(worst < 1e-3, "relative depth error $worst (16-bit quantisation)")
    }

    @Test
    fun `GDepth in extended XMP chunks decodes back to the written depth`() {
        val guid = "0123456789ABCDEF0123456789ABCDEF"
        val extended = """<x:xmpmeta><rdf:Description GDepth:Data="${Base64.getEncoder().encodeToString(encoded)}"/></x:xmpmeta>""".toByteArray()
        val standard = """<x:xmpmeta><rdf:Description xmlns:GDepth="http://ns.google.com/photos/1.0/depthmap/" xmpNote:HasExtendedXMP="$guid" GDepth:Format="RangeInverse" GDepth:Near="$dmin" GDepth:Far="$dmax" GDepth:Mime="image/png"/></x:xmpmeta>"""
        val extHeader = "http://ns.adobe.com/xmp/extension/\u0000".toByteArray(Charsets.ISO_8859_1)
        val chunks = extended.toList().chunked(3000).mapIndexed { i, part ->
            extHeader + guid.toByteArray() + ByteBuffer.allocate(8).putInt(extended.size).putInt(i * 3000).array() + part.toByteArray()
        }.reversed() // out of order on purpose: chunks are joined by offset
        val map = assertNotNull(EmbeddedDepthReader.read(jpeg(listOf(standardHeader + standard.toByteArray()) + chunks)))
        assertEquals(EmbeddedDepthMap.Source.GDEPTH, map.source)
        val worst = depth.values.indices.maxOf { abs(map.depth.values[it] - depth.values[it]) / depth.values[it] }
        assertTrue(worst < 1e-3, "relative depth error $worst")
    }

    @Test
    fun `a photo without depth has none`() {
        assertNull(EmbeddedDepthReader.read(jpeg(listOf(standardHeader + "<x:xmpmeta/>".toByteArray()))))
        assertNull(EmbeddedDepthReader.read(byteArrayOf(1, 2, 3)))
    }

    /** The evaluation's fixtures are git-ignored; when present they are checked against the Python reader's output. */
    @Test
    fun `evaluation fixtures match the Python reference reader when present`() {
        val directory = File(checkNotNull(System.getProperty("lightly.depthFixturesDir")))
        val cases = listOf("night_01_dd.jpg", "night_01_dd--gdepth.jpg").filter { File(directory, it).isFile && File(directory, "$it.disparity.npy").isFile }
        if (cases.isEmpty()) {
            println("experiments/depth/embedded/fixtures not present in this checkout: synthetic containers only")
            return
        }
        for (name in cases) {
            val map = assertNotNull(EmbeddedDepthReader.read(File(directory, name).readBytes()), name)
            val expected = readNpyFloat32(File(directory, "$name.disparity.npy"))
            val actual = map.disparity.values
            assertEquals(expected.size, actual.size, name)
            val worst = expected.indices.maxOf { abs(expected[it] - actual[it]) / maxOf(abs(expected[it]), 1e-6f) }
            assertTrue(worst < 1e-4, "$name disparity differs by $worst relative")
        }
    }

    private fun readNpyFloat32(file: File): FloatArray {
        val bytes = file.readBytes()
        val headerLength = (bytes[8].toInt() and 0xff) or ((bytes[9].toInt() and 0xff) shl 8)
        val header = String(bytes, 10, headerLength, Charsets.ISO_8859_1)
        require(header.contains("'<f4'")) { "expected float32 npy: $header" }
        val buffer = ByteBuffer.wrap(bytes, 10 + headerLength, bytes.size - 10 - headerLength).order(ByteOrder.LITTLE_ENDIAN)
        return FloatArray(buffer.remaining() / 4) { buffer.float }
    }

    @Test
    fun `distance transform matches brute force and disc morphology is round`() {
        val size = 21
        val seeds = BooleanArray(size * size).also { it[10 * size + 10] = true; it[3 * size + 17] = true }
        val d = PlaneOps.squaredDistanceTo(seeds, size, size)
        for (y in 0 until size) for (x in 0 until size) {
            val brute = minOf((x - 10) * (x - 10) + (y - 10) * (y - 10), (x - 17) * (x - 17) + (y - 3) * (y - 3)).toDouble()
            assertEquals(brute, d[y * size + x], 1e-9)
        }
        val point = FloatPlane(size, size, FloatArray(size * size) { if (it == 10 * size + 10) 1f else 0f })
        val disc = PlaneOps.dilateDisc(point, 0.5f, 5)
        assertEquals(81, disc.count { it }, "a radius-5 disc has 81 pixels")
        val eroded = PlaneOps.erodeDisc(FloatPlane(size, size, FloatArray(size * size) { if (disc[it]) 1f else 0f }), 0.5f, 5)
        assertEquals(1, eroded.count { it })
    }

    @Test
    fun `percentile normalisation and guided upsampling stay in range`() {
        val raw = FloatPlane(10, 10, FloatArray(100) { it.toFloat() })
        val n = DepthMaps.percentileNormalise(raw)
        assertEquals(0f, n.values.first()); assertEquals(1f, n.values.last())
        val guide = FloatPlane(50, 50, FloatArray(2500) { 0.5f })
        val up = DepthMaps.upsample(n, guide)
        assertTrue(up.values.all { it in 0f..1f })
        assertEquals(50, up.width)
    }

    @Test
    fun `model input is 518 by 392 NCHW with ImageNet normalisation`() {
        val rgba = ByteArray(800 * 600 * 4) { if (it % 4 == 3) -1 else 128.toByte() }
        val input = DepthModelInput.fromRgba8(rgba, 800, 600)
        assertEquals(3 * 518 * 392, input.tensor.size)
        assertEquals((128 / 255f - 0.485f) / 0.229f, input.tensor[0], 1e-4f)
        assertEquals((128 / 255f - 0.406f) / 0.225f, input.tensor[2 * 518 * 392 + 100], 1e-4f)
        assertTrue(sqrt(0.0) == 0.0)
    }
}
