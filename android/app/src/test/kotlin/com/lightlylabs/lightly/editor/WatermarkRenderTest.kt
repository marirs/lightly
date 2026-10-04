package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.develop.PixelRect
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.BorderType
import com.lightlylabs.lightly.session.EditTools
import com.lightlylabs.lightly.session.WatermarkFont
import com.lightlylabs.lightly.session.WatermarkText
import com.lightlylabs.lightly.session.WatermarkType
import com.lightlylabs.lightly.signatures.DrawnSignature
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.test.assertContentEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Stage 12 drawn for real (Robolectric native graphics): ink inside the laid-out box, tiles equal the whole. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class WatermarkRenderTest {
    private val stage = WatermarkStage(WatermarkSizes.REVISION_2, WatermarkFonts(null))
    private fun grey(w: Int, h: Int) = Rgba8Image(w, h, ByteArray(w * h * 4) { if (it % 4 == 3) -1 else 60 })

    @Test
    fun `a drawn signature is inked at the bottom-right anchor, at the watermark's opacity, and composites the same per tile`() {
        val w = EditTools.neutral(0).watermark.copy(type = WatermarkType.SIGNATURE,
            signature = com.lightlylabs.lightly.session.SignatureRef("s", "0123456789ab", com.lightlylabs.lightly.session.SignatureKind.DRAWN), size = 60.0, colour = "#FFFFFF")
        val layer = assertNotNull(stage.layer(w, WatermarkContent.Drawn(DrawnSignature.PROTOTYPE_SAMPLE), 600, 400, PixelRect(0, 0, 600, 400), BorderType.NONE))
        val whole = layer.compositeOnto(grey(600, 400))
        var brightest = 0
        var where = 0 to 0
        for (y in 0 until 400) for (x in 0 until 600) {
            val v = whole.pixels[(y * 600 + x) * 4].toInt() and 0xff
            if (v > brightest) { brightest = v; where = x to y }
        }
        // White ink at 85 % over grey 60: about 60 + 0.85·195 ≈ 226 at full coverage.
        assertTrue(brightest in 200..235, "brightest $brightest")
        assertTrue(where.first > 300 && where.second > 250, "ink at $where")
        val tile = layer.compositeOnto(grey(100, 80), originX = 450, originY = 300)
        for (y in 0 until 80) for (x in 0 until 100) for (c in 0 until 3) {
            assertTrue(tile.pixels[(y * 100 + x) * 4 + c] == whole.pixels[((300 + y) * 600 + 450 + x) * 4 + c])
        }
    }

    @Test
    fun `text and the sample logo draw`() {
        val text = EditTools.neutral(0).watermark.copy(type = WatermarkType.TEXT, text = WatermarkText("A. Rivera", WatermarkFont.ALLURA))
        assertNotNull(stage.layer(text, WatermarkContent.Text("A. Rivera", WatermarkFont.ALLURA), 600, 400, PixelRect(0, 0, 600, 400), BorderType.NONE))
        val logo = EditTools.neutral(0).watermark.copy(type = WatermarkType.LOGO, logo = com.lightlylabs.lightly.session.WatermarkLogo(com.lightlylabs.lightly.session.AssetRef.Bundled(WatermarkStage.SAMPLE_LOGO_ID)))
        assertNotNull(stage.layer(logo, WatermarkContent.SampleLogo, 600, 400, PixelRect(0, 0, 600, 400), BorderType.NONE))
    }
}
