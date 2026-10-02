package com.lightlylabs.lightly.render.gpu

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Structure of the generated GLSL. Compiling and running it is PENDING on a device GPU. */
class LutShaderSourceTest {

    private fun mainBody(source: String) = source.substringAfter("void main() {").substringBefore("\n}")

    @Test
    fun `two passes apply Auto then Look in one shader with float in between`() {
        val source = LutShaderSource.fragmentShader(passCount = 2, lutDimension = 33)
        val body = mainBody(source)

        assertEquals(2, Regex("uniform sampler3D").findAll(source).count())
        val autoCall = body.indexOf("applyLut(uLut0, color)")
        val lookCall = body.indexOf("applyLut(uLut1, color)")
        assertTrue(autoCall >= 0 && lookCall > autoCall, "O1 (uLut0) must run before O2 (uLut1):\n$body")
        // No clamp between the passes in main: the next stage clamps its own input (§4.2).
        assertFalse(body.substring(autoCall, lookCall).contains("clamp"), "intermediate must not be clamped/quantised")
    }

    @Test
    fun `each stage clamps its input and the output is clamped exactly once`() {
        val source = LutShaderSource.fragmentShader(passCount = 2, lutDimension = 33)
        val function = source.substringAfter("vec3 applyLut(").substringBefore("void main()")

        assertTrue(function.contains("clamp(color, 0.0, 1.0) * 32.0"), "input clamp, pos = v*(N-1):\n$function")
        assertTrue(function.contains("ivec3(31)"), "cell index clamped to N-2 so v = 1.0 stays in the cube")
        assertFalse(function.substringAfter("vec3 frac").contains("clamp"), "stage output must stay unclamped")
        assertEquals(1, Regex("clamp\\(").findAll(mainBody(source)).count(), "single O4 clamp in main")
        assertTrue(mainBody(source).contains("source.a"), "alpha passes through")
    }

    @Test
    fun `only texelFetch is used, never hardware filtering`() {
        val source = LutShaderSource.fragmentShader(passCount = 2, lutDimension = 33)
        assertFalse(Regex("\\btexture\\(").containsMatchIn(source))
        assertEquals(9, Regex("texelFetch\\(").findAll(source).count(), "8 LUT corners + 1 image fetch")
    }

    @Test
    fun `pass count shapes the shader`() {
        val none = LutShaderSource.fragmentShader(passCount = 0, lutDimension = 33)
        assertFalse(none.contains("sampler3D uLut"))
        assertFalse(none.contains("applyLut"))

        val one = LutShaderSource.fragmentShader(passCount = 1, lutDimension = 33)
        assertEquals(1, Regex("uniform sampler3D").findAll(one).count())
        assertTrue(one.contains("applyLut(uLut0, color)"))
        assertFalse(one.contains("uLut1"))

        assertFailsWith<IllegalArgumentException> { LutShaderSource.fragmentShader(passCount = 3, lutDimension = 33) }
    }

    @Test
    fun `dimension is substituted`() {
        val source = LutShaderSource.fragmentShader(passCount = 1, lutDimension = 17)
        assertTrue(source.contains("* 16.0"))
        assertTrue(source.contains("ivec3(15)"))
    }

    @Test
    fun `sources declare GLSL ES 3_00 with high precision`() {
        val fragment = LutShaderSource.fragmentShader(passCount = 2, lutDimension = 33)
        assertTrue(fragment.startsWith("#version 300 es\n"))
        assertTrue(fragment.contains("precision highp float;"))
        assertTrue(fragment.contains("precision highp sampler3D;"))
        assertTrue(LutShaderSource.vertexShader.startsWith("#version 300 es\n"))
    }
}
