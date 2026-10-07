package com.lightlylabs.lightly.background

import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer
import java.security.MessageDigest

/**
 * Bit-exactness of the Background stage (completion plan A1, 2026-10-07): speed changes must leave every float and
 * byte unchanged. The golden tests compare with tolerances, so they cannot show that; these hashes were recorded from
 * the implementation at 68b4e37, before the drag-frame speed work, and must not change.
 * A deliberate change to the rendering arithmetic re-records them in the same commit, with the reason.
 */
class BackgroundExactnessTest {
    private fun scene(w: Int, h: Int, seed: Int): Triple<ByteArray, BackgroundAnalysis, FloatImage> {
        val developed = ByteArray(w * h * 4) { i -> if (i % 4 == 3) -1 else ((i / 4 % w * 7 + i / 4 / w * 3 + i % 4 * 40 + seed) % 251).toByte() }
        val inside = { x: Int, y: Int -> val dx = (x - w / 2.0) / (w * 0.33); val dy = (y - h * 0.62) / (h * 0.45); dx * dx + dy * dy }
        val matte = FloatPlane(w, h, FloatArray(w * h) { p -> (1.5f - inside(p % w, p / w).toFloat() * 1.5f).coerceIn(0f, 1f) })
        val nearness = FloatPlane(w, h, FloatArray(w * h) { p -> if (matte.values[p] > 0.5f) 0.75f + 0.05f * (p / w).toFloat() / h else 0.1f + 0.2f * (p % w).toFloat() / w })
        val replacement = ReplacementImage.gradient(w, h, 90.0, listOf("#3C4A55" to 0.0, "#C8A060" to 1.0))
        return Triple(developed, BackgroundAnalysis(w, h, NormalisedDepth(DepthOrigin.ESTIMATED, nearness), matte), replacement)
    }

    private fun digest(vararg parts: Any?): String {
        val sha = MessageDigest.getInstance("SHA-256")
        for (part in parts) when (part) {
            null -> sha.update(0)
            is ByteArray -> sha.update(part)
            is FloatArray -> { val b = ByteBuffer.allocate(part.size * 4); part.forEach { b.putFloat(it) }; sha.update(b.array()) }
            else -> error("unsupported $part")
        }
        return sha.digest().take(12).joinToString("") { "%02x".format(it) }
    }

    private fun render(w: Int, h: Int, style: String, layers: Int, seed: Int): String {
        val (developed, analysis, replacement) = scene(w, h, seed)
        val frameW = w * 5 / 3
        val frameH = h * 5 / 3
        val full = ReplacementPixels(frameW, frameH, ByteArray(frameW * frameH * 4) { if (it % 4 == 3) -1 else (it % 7 * 30).toByte() })
        val plan = BackgroundPlan(replacement, FocusParams(60.0, 40.0, style, "round", 50.0), 0.8, null, full)
        val working = BackgroundStage.renderWorking(developed, analysis, plan, layers)
        val region = ByteArray(frameW * frameH * 4) { if (it % 4 == 3) -1 else ((it * 13 + seed) % 251).toByte() }
        val out = BackgroundStage.applyRegion(region, 0, 0, frameW, frameH, frameW, frameH, working, full)
        return digest(working.blurred?.data, working.sharp?.data, working.weight?.values, working.foregroundShift?.data, out)
    }

    @Test
    fun `drag-size lens render is bit-identical`() = assertEquals(EXPECTED_DRAG_LENS, render(160, 240, "lens", Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW, 1))

    @Test
    fun `settled-size soft render is bit-identical`() = assertEquals(EXPECTED_SETTLED_SOFT, render(256, 384, "soft", Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW, 2))

    @Test
    fun `export-layers swirl render is bit-identical`() = assertEquals(EXPECTED_EXPORT_SWIRL, render(200, 300, "swirl", Refocus.FocusConstants.LAYERS_PER_SIDE_EXPORT, 3))

    @Test
    fun `a kept scene geometry gives the same bits as a fresh one for a new Look`() {
        val (developed, analysis, replacement) = scene(160, 240, 5)
        val plan = BackgroundPlan(replacement, FocusParams(60.0, 40.0, "lens", "round", 50.0), 0.8, null, null)
        BackgroundStage.releasePreviewCaches()
        BackgroundStage.renderWorking(developed, analysis, plan, Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW, dragFrame = true)
        val before = BackgroundStage.sceneGeometries
        // The next drag frame: another Look (other bytes), the same depth and matte planes.
        val nextLook = ByteArray(developed.size) { i -> if (i % 4 == 3) -1 else (developed[i] + 17).toByte() }
        val kept = BackgroundStage.renderWorking(nextLook, analysis, plan, Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW, dragFrame = true)
        assertEquals("the geometry is reused", before, BackgroundStage.sceneGeometries)
        BackgroundStage.releasePreviewCaches()
        val fresh = BackgroundStage.renderWorking(nextLook, analysis, plan, Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW)
        assertEquals(digest(fresh.blurred?.data, fresh.sharp?.data, fresh.weight?.values), digest(kept.blurred?.data, kept.sharp?.data, kept.weight?.values))
    }

    @Test
    fun `foreground estimate is bit-identical`() {
        val (developed, analysis, _) = scene(150, 220, 4)
        val photo = FloatImage(150, 220, 3, FloatArray(150 * 220 * 3) { SrgbBytes.TO_LINEAR[developed[(it / 3) * 4 + it % 3].toInt() and 0xff] })
        assertEquals(EXPECTED_FOREGROUND, digest(ForegroundEstimate.estimate(photo, analysis.matte!!).data))
    }

    companion object {
        const val EXPECTED_DRAG_LENS = "3792291133cf1b5014455ce3"
        const val EXPECTED_SETTLED_SOFT = "07721c54f59624eef485272f"
        const val EXPECTED_EXPORT_SWIRL = "1e7c6d4cf72e8803be1c2036"
        const val EXPECTED_FOREGROUND = "69af8df3d3159a976a186391"
    }
}
