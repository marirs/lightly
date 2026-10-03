package com.lightlylabs.lightly.background

import java.util.Base64

/** Depth embedded in a photo, decoded to depth (metres or relative units) and disparity (1/d, larger = nearer). */
class EmbeddedDepthMap(
    val source: Source,
    val format: String,
    val near: Double,
    val far: Double,
    val units: String,
    val depth: FloatPlane,
) {
    enum class Source { DYNAMIC_DEPTH_1_0, GDEPTH }

    val disparity: FloatPlane get() = depth.map { 1f / maxOf(it, 1e-6f) }
}

/**
 * Decodes an embedded depth image (PNG or JPEG bytes) to its first channel in [0, 1]. PNG is decoded
 * here (16 bits kept); JPEG depth images need the platform decoder, which the app injects.
 */
fun interface DepthImageDecoder {
    fun decode(bytes: ByteArray): FloatPlane

    companion object {
        val PNG_ONLY = DepthImageDecoder { bytes -> require(PngGrayDecoder.isPng(bytes)) { "JPEG depth images need the platform decoder" }; PngGrayDecoder.decode(bytes) }
    }
}

/**
 * Reader for depth embedded in Android photos (docs/v1/depth-evaluation.md §E2), a port of
 * `experiments/depth/embedded/dynamic_depth.py`:
 * - **Dynamic Depth 1.0** (`DEPTH_JPEG`, Pixel Portrait): XMP `Container:Directory` items appended
 *   after the primary JPEG's EOI, `DepthMap:Format/Near/Far/DepthURI`;
 * - **GDepth** (legacy, often in extended XMP): base64 `GDepth:Data`.
 * Ultra HDR gain maps share the container but are never taken as depth (only `DepthURI` is followed).
 * Samsung's proprietary trailer is not supported: such photos have no embedded depth here.
 */
object EmbeddedDepthReader {
    private val STANDARD_XMP = "http://ns.adobe.com/xap/1.0/\u0000".toByteArray(Charsets.ISO_8859_1)
    private val EXTENDED_XMP = "http://ns.adobe.com/xmp/extension/\u0000".toByteArray(Charsets.ISO_8859_1)

    /** Null when the photo carries no supported depth. Throws only for a malformed container that claims depth. */
    fun read(data: ByteArray, decoder: DepthImageDecoder = DepthImageDecoder.PNG_ONLY): EmbeddedDepthMap? {
        if (data.size < 4 || (data[0].toInt() and 0xff) != 0xFF || (data[1].toInt() and 0xff) != 0xD8) return null
        val xmp = readXmp(data)
        if (xmp.contains("photos/dd/1.0") && property(xmp, "DepthMap", "Format") != null) {
            val items = Regex("<Container:Item\\b(.*?)(?:/>|</Container:Item>)", RegexOption.DOT_MATCHES_ALL).findAll(xmp).map { match ->
                val block = match.groupValues[1]
                fun attribute(name: String) = (Regex("Item:$name=\"([^\"]*)\"").find(block) ?: Regex("<Item:$name>([^<]*)</Item:$name>").find(block))?.groupValues?.get(1)
                ContainerItem(attribute("Mime"), attribute("Length")?.toIntOrNull() ?: 0, attribute("Padding")?.toIntOrNull() ?: 0, attribute("DataURI"))
            }.toList()
            var offset = primaryImageLength(data) + (items.firstOrNull()?.padding ?: 0)
            val blobs = mutableMapOf<String?, ByteArray>()
            for (item in items.drop(1)) {
                require(offset + item.length <= data.size) { "Dynamic Depth item ${item.uri} runs past the end of the file" }
                blobs[item.uri] = data.copyOfRange(offset, offset + item.length)
                offset += item.length
            }
            val depthUri = property(xmp, "DepthMap", "DepthURI")
            val format = property(xmp, "DepthMap", "Format")!!
            val near = property(xmp, "DepthMap", "Near")!!.toDouble()
            val far = property(xmp, "DepthMap", "Far")!!.toDouble()
            val blob = blobs[depthUri] ?: throw IllegalArgumentException("Dynamic Depth DepthURI $depthUri has no item")
            return EmbeddedDepthMap(EmbeddedDepthMap.Source.DYNAMIC_DEPTH_1_0, format, near, far, property(xmp, "DepthMap", "Units") ?: "None",
                decodeRange(decoder.decode(blob), format, near, far))
        }
        val gdepth = property(xmp, "GDepth", "Data") ?: return null
        val format = property(xmp, "GDepth", "Format") ?: return null
        val near = property(xmp, "GDepth", "Near")?.toDouble() ?: return null
        val far = property(xmp, "GDepth", "Far")?.toDouble() ?: return null
        val image = decoder.decode(Base64.getMimeDecoder().decode(gdepth))
        return EmbeddedDepthMap(EmbeddedDepthMap.Source.GDEPTH, format, near, far, property(xmp, "GDepth", "Units") ?: "None", decodeRange(image, format, near, far))
    }

    private class ContainerItem(val mime: String?, val length: Int, val padding: Int, val uri: String?)

    /** RangeLinear: d = near + v(far − near); RangeInverse: d = far·near / (far − v(far − near)). */
    fun decodeRange(normalised: FloatPlane, format: String, near: Double, far: Double): FloatPlane = when (format) {
        "RangeInverse" -> normalised.map { v -> (far * near / (far - v * (far - near))).toFloat() }
        "RangeLinear" -> normalised.map { v -> (near + v * (far - near)).toFloat() }
        else -> throw IllegalArgumentException("unknown depth format $format")
    }

    private fun property(xmp: String, prefix: String, name: String): String? =
        (Regex("$prefix:$name=\"([^\"]*)\"").find(xmp) ?: Regex("<$prefix:$name>([^<]*)</$prefix:$name>", RegexOption.DOT_MATCHES_ALL).find(xmp))
            ?.groupValues?.get(1)?.trim()

    /** Standard XMP packet plus extended XMP chunks reassembled (GUID-addressed, offset-ordered). */
    fun readXmp(data: ByteArray): String {
        var standard = ""
        val chunks = linkedMapOf<String, java.util.TreeMap<Int, ByteArray>>()
        for (segment in segments(data)) {
            if (segment.marker != 0xE1) continue
            val payload = segment.payload
            if (payload.startsWith(STANDARD_XMP)) {
                standard = String(payload, STANDARD_XMP.size, payload.size - STANDARD_XMP.size, Charsets.UTF_8)
            } else if (payload.startsWith(EXTENDED_XMP)) {
                val body = payload.copyOfRange(EXTENDED_XMP.size, payload.size)
                val guid = String(body, 0, 32, Charsets.US_ASCII)
                val offset = java.nio.ByteBuffer.wrap(body, 36, 4).int
                chunks.getOrPut(guid) { java.util.TreeMap() }[offset] = body.copyOfRange(40, body.size)
            }
        }
        val extended = chunks.values.joinToString("") { parts -> String(parts.values.fold(ByteArray(0)) { acc, part -> acc + part }, Charsets.UTF_8) }
        return standard + extended
    }

    private class Segment(val marker: Int, val payload: ByteArray)

    /** Header segments up to the first SOS. */
    private fun segments(data: ByteArray): List<Segment> {
        val out = mutableListOf<Segment>()
        var position = 2
        while (position + 4 <= data.size) {
            require((data[position].toInt() and 0xff) == 0xFF) { "bad JPEG marker at $position" }
            val marker = data[position + 1].toInt() and 0xff
            if (marker == 0xD9) break
            val length = ((data[position + 2].toInt() and 0xff) shl 8) or (data[position + 3].toInt() and 0xff)
            out += Segment(marker, data.copyOfRange(position + 4, minOf(data.size, position + 2 + length)))
            if (marker == 0xDA) break
            position += 2 + length
        }
        return out
    }

    /** Byte length of the primary JPEG through its EOI, walking every scan (progressive-safe). */
    fun primaryImageLength(data: ByteArray): Int {
        var position = 2
        while (true) {
            val marker = data[position + 1].toInt() and 0xff
            if (marker == 0xD9) return position + 2
            if (marker in 0xD0..0xD7 || marker == 0x01) { position += 2; continue }
            val length = ((data[position + 2].toInt() and 0xff) shl 8) or (data[position + 3].toInt() and 0xff)
            position += 2 + length
            if (marker == 0xDA) {
                while (true) {
                    while ((data[position].toInt() and 0xff) != 0xFF) position++
                    val following = data[position + 1].toInt() and 0xff
                    if (following == 0x00 || following in 0xD0..0xD7) { position += 2; continue }
                    break
                }
            }
        }
    }

    private fun ByteArray.startsWith(prefix: ByteArray) = size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }
}
