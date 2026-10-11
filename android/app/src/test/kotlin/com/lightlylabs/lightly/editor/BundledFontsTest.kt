package com.lightlylabs.lightly.editor

import android.graphics.Paint
import android.graphics.Typeface
import androidx.test.core.app.ApplicationProvider
import com.lightlylabs.lightly.session.NormalisedPoint
import com.lightlylabs.lightly.session.TextFont
import com.lightlylabs.lightly.session.TextLayer
import com.lightlylabs.lightly.session.TextWeight
import com.lightlylabs.lightly.session.WatermarkFont
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * Owner amendments 2026-10-11 (second): the eleven Text fonts and thirteen Watermark › Text fonts are bundled from
 * shared/fonts (with their licences) and load; the Text weight reaches the variable fonts' `wght` axis; a character a
 * signature script lacks falls back to a system font instead of drawing nothing.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class BundledFontsTest {
    private val assets = ApplicationProvider.getApplicationContext<android.app.Application>().assets
    private val fonts = WatermarkFonts(assets)
    private val sample = "Summer in Lisbon"

    private fun width(typeface: Typeface, text: String = sample) = Paint().apply { this.typeface = typeface; textSize = 100f }.measureText(text)

    @Test
    fun `the eleven Text fonts and thirteen watermark fonts are bundled with their licences and load`() {
        assertEquals(11, TextOptions.FONTS.size)
        assertEquals(13, WatermarkOptions.FONTS.size)
        assertEquals(WatermarkFont.entries, WatermarkOptions.FONTS.map { it.first })
        val files = (TextFont.entries.map(WatermarkFonts::textFontFile) + WatermarkFont.entries.map(WatermarkFonts::watermarkFontFile)).toSet()
        val bundled = assets.list(WatermarkFonts.ASSET_DIR)!!.toSet()
        files.forEach { file ->
            assertTrue(file in bundled, "$file is in assets/fonts")
            val family = file.substringBefore('-')
            assertTrue(bundled.any { it.startsWith("$family-") && (it.endsWith("-OFL.txt") || it.substringBeforeLast('.').endsWith("-LICENSE")) }, "$file ships with its licence")
        }
        val fallbackWidth = width(Typeface.DEFAULT)
        TextFont.entries.forEach { font -> assertNotEquals(fallbackWidth, width(fonts.textTypeface(font)), "$font loads its own file") }
        WatermarkFont.entries.forEach { font -> assertNotEquals(fallbackWidth, width(fonts.typeface(font)), "$font loads its own file") }
    }

    @Test
    fun `bold is wider than regular and regular wider than thin on a variable font, a single-weight font ignores the weight`() {
        for (font in listOf(TextFont.INTER, TextFont.MONTSERRAT)) {
            val thin = width(fonts.textTypeface(font, TextWeight.THIN))
            val regular = width(fonts.textTypeface(font, TextWeight.REGULAR))
            val bold = width(fonts.textTypeface(font, TextWeight.BOLD))
            assertTrue(bold > regular && regular > thin, "$font: thin $thin, regular $regular, bold $bold")
        }
        assertEquals(width(fonts.textTypeface(TextFont.BEBAS_NEUE, TextWeight.REGULAR)), width(fonts.textTypeface(TextFont.BEBAS_NEUE, TextWeight.BOLD)))
        // Stage 11 (preview, marks and Save copy) lays the block out at the layer's weight.
        val stage = TextStage(fonts)
        fun layer(weight: TextWeight) = TextLayer("0a1b2c3d", sample, TextFont.INTER, weight, 42, "#FFFFFF", 100.0, NormalisedPoint(0.5, 0.5), 0.0)
        assertTrue(stage.block(layer(TextWeight.BOLD), 1000.0, 800.0).width > stage.block(layer(TextWeight.REGULAR), 1000.0, 800.0).width)
    }

    @Test
    fun `a character a signature script lacks falls back to a system font`() {
        // Carpenters has no "." and Astoria, Monttee and Shareit no "·" (shared/fonts/README.md).
        for ((font, missing) in listOf(WatermarkFont.CARPENTERS to ".", WatermarkFont.ASTORIA to "·", WatermarkFont.MONTTEE to "·", WatermarkFont.SHAREIT to "·")) {
            val paint = Paint().apply { typeface = fonts.typeface(font); textSize = 100f }
            assertTrue(paint.hasGlyph(missing), "$font draws \"$missing\" through the fallback chain")
            assertTrue(paint.measureText("A${missing}B") > paint.measureText("AB"), "$font gives \"$missing\" an advance")
        }
    }
}
