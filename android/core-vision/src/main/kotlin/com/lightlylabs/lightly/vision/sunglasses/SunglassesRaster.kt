package com.lightlylabs.lightly.vision.sunglasses

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The three render passes of `portrait.sunglasses` (rendering-v2 §7.5 "Passes") as a software rasteriser: the Android
 * counterpart of the SceneKit scene in iOS `SunglassesRenderer.renderPasses`.
 *
 * v3 differs: iOS renders with SceneKit; Android rasterises in Kotlin (no 3D engine dependency, identical pixels on
 * every device, testable on the JVM). The scene is the same: an orthographic camera looking down −z over a region of
 * the photo, the pair tilted −8° about its x axis and placed by the head's axes, a depth-only head ellipsoid and face
 * mesh drawn first, lenses depth-only in the frame passes. Lighting follows SceneKit's physically based model (one
 * directional light, ambient); its gains are measured against SceneKit references (SunglassesRasterTest).
 *
 * Scene units are image pixels: x right, y up, z towards the viewer, origin at the image centre.
 */
object SunglassesRaster {

    /** A decoded texture: RGBA8, row-major, origin top-left (the pack's uv origin). */
    class Texture(val width: Int, val height: Int, val rgba: ByteArray)

    /**
     * Linear radiance = albedo·(1 − metal)·(AMBIENT + KEY·n·l) + SPECULAR·GGX. The gains are fitted to SceneKit over the
     * reference renders (SunglassesRasterTest "fit lighting gains", 2026-10-13: mean frame colour difference 0.027).
     */
    object Lighting {
        // Variables only so SunglassesRasterTest can fit them against SceneKit; the renderer never changes them.
        @JvmField var AMBIENT = 0.4f
        @JvmField var KEY = 1.1f
        @JvmField var SPECULAR = 3.0f
        /** The key light's travel direction: SceneKit eulerAngles (−0.6, 0.4, 0) applied to −z (yaw after pitch). */
        val toLight: FloatArray = run {
            val pitch = -0.6; val yaw = 0.4
            // Rx(pitch)·(0, 0, −1), then Ry(yaw).
            val y1 = -(-1.0) * sin(pitch); val z1 = -cos(pitch)
            val x2 = z1 * sin(yaw); val z2 = z1 * cos(yaw)
            floatArrayOf((-x2).toFloat(), (-y1).toFloat(), (-z2).toFloat())   // towards the light
        }
    }

    enum class Pass { FRAME, FRONT, LENS }

    /** The pair's placement: origin (scene units), axes, and pixels per metre (Size included). */
    class Placement(val origin: DoubleArray, val ex: DoubleArray, val ey: DoubleArray, val ez: DoubleArray, val scale: Double)

    /** The rendered region in image pixels and its RGBA result: colour sRGB-encoded (not premultiplied), alpha 0…1. */
    class Result(val x0: Int, val y0: Int, val width: Int, val height: Int, val rgba: FloatArray)

    private const val SS = 2   // supersampling factor per axis (SceneKit uses 4× MSAA)
    private const val TILT = -0.14   // pantoscopic tilt, radians (rendering-v2 §7.5 placement)
    private const val FRONT_DEPTH = 0.012
    private const val ALL_DEPTH = 0.25
    private val HEAD_CENTRE = doubleArrayOf(0.0, -0.026, -0.098)
    private val HEAD_RADII = doubleArrayOf(0.076, 0.115, 0.098)

    /**
     * Renders [pass] of [mesh] over the region (x0, y0, width, height) of a W × H image. [faceMesh] holds the face
     * occluder as scene-unit triangles (x, y, z per vertex, three vertices per triangle), already pushed back.
     */
    fun render(
        pack: SunglassesPack, pair: SunglassesPack.Pair, mesh: SunglassesPack.Mesh, textures: (String) -> Texture?,
        placement: Placement, imageWidth: Int, imageHeight: Int, x0: Int, y0: Int, width: Int, height: Int,
        faceMesh: FloatArray, pass: Pass,
    ): Result {
        val sw = width * SS
        val sh = height * SS
        val depth = FloatArray(sw * sh) { Float.NEGATIVE_INFINITY }
        val k = placement.scale
        val nearestZ = -(if (pass == Pass.FRONT) FRONT_DEPTH else ALL_DEPTH) * k   // the camera's far plane in scene z
        // Sample (sx, sy) of the region ↔ scene: x = x0 + (sx + 0.5)/SS − W/2, y = H/2 − (y0 + (sy + 0.5)/SS).
        val toSampleX = { x: Double -> (x + imageWidth / 2.0 - x0) * SS - 0.5 }
        val toSampleY = { y: Double -> (imageHeight / 2.0 - y - y0) * SS - 0.5 }

        // 1. Occluders, depth only: the head ellipsoid (in the pair's frame) and the face mesh.
        val head = headTriangles(placement)
        rasterDepth(head, depth, sw, sh, toSampleX, toSampleY, nearestZ)
        rasterDepth(faceMesh, depth, sw, sh, toSampleX, toSampleY, nearestZ)

        // 2. The pair's vertices in scene units (tilt, then the head's axes, then the origin); normals rotated alike.
        val n = mesh.vertexCount
        val pos = FloatArray(n * 3)
        val nrm = FloatArray(n * 3)
        val ct = cos(TILT); val st = sin(TILT)
        val v = mesh.vertices
        for (i in 0 until n) {
            val px = v[i * 8].toDouble(); val py0 = v[i * 8 + 1].toDouble(); val pz0 = v[i * 8 + 2].toDouble()
            val py = py0 * ct - pz0 * st; val pz = py0 * st + pz0 * ct
            val nx = v[i * 8 + 3].toDouble(); val ny0 = v[i * 8 + 4].toDouble(); val nz0 = v[i * 8 + 5].toDouble()
            val ny = ny0 * ct - nz0 * st; val nz = ny0 * st + nz0 * ct
            for (c in 0..2) {
                pos[i * 3 + c] = (placement.origin[c] + k * (px * placement.ex[c] + py * placement.ey[c] + pz * placement.ez[c])).toFloat()
                nrm[i * 3 + c] = (nx * placement.ex[c] + ny * placement.ey[c] + nz * placement.ez[c]).toFloat()
            }
        }
        // 3. Visibility: per sample, the nearest opaque fragment (frame, or lens as depth/coverage).
        val triangleOf = IntArray(sw * sh) { -1 }
        val elementOf = IntArray(sw * sh) { -1 }
        val baryA = FloatArray(sw * sh); val baryB = FloatArray(sw * sh)
        val translucent = ArrayList<Int>()
        for ((e, element) in mesh.elements.withIndex()) {
            val material = pair.materials[element.materialIndex]
            // Frame passes: lenses never hide the frame. SceneKit draws the frame elements before the lens elements (the
            // pack's material order), so the far arm stays visible through a depth-only lens; iOS and the approved trial
            // renders look like that. In the lens pass both write depth and the nearer surface wins.
            if (pass != Pass.LENS && material.role == SunglassesPack.Role.LENS) continue
            if (material.role == SunglassesPack.Role.FRAME && material.translucent && pass != Pass.LENS) { translucent += e; continue }
            rasterElement(element.indices, pos, depth, sw, sh, toSampleX, toSampleY, nearestZ) { sample, tri, a, b ->
                triangleOf[sample] = tri; elementOf[sample] = e; baryA[sample] = a; baryB[sample] = b
            }
        }
        // 4. Shade every sample once (linear, premultiplied).
        val linear = FloatArray(sw * sh * 4)
        for (s in 0 until sw * sh) {
            val e = elementOf[s]
            if (e < 0) continue
            val element = mesh.elements[e]
            val material = pair.materials[element.materialIndex]
            when {
                pass == Pass.LENS -> {
                    val white = if (material.role == SunglassesPack.Role.LENS) 1f else 0f
                    linear[s * 4] = white; linear[s * 4 + 1] = white; linear[s * 4 + 2] = white; linear[s * 4 + 3] = 1f
                }
                material.role == SunglassesPack.Role.LENS -> Unit   // depth only: the compositor draws the glass
                else -> shade(material, textures, mesh, element.indices, triangleOf[s], baryA[s], baryB[s], pos, nrm, linear, s, 1f)
            }
        }
        // 5. Translucent frame parts, blended over in element order (SceneKit draws them without sorting too).
        for (e in translucent) {
            val element = mesh.elements[e]
            val material = pair.materials[element.materialIndex]
            val shaded = FloatArray(4)
            rasterElement(element.indices, pos, depth, sw, sh, toSampleX, toSampleY, nearestZ) { sample, tri, a, b ->
                java.util.Arrays.fill(shaded, 0f)
                shade(material, textures, mesh, element.indices, tri, a, b, pos, nrm, shaded, 0, 1f)
                val alpha = shaded[3]
                for (c in 0..3) linear[sample * 4 + c] = shaded[c] + linear[sample * 4 + c] * (1 - alpha)
            }
        }
        // 6. Resolve SS × SS samples (linear, premultiplied), then unpremultiply and encode sRGB.
        val out = FloatArray(width * height * 4)
        val inv = 1f / (SS * SS)
        for (y in 0 until height) for (x in 0 until width) {
            var r = 0f; var g = 0f; var b = 0f; var a = 0f
            for (dy in 0 until SS) for (dx in 0 until SS) {
                val s = ((y * SS + dy) * sw + x * SS + dx) * 4
                r += linear[s]; g += linear[s + 1]; b += linear[s + 2]; a += linear[s + 3]
            }
            a *= inv
            val o = (y * width + x) * 4
            if (a > 0f) {
                out[o] = encode(r * inv / a); out[o + 1] = encode(g * inv / a); out[o + 2] = encode(b * inv / a)
            }
            out[o + 3] = a
        }
        return Result(x0, y0, width, height, out)
    }

    // MARK: Shading

    private fun shade(
        material: SunglassesPack.Material, textures: (String) -> Texture?, mesh: SunglassesPack.Mesh, indices: IntArray,
        tri: Int, a: Float, b: Float, pos: FloatArray, nrm: FloatArray, out: FloatArray, at: Int, coverage: Float,
    ) {
        val i0 = indices[tri * 3]; val i1 = indices[tri * 3 + 1]; val i2 = indices[tri * 3 + 2]
        val c = 1 - a - b
        // Interpolated normal (double-sided: turned towards the viewer).
        var nx = nrm[i0 * 3] * c + nrm[i1 * 3] * a + nrm[i2 * 3] * b
        var ny = nrm[i0 * 3 + 1] * c + nrm[i1 * 3 + 1] * a + nrm[i2 * 3 + 1] * b
        var nz = nrm[i0 * 3 + 2] * c + nrm[i1 * 3 + 2] * a + nrm[i2 * 3 + 2] * b
        val len = sqrt(nx * nx + ny * ny + nz * nz).takeIf { it > 1e-6f } ?: 1f
        nx /= len; ny /= len; nz /= len
        if (nz < 0) { nx = -nx; ny = -ny; nz = -nz }
        // Albedo: the base texture (sRGB) at the interpolated uv, or the material colour.
        val v = mesh.vertices
        val u = v[i0 * 8 + 6] * c + v[i1 * 8 + 6] * a + v[i2 * 8 + 6] * b
        val w = v[i0 * 8 + 7] * c + v[i1 * 8 + 7] * a + v[i2 * 8 + 7] * b
        // Material colours are sRGB-encoded, as SceneKit reads a UIColor.
        var ar = decode(material.baseColor[0]); var ag = decode(material.baseColor[1]); var ab = decode(material.baseColor[2]); var alpha = 1f
        val texture = material.base?.let(textures)
        if (texture != null) {
            val t = sample(texture, u, w)
            ar = decode(t[0]); ag = decode(t[1]); ab = decode(t[2])
            if (material.translucent) alpha = t[3]
        }
        val l = Lighting.toLight
        val ndl = max(0f, nx * l[0] + ny * l[1] + nz * l[2])
        val metal = material.metalness
        val diffuse = (1 - metal) * (Lighting.AMBIENT + Lighting.KEY * ndl)
        // GGX specular for the key light, viewer along +z.
        val hx = l[0]; val hy = l[1]; val hz = l[2] + 1f
        val hl = sqrt(hx * hx + hy * hy + hz * hz)
        val ndh = max(0f, (nx * hx + ny * hy + nz * hz) / hl)
        val rough = max(material.roughness, 0.04f)
        val a2 = rough.pow(4)
        val d = ndh * ndh * (a2 - 1) + 1
        val ggx = (a2 / (PI.toFloat() * d * d))
        val ndv = max(nz, 1e-3f)
        val kk = (rough + 1).pow(2) / 8
        val vis = 1f / ((ndl * (1 - kk) + kk) * (ndv * (1 - kk) + kk) * 4)
        val vdh = max(0f, hz / hl)
        val spec = Lighting.SPECULAR * Lighting.KEY * ndl * ggx * vis
        for ((ch, albedo) in floatArrayOf(ar, ag, ab).withIndex()) {
            val f0 = 0.04f * (1 - metal) + albedo * metal
            val fresnel = f0 + (1 - f0) * (1 - vdh).pow(5)
            out[at * 4 + ch] = (albedo * diffuse + spec * fresnel) * alpha * coverage
        }
        out[at * 4 + 3] = alpha * coverage
    }

    private fun sample(t: Texture, u: Float, v: Float): FloatArray {
        val x = (u - floor(u)) * t.width - 0.5f
        val y = (v - floor(v)) * t.height - 0.5f
        val x0 = floor(x).toInt(); val y0 = floor(y).toInt()
        val fx = x - x0; val fy = y - y0
        val out = FloatArray(4)
        for (dy in 0..1) for (dx in 0..1) {
            val px = Math.floorMod(x0 + dx, t.width); val py = Math.floorMod(y0 + dy, t.height)
            val weight = (if (dx == 0) 1 - fx else fx) * (if (dy == 0) 1 - fy else fy)
            val o = (py * t.width + px) * 4
            for (ch in 0..3) out[ch] += (t.rgba[o + ch].toInt() and 0xff) / 255f * weight
        }
        return out
    }

    fun decode(e: Float): Float = if (e <= 0.04045f) e / 12.92f else ((e + 0.055f) / 1.055f).pow(2.4f)
    fun encode(l: Float): Float {
        val x = min(max(l, 0f), 1f)
        return if (x <= 0.0031308f) x * 12.92f else 1.055f * x.pow(1 / 2.4f) - 0.055f
    }

    // MARK: Rasterisation

    /** Calls [hit] for every sample a triangle wins (depth test: nearer = larger z, within the far plane), writing depth. */
    private inline fun rasterElement(
        indices: IntArray, pos: FloatArray, depth: FloatArray, sw: Int, sh: Int,
        toSampleX: (Double) -> Double, toSampleY: (Double) -> Double, nearestZ: Double,
        hit: (sample: Int, triangle: Int, a: Float, b: Float) -> Unit,
    ) {
        val tris = indices.size / 3
        for (t in 0 until tris) {
            val i0 = indices[t * 3]; val i1 = indices[t * 3 + 1]; val i2 = indices[t * 3 + 2]
            triangle(
                toSampleX(pos[i0 * 3].toDouble()), toSampleY(pos[i0 * 3 + 1].toDouble()), pos[i0 * 3 + 2].toDouble(),
                toSampleX(pos[i1 * 3].toDouble()), toSampleY(pos[i1 * 3 + 1].toDouble()), pos[i1 * 3 + 2].toDouble(),
                toSampleX(pos[i2 * 3].toDouble()), toSampleY(pos[i2 * 3 + 1].toDouble()), pos[i2 * 3 + 2].toDouble(),
                depth, sw, sh, nearestZ,
            ) { s, a, b -> hit(s, t, a, b) }
        }
    }

    /** Depth-only triangles (x, y, z scene units per vertex, three per triangle). */
    private fun rasterDepth(tris: FloatArray, depth: FloatArray, sw: Int, sh: Int,
                            toSampleX: (Double) -> Double, toSampleY: (Double) -> Double, nearestZ: Double) {
        for (t in 0 until tris.size / 9) {
            val o = t * 9
            triangle(
                toSampleX(tris[o].toDouble()), toSampleY(tris[o + 1].toDouble()), tris[o + 2].toDouble(),
                toSampleX(tris[o + 3].toDouble()), toSampleY(tris[o + 4].toDouble()), tris[o + 5].toDouble(),
                toSampleX(tris[o + 6].toDouble()), toSampleY(tris[o + 7].toDouble()), tris[o + 8].toDouble(),
                depth, sw, sh, nearestZ,
            ) { _, _, _ -> }
        }
    }

    /** Scan-converts one triangle over sample centres (top-left rule not needed: shared edges may double-hit). */
    private inline fun triangle(
        x0: Double, y0: Double, z0: Double, x1: Double, y1: Double, z1: Double, x2: Double, y2: Double, z2: Double,
        depth: FloatArray, sw: Int, sh: Int, nearestZ: Double, hit: (sample: Int, a: Float, b: Float) -> Unit,
    ) {
        val area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
        if (abs(area) < 1e-12) return
        val minX = max(0, floor(min(x0, min(x1, x2))).toInt()); val maxX = min(sw - 1, kotlin.math.ceil(max(x0, max(x1, x2))).toInt())
        val minY = max(0, floor(min(y0, min(y1, y2))).toInt()); val maxY = min(sh - 1, kotlin.math.ceil(max(y0, max(y1, y2))).toInt())
        if (minX > maxX || minY > maxY) return
        for (y in minY..maxY) {
            val py = y.toDouble()
            for (x in minX..maxX) {
                val px = x.toDouble()
                // Barycentric weights of vertices 1 and 2.
                val a = ((px - x0) * (y2 - y0) - (x2 - x0) * (py - y0)) / area
                val b = ((x1 - x0) * (py - y0) - (px - x0) * (y1 - y0)) / area
                if (a < 0 || b < 0 || a + b > 1) continue
                val z = z0 + (z1 - z0) * a + (z2 - z0) * b
                if (z < nearestZ) continue
                val s = y * sw + x
                if (z <= depth[s]) continue
                depth[s] = z.toFloat()
                hit(s, a.toFloat(), b.toFloat())
            }
        }
    }

    /** The head ellipsoid as triangles in scene units (a 48 × 24 UV sphere, SceneKit's default segment count). */
    private fun headTriangles(p: Placement): FloatArray {
        val seg = 48; val rings = 24
        fun point(i: Int, j: Int): DoubleArray {
            val theta = PI * j / rings; val phi = 2 * PI * i / seg
            val lx = HEAD_CENTRE[0] + HEAD_RADII[0] * sin(theta) * cos(phi)
            val ly0 = HEAD_CENTRE[1] + HEAD_RADII[1] * cos(theta)
            val lz0 = HEAD_CENTRE[2] + HEAD_RADII[2] * sin(theta) * sin(phi)
            // The head is in the holder's frame (not tilted with the pair).
            return DoubleArray(3) { c -> p.origin[c] + p.scale * (lx * p.ex[c] + ly0 * p.ey[c] + lz0 * p.ez[c]) }
        }
        val out = FloatArray(seg * rings * 2 * 9)
        var o = 0
        for (j in 0 until rings) for (i in 0 until seg) {
            val a = point(i, j); val b = point(i + 1, j); val c = point(i + 1, j + 1); val d = point(i, j + 1)
            for (vtx in listOf(a, b, c, a, c, d)) { out[o++] = vtx[0].toFloat(); out[o++] = vtx[1].toFloat(); out[o++] = vtx[2].toFloat() }
        }
        return out
    }
}
