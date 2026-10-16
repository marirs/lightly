package com.lightlylabs.lightly.vision.sunglasses

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

/**
 * The sunglasses pack (format "lightly-sunglasses-pack" 1, shared/sunglasses/build_sunglasses.py): the ten owner-approved
 * pairs of Portrait › Sunglasses (rendering-v2 §7.5). A port of iOS `SunglassesPack.swift`.
 *
 * Pair geometry is in metres: x across (the wearer's left at +x), y up, z forward, origin at the centre of the lenses.
 * [files] reads a pack file by its manifest path (assets on Android, a folder in tests); every file is checked against
 * the manifest's SHA-256 before use.
 */
class SunglassesPack private constructor(val pairs: List<Pair>, private val files: (String) -> ByteArray?) {

    enum class Role { LENS, FRAME }

    class Material(
        val role: Role, val baseColor: FloatArray, val roughness: Float, val metalness: Float, val translucent: Boolean,
        val base: String?, val baseSha256: String?, val normal: String?, val normalSha256: String?,
    )

    class Pair(
        val id: String, val name: String, val order: Int, val mesh: String, val meshSha256: String,
        val thumbnail: String, val thumbnailSha256: String, val materials: List<Material>,
    )

    /** An LSG 1 mesh: interleaved vertices (position xyz, normal xyz, uv; 8 floats each) and one index list per element. */
    class Mesh(val vertices: FloatArray, val elements: List<Element>) {
        class Element(val materialIndex: Int, val indices: IntArray)
        val vertexCount get() = vertices.size / 8
        /** Lowest bridge point above the lens centre and half the lens height, metres (iOS SunglassesPack.measureFit);
         *  filled by [SunglassesPack.mesh] from the materials' roles. */
        var bridgeBottomMetres = 0.0
        var lensHalfHeightMetres = 0.0
        /** The front's width in metres: x extent of the vertices within FRONT_PLANE_METRES of the lens plane. */
        val frontWidthMetres: Double by lazy {
            var lo = Double.MAX_VALUE; var hi = -Double.MAX_VALUE
            for (i in 0 until vertexCount) {
                if (kotlin.math.abs(vertices[i * 8 + 2]) >= SunglassesConstants.FRONT_PLANE_METRES) continue
                lo = minOf(lo, vertices[i * 8].toDouble()); hi = maxOf(hi, vertices[i * 8].toDouble())
            }
            if (hi > lo) hi - lo else 0.0
        }
    }

    class FormatException(message: String) : Exception(message)
    class DigestMismatchException(path: String) : Exception("$path does not match the manifest's SHA-256")

    fun pair(id: String): Pair? = pairs.firstOrNull { it.id == id }

    /** A pack file after its SHA-256 check; null when it is missing. */
    fun verified(path: String, sha256: String): ByteArray? {
        val bytes = files(path) ?: return null
        if (sha256Hex(bytes) != sha256) throw DigestMismatchException(path)
        return bytes
    }

    private val meshes = HashMap<String, Mesh>()

    /** The pair's mesh, verified and decoded once (pack files never change while the app runs). */
    @Synchronized
    fun mesh(pair: Pair): Mesh = meshes.getOrPut(pair.id) {
        val bytes = verified(pair.mesh, pair.meshSha256) ?: throw FormatException("${pair.mesh} is missing")
        decodeLsg(bytes, pair.materials.size).also { m ->
            var bridge = Double.MAX_VALUE; var top = -Double.MAX_VALUE; var bottom = Double.MAX_VALUE
            for (e in m.elements) {
                val lens = pair.materials.getOrNull(e.materialIndex)?.role == Role.LENS
                for (i in e.indices) {
                    val x = m.vertices[i * 8].toDouble(); val y = m.vertices[i * 8 + 1].toDouble(); val z = m.vertices[i * 8 + 2].toDouble()
                    if (kotlin.math.abs(z) >= SunglassesConstants.FRONT_PLANE_METRES + 0.01) continue
                    if (lens) { top = maxOf(top, y); bottom = minOf(bottom, y) }
                    else if (kotlin.math.abs(x) < 0.004 && kotlin.math.abs(z) < SunglassesConstants.FRONT_PLANE_METRES) bridge = minOf(bridge, y)
                }
            }
            m.bridgeBottomMetres = if (bridge < Double.MAX_VALUE) bridge else 0.0
            m.lensHalfHeightMetres = if (top > bottom) (top - bottom) / 2 else 0.0
        }
    }

    companion object {
        const val FORMAT = "lightly-sunglasses-pack"
        const val FORMAT_VERSION = 1
        private val ID = Regex("sun-[0-9a-f]{12}")

        fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

        /** Reads `sunglasses.json` and checks that every pair names only its own files. */
        fun load(manifest: String, files: (String) -> ByteArray?): SunglassesPack {
            val root = Json.parseToJsonElement(manifest).jsonObject
            val format = root["format"]?.jsonPrimitive?.content
            val version = root["formatVersion"]?.jsonPrimitive?.int
            if (format != FORMAT || version != FORMAT_VERSION) throw FormatException("$format $version; this app reads $FORMAT $FORMAT_VERSION")
            val pairs = root.getValue("pairs").jsonArray.map { element ->
                val p = element.jsonObject
                fun s(key: String, o: JsonObject = p) = o[key]?.jsonPrimitive?.content
                val id = s("id") ?: throw FormatException("a pair without an id")
                if (!ID.matches(id) || s("mesh") != "mesh/$id.lsg" || s("thumbnail") != "thumb/$id.png") {
                    throw FormatException("pair $id names ${s("mesh")}, ${s("thumbnail")}")
                }
                val materials = p.getValue("materials").jsonArray.map { m ->
                    val o = m.jsonObject
                    for (path in listOfNotNull(s("base", o), s("normal", o))) {
                        if (!path.startsWith("tex/$id-") || ".." in path) throw FormatException("pair $id names texture $path")
                    }
                    Material(
                        role = if (s("role", o) == "lens") Role.LENS else Role.FRAME,
                        baseColor = o.getValue("baseColor").jsonArray.map { it.jsonPrimitive.double.toFloat() }.toFloatArray(),
                        roughness = o.getValue("roughness").jsonPrimitive.double.toFloat(),
                        metalness = o.getValue("metalness").jsonPrimitive.double.toFloat(),
                        translucent = o.getValue("translucent").jsonPrimitive.boolean,
                        base = s("base", o), baseSha256 = s("baseSha256", o), normal = s("normal", o), normalSha256 = s("normalSha256", o),
                    )
                }
                Pair(id, s("name")!!, p.getValue("order").jsonPrimitive.int, s("mesh")!!, s("meshSha256")!!,
                     s("thumbnail")!!, s("thumbnailSha256")!!, materials)
            }.sortedBy { it.order }
            return SunglassesPack(pairs, files)
        }

        /**
         * LSG 1 (shared/sunglasses/build_sunglasses.py): "LSG1", u32 version, u32 vertexCount, u32 elementCount, then
         * vertexCount × {f32 position[3], normal[3], uv[2]} (uv origin top-left), then per element {u32 materialIndex,
         * u32 indexCount, u32 indices[indexCount]} (triangles). Little-endian. Every index must address a vertex.
         */
        fun decodeLsg(bytes: ByteArray, materialCount: Int): Mesh {
            val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            fun u32(): Int {
                if (b.remaining() < 4) throw FormatException("truncated LSG")
                val v = b.int.toLong() and 0xffffffffL
                if (v > Int.MAX_VALUE) throw FormatException("LSG count out of range")
                return v.toInt()
            }
            if (bytes.size < 16 || String(bytes, 0, 4, Charsets.US_ASCII) != "LSG1") throw FormatException("not an LSG mesh")
            b.position(4)
            if (u32() != 1) throw FormatException("LSG version")
            val vertexCount = u32()
            val elementCount = u32()
            if (vertexCount <= 0 || elementCount <= 0 || b.remaining() < vertexCount.toLong() * 32) throw FormatException("LSG vertices")
            val vertices = FloatArray(vertexCount * 8)
            b.asFloatBuffer().get(vertices)
            b.position(16 + vertexCount * 32)
            val elements = List(elementCount) {
                val material = u32()
                val count = u32()
                if (material >= materialCount || count % 3 != 0 || b.remaining() < count.toLong() * 4) throw FormatException("LSG element")
                val indices = IntArray(count) { u32() }
                if (indices.any { it >= vertexCount }) throw FormatException("LSG index out of range")
                Mesh.Element(material, indices)
            }
            return Mesh(vertices, elements)
        }
    }
}
