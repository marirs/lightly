package com.lightlylabs.lightly.render.gl

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES30
import com.lightlylabs.lightly.render.gpu.LutShaderSource
import com.lightlylabs.lightly.render.gpu.LutTexturePacking
import com.lightlylabs.lightly.render.gpu.TileCopy
import com.lightlylabs.lightly.render.gpu.TilePlan
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.render.lut.LutPassPlan
import com.lightlylabs.lightly.render.lut.LutPassRenderer
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.IdentityHashMap

/**
 * Offscreen OpenGL ES 3.0 implementation of [LutPassRenderer], ported from the LUTBench harness
 * (experiments/lut3d/android/LUTBench/.../GlLut.kt, `rgba32f_manual` variant).
 *
 * PENDING (physical device): nothing in this class has run on a GPU in M2. Accuracy against
 * [com.lightlylabs.lightly.render.lut.CpuLutPassRenderer] (≤ 1/255 expected, as the shader-math
 * twin test shows on the JVM), timings and memory must be measured on Adreno and Mali.
 *
 * Threading: EGL contexts are thread-bound. [create] makes the context current on the calling
 * thread, and every later call must come from that same thread: in the app this is the
 * single-thread dispatcher the RenderScheduler and the export path run on (spec §5.2, §8).
 *
 * Differences from LUTBench, on purpose:
 * - Auto and Look are two LUT passes in one shader (spec §4.1 revised); LUTBench applied one fused LUT.
 * - Alpha passes through instead of being forced to 1.
 * - Tiles come from [TilePlan] (≤ 4096², spec §5.3) and are uploaded from RGBA8 byte buffers, not
 *   per-tile Bitmap copies, so this class has no Bitmap dependency.
 */
class GlLutPassRenderer private constructor(
    private val display: EGLDisplay,
    private val context: EGLContext,
    private val surface: EGLSurface,
    private val ownerThread: Thread,
    /** min(GL_MAX_TEXTURE_SIZE, GL_MAX_RENDERBUFFER_SIZE, GL_MAX_VIEWPORT_DIMS). */
    val deviceMaxTileEdge: Int,
    val maxTexture3dSize: Int,
    val rendererName: String,
) : LutPassRenderer {

    private val emptyVertexArray: Int = IntArray(1).also { GLES30.glGenVertexArrays(1, it, 0) }[0]
    private val programsByPassCount = HashMap<Int, Int>()

    // Identity-keyed: the same blended Lut3D instance is reused across preview frames, so its texture
    // is uploaded once. Released LUTs are dropped in [releaseLutTextures].
    private val lutTextures = IdentityHashMap<Lut3D, Int>()
    private var released = false

    override fun render(source: Rgba8Image, plan: LutPassPlan): Rgba8Image {
        checkOwner()
        val program = programFor(plan)
        val lutTextureIds = plan.passes.map { lut -> textureFor(lut) }
        val tilePlan = TilePlan.plan(source.width, source.height, deviceMaxTileEdge)
        val output = ByteArray(source.pixels.size)

        GLES30.glUseProgram(program)
        GLES30.glBindVertexArray(emptyVertexArray)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(program, LutShaderSource.IMAGE_SAMPLER), 0)
        lutTextureIds.forEachIndexed { index, textureId ->
            val unit = index + 1
            GLES30.glUniform1i(GLES30.glGetUniformLocation(program, LutShaderSource.lutSampler(index)), unit)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0 + unit)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, textureId)
        }
        for (tile in tilePlan.tiles) {
            val rendered = renderTile(TileCopy.extract(source, tile))
            TileCopy.insert(output, source.width, tile, rendered)
        }
        GLES30.glFinish()
        checkGlError("render ${source.width}x${source.height}, ${plan.passes.size} passes")
        return Rgba8Image(source.width, source.height, output)
    }

    /** Frees GL textures of LUTs that are no longer in use (call when a Look or Auto result changes). */
    fun releaseLutTextures(keep: Collection<Lut3D> = emptyList()) {
        checkOwner()
        val keepSet = keep.toCollection(java.util.Collections.newSetFromMap(IdentityHashMap()))
        val iterator = lutTextures.entries.iterator()
        while (iterator.hasNext()) {
            val (lut, textureId) = iterator.next()
            if (lut !in keepSet) {
                GLES30.glDeleteTextures(1, intArrayOf(textureId), 0)
                iterator.remove()
            }
        }
    }

    fun release() {
        if (released) return
        checkOwner()
        releaseLutTextures()
        programsByPassCount.values.forEach(GLES30::glDeleteProgram)
        GLES30.glDeleteVertexArrays(1, intArrayOf(emptyVertexArray), 0)
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        EGL14.eglDestroySurface(display, surface)
        EGL14.eglDestroyContext(display, context)
        EGL14.eglTerminate(display)
        released = true
    }

    private fun checkOwner() {
        check(!released) { "GlLutPassRenderer was released" }
        check(Thread.currentThread() === ownerThread) {
            "GL calls must run on ${ownerThread.name}, the thread that owns the EGL context"
        }
    }

    private fun programFor(plan: LutPassPlan): Int {
        val passCount = plan.passes.size
        val dimension = plan.passes.firstOrNull()?.dimension ?: Lut3D.CONTRACT_DIMENSION
        return programsByPassCount.getOrPut(passCount) {
            linkProgram(LutShaderSource.vertexShader, LutShaderSource.fragmentShader(passCount, dimension))
        }
    }

    private fun textureFor(lut: Lut3D): Int = lutTextures.getOrPut(lut) {
        LutTexturePacking.requireFits(lut, maxTexture3dSize)
        val ids = IntArray(1)
        GLES30.glGenTextures(1, ids, 0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, ids[0])
        GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 4)
        GLES30.glTexImage3D(
            GLES30.GL_TEXTURE_3D, 0, GLES30.GL_RGBA32F, lut.dimension, lut.dimension, lut.dimension, 0,
            GLES30.GL_RGBA, GLES30.GL_FLOAT, LutTexturePacking.pack(lut),
        )
        // NEAREST: RGBA32F is not filterable in core ES 3.0, and the shader does its own trilinear.
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)
        for (wrap in intArrayOf(GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_TEXTURE_WRAP_R)) {
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, wrap, GLES30.GL_CLAMP_TO_EDGE)
        }
        checkGlError("upload ${lut.dimension}³ LUT")
        ids[0]
    }

    private fun renderTile(tile: Rgba8Image): Rgba8Image {
        val textures = IntArray(2)
        GLES30.glGenTextures(2, textures, 0)
        val inputTexture = textures[0]
        val outputTexture = textures[1]
        val framebuffers = IntArray(1)
        try {
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, inputTexture)
            GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 4)
            // Plain RGBA8, not SRGB8_ALPHA8: the LUTs are defined on sRGB-encoded values.
            GLES30.glTexImage2D(
                GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, tile.width, tile.height, 0,
                GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, directCopyOf(tile.pixels),
            )
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)

            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, outputTexture)
            GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, GLES30.GL_RGBA8, tile.width, tile.height)
            GLES30.glGenFramebuffers(1, framebuffers, 0)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffers[0])
            GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, outputTexture, 0)
            val status = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER)
            check(status == GLES30.GL_FRAMEBUFFER_COMPLETE) {
                "FBO incomplete for ${tile.width}x${tile.height}: 0x${Integer.toHexString(status)}"
            }

            GLES30.glViewport(0, 0, tile.width, tile.height)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, inputTexture)
            GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)

            // FBO row y is input row y (texelFetch at gl_FragCoord, no flip), so no row reversal.
            val readback = ByteBuffer.allocateDirect(tile.pixels.size).order(ByteOrder.nativeOrder())
            GLES30.glPixelStorei(GLES30.GL_PACK_ALIGNMENT, 4)
            GLES30.glReadPixels(0, 0, tile.width, tile.height, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, readback)
            val pixels = ByteArray(tile.pixels.size)
            readback.position(0)
            readback.get(pixels)
            return Rgba8Image(tile.width, tile.height, pixels)
        } finally {
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
            if (framebuffers[0] != 0) GLES30.glDeleteFramebuffers(1, framebuffers, 0)
            GLES30.glDeleteTextures(2, textures, 0)
        }
    }

    private fun directCopyOf(bytes: ByteArray): ByteBuffer =
        ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder()).put(bytes).also { it.position(0) }

    companion object {
        /** Creates the EGL context and makes it current on the calling thread, which then owns it. */
        fun create(): GlLutPassRenderer {
            val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            val version = IntArray(2)
            check(EGL14.eglInitialize(display, version, 0, version, 1)) { "eglInitialize failed: ${eglError()}" }
            val configs = arrayOfNulls<EGLConfig>(1)
            val count = IntArray(1)
            val attributes = intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_NONE,
            )
            check(EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) && count[0] > 0) {
                "No ES 3.0 pbuffer config: ${eglError()}"
            }
            val context = EGL14.eglCreateContext(
                display, configs[0], EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0,
            )
            check(context != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed: ${eglError()}" }
            // A 1x1 pbuffer only to make the context current; all rendering goes to FBOs.
            val surface = EGL14.eglCreatePbufferSurface(display, configs[0], intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
            check(surface != EGL14.EGL_NO_SURFACE) { "eglCreatePbufferSurface failed: ${eglError()}" }
            check(EGL14.eglMakeCurrent(display, surface, surface, context)) { "eglMakeCurrent failed: ${eglError()}" }

            val value = IntArray(2)
            fun query(name: Int): Int { GLES30.glGetIntegerv(name, value, 0); return value[0] }
            val maxTexture = query(GLES30.GL_MAX_TEXTURE_SIZE)
            val maxRenderbuffer = query(GLES30.GL_MAX_RENDERBUFFER_SIZE)
            val max3d = query(GLES30.GL_MAX_3D_TEXTURE_SIZE)
            GLES30.glGetIntegerv(GLES30.GL_MAX_VIEWPORT_DIMS, value, 0)
            val maxTileEdge = minOf(maxTexture, maxRenderbuffer, value[0], value[1])
            return GlLutPassRenderer(
                display, context, surface, Thread.currentThread(),
                deviceMaxTileEdge = maxTileEdge,
                maxTexture3dSize = max3d,
                rendererName = GLES30.glGetString(GLES30.GL_RENDERER) ?: "",
            )
        }

        private fun eglError(): String = "0x${Integer.toHexString(EGL14.eglGetError())}"

        private fun checkGlError(where: String) {
            val error = GLES30.glGetError()
            check(error == GLES30.GL_NO_ERROR) { "GL error 0x${Integer.toHexString(error)} at $where" }
        }

        private fun compileShader(type: Int, source: String): Int {
            val shader = GLES30.glCreateShader(type)
            GLES30.glShaderSource(shader, source)
            GLES30.glCompileShader(shader)
            val status = IntArray(1)
            GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
            if (status[0] == 0) {
                val log = GLES30.glGetShaderInfoLog(shader)
                GLES30.glDeleteShader(shader)
                error("Shader compile failed: $log")
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
            GLES30.glDeleteShader(vertex)
            GLES30.glDeleteShader(fragment)
            check(status[0] != 0) { "Program link failed: ${GLES30.glGetProgramInfoLog(program)}" }
            return program
        }
    }
}
