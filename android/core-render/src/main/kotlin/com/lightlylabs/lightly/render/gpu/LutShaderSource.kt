package com.lightlylabs.lightly.render.gpu

import com.lightlylabs.lightly.render.lut.LutPassPlan

/**
 * GLSL ES 3.00 sources for the LUT passes, generated per pass count so a render with no Look does
 * not pay for a second lookup. Ported from the LUTBench `rgba32f_manual` variant (GlLut.kt), which
 * was within 1/255 of the reference on the emulator (GPU accuracy on Adreno/Mali is PENDING).
 *
 * Why one fragment shader for both passes rather than two draw calls: the value between O1 and O2
 * must stay float (it may be > 1; the next stage clamps it, §4.2). Two draws through an RGBA8
 * framebuffer would quantise and clip it to 8 bits, which the CPU oracle does not do.
 *
 * Why manual trilinear with texelFetch on an RGBA32F texture rather than `texture()` on RGBA16F:
 * hardware filtering uses reduced-precision weights on some GPUs, and RGBA16F loses precision on
 * out-of-range entries. A faster RGBA16F + GL_LINEAR variant can be enabled per GPU only after it
 * is measured within tolerance on that device (spec §8 "Precision").
 */
object LutShaderSource {

    const val IMAGE_SAMPLER = "uImage"

    /** Sampler uniform for pass [index]: uLut0 = Auto (O1), uLut1 = Look (O2) when both are present. */
    fun lutSampler(index: Int): String = "uLut$index"

    /** Attribute-less full-screen triangle (no vertex buffers). */
    val vertexShader: String = """
        #version 300 es
        void main() {
            vec2 corner = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
            gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
        }
    """.trimIndent()

    fun fragmentShader(passCount: Int, lutDimension: Int): String {
        require(passCount in 0..LutPassPlan.MAX_PASSES) { "passCount must be 0..${LutPassPlan.MAX_PASSES}, was $passCount" }
        require(lutDimension >= 2) { "lutDimension must be >= 2" }
        val samplers = (0 until passCount).joinToString("\n") { "uniform sampler3D ${lutSampler(it)};" }
        val passes = (0 until passCount).joinToString("\n") { "    color = applyLut(${lutSampler(it)}, color);" }
        return buildString {
            appendLine("#version 300 es")
            appendLine("precision highp float;")
            appendLine("precision highp int;")
            appendLine("precision highp sampler2D;")
            appendLine("precision highp sampler3D;")
            appendLine("uniform sampler2D $IMAGE_SAMPLER;")
            if (samplers.isNotEmpty()) appendLine(samplers)
            appendLine("out vec4 fragColor;")
            appendLine()
            if (passCount > 0) append(applyLutFunction(lutDimension))
            appendLine("void main() {")
            // The source is an RGBA8 (not SRGB8_ALPHA8) texture: LUTs are defined on sRGB-encoded
            // values, so the GPU must not linearise on fetch. texelFetch at gl_FragCoord: no filtering.
            appendLine("    vec4 source = texelFetch($IMAGE_SAMPLER, ivec2(gl_FragCoord.xy), 0);")
            appendLine("    vec3 color = source.rgb;")
            if (passes.isNotEmpty()) appendLine(passes)
            // O4: the only clamp outside the passes. Alpha passes through.
            appendLine("    fragColor = vec4(clamp(color, 0.0, 1.0), source.a);")
            appendLine("}")
        }
    }

    /** §4.2 stage: clamp the INPUT, exact-grid trilinear (pos = v·(N−1)), output unclamped. */
    private fun applyLutFunction(dimension: Int): String = """
        vec3 applyLut(highp sampler3D lut, vec3 color) {
            vec3 scaled = clamp(color, 0.0, 1.0) * ${dimension - 1}.0;
            ivec3 base = clamp(ivec3(floor(scaled)), ivec3(0), ivec3(${dimension - 2}));
            vec3 frac = scaled - vec3(base);
            vec3 c000 = texelFetch(lut, base + ivec3(0, 0, 0), 0).rgb;
            vec3 c100 = texelFetch(lut, base + ivec3(1, 0, 0), 0).rgb;
            vec3 c010 = texelFetch(lut, base + ivec3(0, 1, 0), 0).rgb;
            vec3 c110 = texelFetch(lut, base + ivec3(1, 1, 0), 0).rgb;
            vec3 c001 = texelFetch(lut, base + ivec3(0, 0, 1), 0).rgb;
            vec3 c101 = texelFetch(lut, base + ivec3(1, 0, 1), 0).rgb;
            vec3 c011 = texelFetch(lut, base + ivec3(0, 1, 1), 0).rgb;
            vec3 c111 = texelFetch(lut, base + ivec3(1, 1, 1), 0).rgb;
            vec3 c00 = mix(c000, c100, frac.r);
            vec3 c10 = mix(c010, c110, frac.r);
            vec3 c01 = mix(c001, c101, frac.r);
            vec3 c11 = mix(c011, c111, frac.r);
            vec3 c0 = mix(c00, c10, frac.g);
            vec3 c1 = mix(c01, c11, frac.g);
            return mix(c0, c1, frac.b);
        }

    """.trimIndent() + "\n"
}
