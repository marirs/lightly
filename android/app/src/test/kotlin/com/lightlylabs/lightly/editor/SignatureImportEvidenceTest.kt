package com.lightlylabs.lightly.editor

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import androidx.lifecycle.SavedStateHandle
import com.lightlylabs.lightly.develop.DevelopRenderer
import com.lightlylabs.lightly.develop.PixelRect
import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.FullResolutionSource
import com.lightlylabs.lightly.export.JpegEncoder
import com.lightlylabs.lightly.export.MediaStoreGateway
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.export.Rgba8ExportFrame
import com.lightlylabs.lightly.export.SaveCopyExporter
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.BorderType
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef
import com.lightlylabs.lightly.session.WatermarkType
import com.lightlylabs.lightly.signatures.DrawnSignature
import com.lightlylabs.lightly.signatures.SignatureStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import kotlin.math.abs
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Signature import (W6 and W10) through the real view model and stage, with the inputs iOS uses: real ink on
 * unevenly lit paper, low-contrast content (used as it is), a blank white image and a file that cannot be
 * decoded (both a toast, no sheet). Saves the Import sheet's preview (the extracted PNG) and the
 * watermark composited on the sunset photo to LIGHTLY_EVIDENCE_DIR (or a temporary folder), with a summary.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SignatureImportEvidenceTest {
    private val repo: File = File(checkNotNull(System.getProperty("lightly.renderingContract"))).parentFile.parentFile.parentFile
    private val out: File = (System.getenv("LIGHTLY_EVIDENCE_DIR")?.let { File(it, "signature-import") } ?: kotlin.io.path.createTempDirectory("import").toFile()).apply { mkdirs() }

    // getPixels/setPixels are channel-order explicit; copyPixelsToBuffer's byte order differs under
    // Robolectric's native graphics (it swapped red and blue here), which would recolour the ink.
    private fun rgba(bitmap: Bitmap): Rgba8Image {
        val colours = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(colours, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        val bytes = ByteArray(colours.size * 4)
        for (i in colours.indices) {
            val c = colours[i]
            bytes[i * 4] = (c shr 16).toByte(); bytes[i * 4 + 1] = (c shr 8).toByte(); bytes[i * 4 + 2] = c.toByte(); bytes[i * 4 + 3] = (c ushr 24).toByte()
        }
        return Rgba8Image(bitmap.width, bitmap.height, bytes)
    }

    /**
     * A photo of a signature: the prototype's path in dark blue ink on warm paper, 900 × 400, lit unevenly
     * (the paper darkens by 40 levels towards the right), which is where a global paper level leaves a faint
     * tinted rectangle.
     */
    private fun inkPhoto(): Rgba8Image {
        val bitmap = Bitmap.createBitmap(900, 400, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawPaint(android.graphics.Paint().apply {
            shader = android.graphics.LinearGradient(0f, 0f, 900f, 0f, android.graphics.Color.rgb(242, 238, 228), android.graphics.Color.rgb(202, 198, 188), android.graphics.Shader.TileMode.CLAMP)
        })
        WatermarkStage(WatermarkSizes.REVISION_2, WatermarkFonts(null)).drawSignature(canvas, DrawnSignature.PROTOTYPE_SAMPLE, 120f, 80f, 240f, android.graphics.Color.rgb(29, 42, 107))
        return rgba(bitmap)
    }

    private fun blankPhoto() = rgba(Bitmap.createBitmap(900, 400, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.WHITE) })

    /** Real content at low contrast (a soft grey gradient with a faint disc): no ink, not blank → used as it is. */
    private fun lowContrastPhoto(): Rgba8Image {
        val bitmap = Bitmap.createBitmap(900, 400, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawPaint(android.graphics.Paint().apply {
            shader = android.graphics.LinearGradient(0f, 0f, 900f, 0f, android.graphics.Color.rgb(150, 150, 150), android.graphics.Color.rgb(190, 190, 190), android.graphics.Shader.TileMode.CLAMP)
        })
        canvas.drawCircle(450f, 200f, 120f, android.graphics.Paint().apply { isAntiAlias = true; color = android.graphics.Color.rgb(175, 172, 168) })
        return rgba(bitmap)
    }

    private fun save(png: ByteArray, name: String) = File(out, "$name.png").writeBytes(png)

    private fun save(image: Rgba8Image, name: String) {
        val p = image.pixels
        val colours = IntArray(image.width * image.height) { i -> ((p[i * 4 + 3].toInt() and 0xff) shl 24) or ((p[i * 4].toInt() and 0xff) shl 16) or ((p[i * 4 + 1].toInt() and 0xff) shl 8) or (p[i * 4 + 2].toInt() and 0xff) }
        val bitmap = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888).apply { setPixels(colours, 0, image.width, 0, 0, image.width, image.height) }
        File(out, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `import with real ink, low-contrast content, a blank image and an undecodable file`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(dispatcher)
        val sunset = rgba(BitmapFactory.decodeFile(File(repo, "docs/ui/assets/photos/sunset_02.jpg").path))
        val photos = mapOf("ink" to inkPhoto(), "blank" to blankPhoto(), "lowcontrast" to lowContrastPhoto())
        val store = SignatureStore(null)
        val env = EditorEnvironment(
            photoLoader = PhotoLoader { asset ->
                if (asset == "content://editor") return@PhotoLoader LoadedPhoto(SourceRef(asset, SourceFingerprint("ab".repeat(32), 1, sunset.width, sunset.height), 1), sunset, sunset, FullResolutionSource { sunset })
                val image = photos[asset] ?: throw IllegalArgumentException("cannot decode $asset")
                LoadedPhoto(SourceRef(asset, SourceFingerprint("cd".repeat(32), 1, image.width, image.height), 1), image, image, FullResolutionSource { image })
            },
            photoAccess = object : PhotoAccessGrants { override fun retain(assetId: String) = true; override fun release(assetId: String) {} },
            autoDeveloper = AutoDeveloper { _, _, _ -> DevelopResult.NoModelInThisBuild },
            personDetector = PendingPersonDetector,
            library = CompletableDeferred(BundledPack.library),
            previewRenderer = DevelopRenderer(),
            renderDispatcher = dispatcher, prefetchDispatcher = dispatcher,
            exporter = ExportCoordinator(SaveCopyExporter(object : MediaStoreGateway<String> {
                override fun insertPending(spec: NewImageSpec) = "x"
                override fun openForWrite(handle: String) = java.io.ByteArrayOutputStream()
                override fun publish(handle: String) = true
                override fun delete(handle: String) {}
            }, JpegEncoder<Rgba8ExportFrame> { _, _, _ -> }), Rgba8ExportFrame.factory, dispatcher),
            favourites = object : FavouritesStore {
                override val favourites: StateFlow<List<String>> = MutableStateFlow(emptyList())
                override fun update(change: (List<String>) -> List<String>) {}
            },
            debugBuild = true, signatures = store,
        )
        val vm = EditorViewModel(SavedStateHandle(), env, CoroutineScope(SupervisorJob() + dispatcher))
        vm.openPhoto("content://editor")
        advanceUntilIdle()
        vm.selectTool(EditorTool.WATERMARK)
        val stage = WatermarkStage(WatermarkSizes.REVISION_2, WatermarkFonts(null))
        val summary = mutableListOf("input,outcome,toast,preview_px,stray_alpha_px,changed_px,changed_mean_delta,changed_outside_ink_px")
        val expected = mapOf(
            "ink" to null, "lowcontrast" to null,
            "blank" to EditorViewModel.SIGNATURE_IMPORT_BLANK, "broken" to EditorViewModel.SIGNATURE_IMPORT_UNREADABLE,
        )
        for ((input, toast) in expected) {
            vm.importSignaturePhoto(input)
            testScheduler.advanceTimeBy(100)
            testScheduler.runCurrent()
            val ui = vm.uiState.value
            val opened = ui.overlay == EditorOverlay.SIGNATURE_IMPORT
            val png = ui.watermark.imported
            if (toast != null) {
                // Never silent, never an empty rectangle: no sheet, the toast says why.
                assertTrue(!opened && png == null, "$input opens no sheet")
                assertEquals(toast, ui.toast, "$input shows its toast")
                summary += "$input,toast,\"${ui.toast}\",-,-,-,-,-"
                advanceUntilIdle()
                continue
            }
            assertTrue(opened, "$input opens the Import sheet")
            assertNotNull(png, "$input: the sheet has something to Use (W6)")
            save(png, "$input-sheet-preview")
            val preview = rgba(BitmapFactory.decodeByteArray(png, 0, png.size))
            // Alpha is exactly 0 away from the ink: no faint paper rectangle (only for an extracted signature).
            val previewAlpha = IntArray(preview.width * preview.height) { preview.pixels[it * 4 + 3].toInt() and 0xff }
            val core = BooleanArray(previewAlpha.size) { previewAlpha[it] >= 128 }
            val nearInk = com.lightlylabs.lightly.signatures.SignatureInkExtractor.dilate(core, preview.width, preview.height, com.lightlylabs.lightly.signatures.SignatureInkExtractor.INK_PROXIMITY + 2)
            val stray = previewAlpha.indices.count { previewAlpha[it] != 0 && !nearInk[it] }
            if (input == "ink") assertEquals(0, stray, "ink: alpha is exactly 0 away from the ink")
            vm.useImportedSignature()
            advanceUntilIdle()
            val w = vm.uiState.value.session!!.current.tools.watermark
            assertEquals(WatermarkType.SIGNATURE, w.type)
            val saved = store.resolve(w.signature!!)!!
            val layer = stage.layer(w, WatermarkContent.Imported(saved.data), sunset.width, sunset.height, PixelRect(0, 0, sunset.width, sunset.height), BorderType.NONE)!!
            val composite = layer.compositeOnto(sunset)
            save(composite, "$input-watermark-on-sunset")
            // What the watermark changed on the photo, and how much of that lies away from its ink (layer α ≥ 0.5).
            val layerCore = BooleanArray(layer.width * layer.height) { (layer.premultiplied[it * 4 + 3].toInt() and 0xff) >= 128 }
            val layerNear = com.lightlylabs.lightly.signatures.SignatureInkExtractor.dilate(layerCore, layer.width, layer.height, 3)
            var changed = 0; var delta = 0.0; var outside = 0
            for (y in 0 until sunset.height) for (x in 0 until sunset.width) {
                val i = y * sunset.width + x
                val d = (0 until 3).sumOf { abs((composite.pixels[i * 4 + it].toInt() and 0xff) - (sunset.pixels[i * 4 + it].toInt() and 0xff)) } / 3.0
                if (d <= 0) continue
                changed++; delta += d
                val lx = x - layer.x; val ly = y - layer.y
                if (lx !in 0 until layer.width || ly !in 0 until layer.height || !layerNear[ly * layer.width + lx]) outside++
            }
            if (input == "ink") assertEquals(0, outside, "ink: the composite changes nothing away from the ink")
            summary += listOf(input, "sheet", "-", "${preview.width}x${preview.height}", stray, changed, "%.1f".format(if (changed > 0) delta / changed else 0.0), outside).joinToString(",")
        }
        File(out, "summary.csv").writeText(summary.joinToString("\n") + "\n")
        println("evidence: ${out.absolutePath}\n" + summary.joinToString("\n"))
        assertNull(vm.uiState.value.overlay)
    }

    @Test
    fun `the same inputs give the same outcomes as iOS thresholds`() {
        val images = com.lightlylabs.lightly.signatures.SignatureImages
        assertTrue(images.importSignature(inkPhoto()) is com.lightlylabs.lightly.signatures.SignatureImages.ImportResult.InkFound)
        assertTrue(images.importSignature(lowContrastPhoto()) is com.lightlylabs.lightly.signatures.SignatureImages.ImportResult.AsIs)
        assertEquals(com.lightlylabs.lightly.signatures.SignatureImages.ImportResult.Blank, images.importSignature(blankPhoto()))
        assertEquals(com.lightlylabs.lightly.signatures.SignatureImages.ImportResult.Unreadable, images.importSignature(null))
    }
}
