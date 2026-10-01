package com.lightlylabs.lutbench

import android.graphics.Bitmap
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES30
import android.opengl.GLUtils
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.min

/**
 * Offscreen OpenGL ES 3.0 LUT application: EGL pbuffer (1x1, only to make a context current)
 * + FBO with an RGBA8 colour texture, full-screen triangle, glReadPixels readback.
 *
 * The source is uploaded as plain RGBA8 (not GL_SRGB8_ALPHA8): the LUT is defined on
 * sRGB-encoded values, so the GPU must not linearise on fetch.
 *
 * Variants:
 *  - "rgba16f_linear": 3D LUT texture RGBA16F, GL_LINEAR hardware trilinear, sampled at the
 *    texel-centre mapping (c*(N-1)+0.5)/N so c=0 and c=1 land exactly on the first/last texel.
 *  - "rgba32f_manual": 3D LUT texture RGBA32F, GL_NEAREST, 8 texelFetch + manual trilinear
 *    (RGBA32F is not filterable in core ES 3.0; OES_texture_float_linear presence is recorded).
 */
class GlLut(private val log: (String) -> Unit) {
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var surface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var emptyVertexArray = 0
    private val programs = HashMap<String, Int>()
    private val lutTextures = HashMap<String, Int>()

    val limits = JSONObject()
    var renderer: String = ""
        private set
    var version: String = ""
        private set

    /** Largest tile edge usable for both the input texture and the FBO. */
    private var maxTileEdge = 0

    fun init() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val versionOut = IntArray(2)
        check(EGL14.eglInitialize(display, versionOut, 0, versionOut, 1)) { "eglInitialize failed: 0x${Integer.toHexString(EGL14.eglGetError())}" }
        val configAttributes = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val configCount = IntArray(1)
        check(EGL14.eglChooseConfig(display, configAttributes, 0, configs, 0, 1, configCount, 0) && configCount[0] > 0) {
            "eglChooseConfig found no ES3 pbuffer config: 0x${Integer.toHexString(EGL14.eglGetError())}"
        }
        context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
        check(context != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed: 0x${Integer.toHexString(EGL14.eglGetError())}" }
        surface = EGL14.eglCreatePbufferSurface(display, configs[0], intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
        check(surface != EGL14.EGL_NO_SURFACE) { "eglCreatePbufferSurface failed: 0x${Integer.toHexString(EGL14.eglGetError())}" }
        check(EGL14.eglMakeCurrent(display, surface, surface, context)) { "eglMakeCurrent failed: 0x${Integer.toHexString(EGL14.eglGetError())}" }

        renderer = GLES30.glGetString(GLES30.GL_RENDERER) ?: ""
        version = GLES30.glGetString(GLES30.GL_VERSION) ?: ""
        val single = IntArray(2)
        fun queryInt(name: Int): Int { GLES30.glGetIntegerv(name, single, 0); return single[0] }
        val maxTexture = queryInt(GLES30.GL_MAX_TEXTURE_SIZE)
        val maxRenderbuffer = queryInt(GLES30.GL_MAX_RENDERBUFFER_SIZE)
        val max3d = queryInt(GLES30.GL_MAX_3D_TEXTURE_SIZE)
        GLES30.glGetIntegerv(GLES30.GL_MAX_VIEWPORT_DIMS, single, 0)
        val viewportW = single[0]; val viewportH = single[1]
        maxTileEdge = minOf(maxTexture, maxRenderbuffer, viewportW, viewportH)
        val extensions = GLES30.glGetString(GLES30.GL_EXTENSIONS) ?: ""
        limits.put("GL_MAX_TEXTURE_SIZE", maxTexture)
            .put("GL_MAX_RENDERBUFFER_SIZE", maxRenderbuffer)
            .put("GL_MAX_3D_TEXTURE_SIZE", max3d)
            .put("GL_MAX_VIEWPORT_DIMS", org.json.JSONArray(listOf(viewportW, viewportH)))
            .put("tile_edge_used", maxTileEdge)
            .put("OES_texture_float_linear", extensions.contains("GL_OES_texture_float_linear"))
            .put("EXT_color_buffer_half_float", extensions.contains("GL_EXT_color_buffer_half_float"))
            .put("EXT_color_buffer_float", extensions.contains("GL_EXT_color_buffer_float"))
            .put("egl_version", "${versionOut[0]}.${versionOut[1]}")

        val vaoOut = IntArray(1)
        GLES30.glGenVertexArrays(1, vaoOut, 0)
        emptyVertexArray = vaoOut[0]
        log("GL: $renderer | $version | limits $limits")
    }

    /** Compiles both programs; returns compile+link time per variant in ms. */
    fun buildPrograms(): JSONObject {
        val times = JSONObject()
        for (variant in VARIANTS) {
            val (program, ms) = timedMs { linkProgram(VERTEX_SHADER, fragmentShaderFor(variant)) }
            programs[variant] = program
            times.put(variant, ms)
        }
        return times
    }

    /** Uploads the fused LUT to both variants' 3D textures; returns upload time per variant (ms). */
    fun uploadLut(fusedRgba: FloatArray): JSONObject {
        val times = JSONObject()
        val buffer = ByteBuffer.allocateDirect(fusedRgba.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        buffer.put(fusedRgba).position(0)
        for (variant in VARIANTS) {
            lutTextures.remove(variant)?.let { GLES30.glDeleteTextures(1, intArrayOf(it), 0) }
            val (_, ms) = timedMs {
                val ids = IntArray(1)
                GLES30.glGenTextures(1, ids, 0)
                GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, ids[0])
                val internalFormat = if (variant == VARIANT_16F_LINEAR) GLES30.GL_RGBA16F else GLES30.GL_RGBA32F
                val filter = if (variant == VARIANT_16F_LINEAR) GLES30.GL_LINEAR else GLES30.GL_NEAREST
                GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 4)
                GLES30.glTexImage3D(GLES30.GL_TEXTURE_3D, 0, internalFormat, LUT_DIM, LUT_DIM, LUT_DIM, 0, GLES30.GL_RGBA, GLES30.GL_FLOAT, buffer)
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_MIN_FILTER, filter)
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_MAG_FILTER, filter)
                for (wrap in intArrayOf(GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_TEXTURE_WRAP_R)) {
                    GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, wrap, GLES30.GL_CLAMP_TO_EDGE)
                }
                GLES30.glFinish()
                lutTextures[variant] = ids[0]
            }
            checkGlError("uploadLut($variant)")
            times.put(variant, ms)
        }
        return times
    }

    /**
     * End-to-end LUT application timing: input texture alloc + upload, FBO alloc, draw,
     * glReadPixels of every pixel into CPU memory, glFinish, cleanup. Everything is inside the
     * timed region. If [output] is null the readback goes through a reused strip buffer (used
     * when a full-frame output buffer cannot be allocated); all pixels are still read back.
     */
    fun apply(variant: String, source: Bitmap, output: ByteBuffer?): Double {
        val program = programs.getValue(variant)
        val lutTexture = lutTextures.getValue(variant)
        val width = source.width
        val height = source.height
        val tileEdge = maxTileEdge
        val needsTiling = width > tileEdge || height > tileEdge
        val stripBuffer = if (output == null) ByteBuffer.allocateDirect(min(width, tileEdge) * STRIP_ROWS * 4) else null

        val start = System.nanoTime()
        GLES30.glUseProgram(program)
        GLES30.glBindVertexArray(emptyVertexArray)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(program, "uImage"), 0)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(program, "uLut"), 1)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, lutTexture)
        var tileY = 0
        while (tileY < height) {
            val tileH = min(tileEdge, height - tileY)
            var tileX = 0
            while (tileX < width) {
                val tileW = min(tileEdge, width - tileX)
                // Tiling path copies the tile into its own bitmap; that copy is part of the cost.
                val tileBitmap = if (needsTiling) Bitmap.createBitmap(source, tileX, tileY, tileW, tileH) else source
                renderTile(tileBitmap, tileW, tileH) {
                    readTile(tileX, tileY, tileW, tileH, width, output, stripBuffer)
                }
                if (tileBitmap !== source) tileBitmap.recycle()
                tileX += tileW
            }
            tileY += tileH
        }
        GLES30.glFinish()
        val elapsedMs = (System.nanoTime() - start) / 1e6
        checkGlError("apply($variant ${width}x$height)")
        return elapsedMs
    }

    private inline fun renderTile(tileBitmap: Bitmap, tileW: Int, tileH: Int, readBack: () -> Unit) {
        val ids = IntArray(2)
        GLES30.glGenTextures(2, ids, 0)
        val inputTexture = ids[0]; val outputTexture = ids[1]

        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, inputTexture)
        GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 4)
        GLUtils.texImage2D(GLES30.GL_TEXTURE_2D, 0, tileBitmap, 0)
        // NEAREST + no mips keeps the texture complete (default min filter needs mipmaps).
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)

        GLES30.glActiveTexture(GLES30.GL_TEXTURE2)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, outputTexture)
        GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, GLES30.GL_RGBA8, tileW, tileH)
        val framebuffers = IntArray(1)
        GLES30.glGenFramebuffers(1, framebuffers, 0)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffers[0])
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, outputTexture, 0)
        val status = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER)
        if (status != GLES30.GL_FRAMEBUFFER_COMPLETE) {
            val glError = GLES30.glGetError()
            cleanupTile(framebuffers[0], ids)
            throw IllegalStateException("FBO incomplete for ${tileW}x$tileH: status 0x${Integer.toHexString(status)}, glError 0x${Integer.toHexString(glError)}")
        }
        GLES30.glViewport(0, 0, tileW, tileH)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, inputTexture)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
        readBack()
        cleanupTile(framebuffers[0], ids)
    }

    private fun cleanupTile(framebuffer: Int, textures: IntArray) {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        GLES30.glDeleteFramebuffers(1, intArrayOf(framebuffer), 0)
        GLES30.glDeleteTextures(textures.size, textures, 0)
    }

    private fun readTile(tileX: Int, tileY: Int, tileW: Int, tileH: Int, fullWidth: Int, output: ByteBuffer?, stripBuffer: ByteBuffer?) {
        GLES30.glPixelStorei(GLES30.GL_PACK_ALIGNMENT, 4)
        if (output != null) {
            // Row y of the FBO is row y of the input (texelFetch at gl_FragCoord, no flip), so
            // the tile lands at its own offset in the full-frame buffer with PACK_ROW_LENGTH.
            GLES30.glPixelStorei(GLES30.GL_PACK_ROW_LENGTH, fullWidth)
            output.position((tileY * fullWidth + tileX) * 4)
            val target = output.slice()
            GLES30.glReadPixels(0, 0, tileW, tileH, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, target)
            output.position(0)
            GLES30.glPixelStorei(GLES30.GL_PACK_ROW_LENGTH, 0)
        } else {
            val strip = stripBuffer!!
            var row = 0
            while (row < tileH) {
                val rows = min(STRIP_ROWS, tileH - row)
                strip.position(0)
                GLES30.glReadPixels(0, row, tileW, rows, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, strip)
                row += rows
            }
        }
    }

    fun checkGlError(where: String) {
        val error = GLES30.glGetError()
        if (error != GLES30.GL_NO_ERROR) {
            val name = when (error) {
                GLES30.GL_OUT_OF_MEMORY -> "GL_OUT_OF_MEMORY"
                GLES30.GL_INVALID_VALUE -> "GL_INVALID_VALUE"
                GLES30.GL_INVALID_OPERATION -> "GL_INVALID_OPERATION"
                GLES30.GL_INVALID_ENUM -> "GL_INVALID_ENUM"
                GLES30.GL_INVALID_FRAMEBUFFER_OPERATION -> "GL_INVALID_FRAMEBUFFER_OPERATION"
                else -> "0x${Integer.toHexString(error)}"
            }
            throw IllegalStateException("GL error $name at $where")
        }
    }

    fun release() {
        if (display != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(display, surface)
            EGL14.eglDestroyContext(display, context)
            EGL14.eglTerminate(display)
        }
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, source)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val info = GLES30.glGetShaderInfoLog(shader)
            GLES30.glDeleteShader(shader)
            throw IllegalStateException("shader compile failed: $info")
        }
        return shader
    }

    private fun linkProgram(vertexSource: String, fragmentSource: String): Int {
        val vertex = compileShader(GLES30.GL_VERTEX_SHADER, vertexSource)
        val fragment = compileShader(GLES30.GL_FRAGMENT_SHADER, fragmentSource)
        val program = GLES30.glCreateProgram()
        GLES30.glAttachShader(program, vertex)
        GLES30.glAttachShader(program, fragment)
        GLES30.glLinkProgram(program)
        val status = IntArray(1)
        GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) throw IllegalStateException("program link failed: ${GLES30.glGetProgramInfoLog(program)}")
        GLES30.glDeleteShader(vertex)
        GLES30.glDeleteShader(fragment)
        return program
    }

    private fun fragmentShaderFor(variant: String): String = when (variant) {
        VARIANT_16F_LINEAR -> FRAGMENT_HEADER + """
            void main() {
                vec3 color = texelFetch(uImage, ivec2(gl_FragCoord.xy), 0).rgb;
                // Texel-centre mapping: grid point k of N lives at (k + 0.5) / N.
                vec3 coord = (color * ${LUT_DIM - 1}.0 + 0.5) / ${LUT_DIM}.0;
                fragColor = vec4(clamp(texture(uLut, coord).rgb, 0.0, 1.0), 1.0);
            }
        """.trimIndent()
        VARIANT_32F_MANUAL -> FRAGMENT_HEADER + """
            void main() {
                vec3 color = texelFetch(uImage, ivec2(gl_FragCoord.xy), 0).rgb;
                vec3 scaled = color * ${LUT_DIM - 1}.0;
                ivec3 base = clamp(ivec3(floor(scaled)), ivec3(0), ivec3(${LUT_DIM - 2}));
                vec3 frac = scaled - vec3(base);
                vec3 c000 = texelFetch(uLut, base + ivec3(0, 0, 0), 0).rgb;
                vec3 c100 = texelFetch(uLut, base + ivec3(1, 0, 0), 0).rgb;
                vec3 c010 = texelFetch(uLut, base + ivec3(0, 1, 0), 0).rgb;
                vec3 c110 = texelFetch(uLut, base + ivec3(1, 1, 0), 0).rgb;
                vec3 c001 = texelFetch(uLut, base + ivec3(0, 0, 1), 0).rgb;
                vec3 c101 = texelFetch(uLut, base + ivec3(1, 0, 1), 0).rgb;
                vec3 c011 = texelFetch(uLut, base + ivec3(0, 1, 1), 0).rgb;
                vec3 c111 = texelFetch(uLut, base + ivec3(1, 1, 1), 0).rgb;
                vec3 c00 = mix(c000, c100, frac.r);
                vec3 c10 = mix(c010, c110, frac.r);
                vec3 c01 = mix(c001, c101, frac.r);
                vec3 c11 = mix(c011, c111, frac.r);
                vec3 c0 = mix(c00, c10, frac.g);
                vec3 c1 = mix(c01, c11, frac.g);
                fragColor = vec4(clamp(mix(c0, c1, frac.b), 0.0, 1.0), 1.0);
            }
        """.trimIndent()
        else -> throw IllegalArgumentException(variant)
    }

    companion object {
        const val VARIANT_16F_LINEAR = "rgba16f_linear"
        const val VARIANT_32F_MANUAL = "rgba32f_manual"
        val VARIANTS = listOf(VARIANT_16F_LINEAR, VARIANT_32F_MANUAL)
        private const val STRIP_ROWS = 256

        private val VERTEX_SHADER = """
            #version 300 es
            void main() {
                // Attribute-less full-screen triangle.
                vec2 corner = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
                gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
            }
        """.trimIndent()

        private val FRAGMENT_HEADER = """
            #version 300 es
            precision highp float;
            precision highp int;
            precision highp sampler2D;
            precision highp sampler3D;
            uniform sampler2D uImage;
            uniform sampler3D uLut;
            out vec4 fragColor;

        """.trimIndent() + "\n"
    }
}
