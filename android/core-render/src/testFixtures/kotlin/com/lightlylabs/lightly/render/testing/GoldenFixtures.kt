package com.lightlylabs.lightly.render.testing

import com.lightlylabs.lightly.render.image.Rgba8Image
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.imageio.ImageIO
import kotlin.test.fail

/**
 * Access to the golden set produced by `experiments/lut3d/reference/make_golden.py`
 * (`<golden>/<stem>/{source.png, input256.f32, fused_lut.f32, reference.png, meta.json}`).
 *
 * The folder is git-ignored (~600 MB), so it is located through the `lightly.goldenDir` system
 * property that the Gradle build sets. A missing or empty folder FAILS the test with instructions:
 * a golden test that silently skips would report green while proving nothing (spec §4.4).
 */
object GoldenFixtures {
    private const val PROPERTY = "lightly.goldenDir"
    private val requiredFiles = listOf("source.png", "input256.f32", "fused_lut.f32", "reference.png", "meta.json")

    private const val HOW_TO_PROVIDE =
        "The golden set is git-ignored (so it is absent in fresh clones and git worktrees): generate it with " +
            "experiments/lut3d/reference/make_golden.py, or point the build at an existing copy with " +
            "./gradlew test -PlightlyGoldenDir=/abs/path/to/experiments/lut3d/golden (or LIGHTLY_GOLDEN_DIR)."

    val root: File by lazy {
        val configured = System.getProperty(PROPERTY)
            ?: fail("System property '$PROPERTY' is not set; run the tests through Gradle (android/build.gradle.kts sets it).")
        val directory = File(configured)
        if (!directory.isDirectory) fail("Golden fixtures not found at '$configured'. $HOW_TO_PROVIDE")
        directory
    }

    /** Every complete golden case, sorted by name. Fails if there are none. */
    val cases: List<GoldenCase> by lazy {
        val found = root.listFiles { file -> file.isDirectory && requiredFiles.all { File(file, it).isFile } }
            .orEmpty()
            .sortedBy { it.name }
            .map(::GoldenCase)
        if (found.isEmpty()) fail("No complete golden cases (${requiredFiles.joinToString()}) under '$root'. $HOW_TO_PROVIDE")
        found
    }

    fun case(stem: String): GoldenCase = cases.firstOrNull { it.stem == stem }
        ?: fail("Golden case '$stem' not found under '$root'; available: ${cases.map { it.stem }}")

    class GoldenCase(val directory: File) {
        val stem: String get() = directory.name

        fun source(): Rgba8Image = readPngAsRgba8(File(directory, "source.png"))

        fun reference(): Rgba8Image = readPngAsRgba8(File(directory, "reference.png"))

        fun fusedLutBytes(): ByteArray = File(directory, "fused_lut.f32").readBytes()

        /** 1×3×256×256 float32 NCHW, the canonical analysis input. */
        fun input256(): FloatArray = readLittleEndianFloats(File(directory, "input256.f32"))

        private val metaText: String by lazy { File(directory, "meta.json").readText() }

        /** `weights_deploy` from meta.json: the weights the fused LUT was built from. */
        fun deployWeights(): FloatArray = readFloatArrayField("weights_deploy")

        fun metaInt(field: String): Int =
            Regex("\"$field\"\\s*:\\s*(-?\\d+)").find(metaText)?.groupValues?.get(1)?.toInt()
                ?: fail("meta.json of $stem has no integer field '$field'")

        // meta.json is flat and machine-written; a regex keeps the fixtures free of a JSON dependency.
        private fun readFloatArrayField(field: String): FloatArray {
            val match = Regex("\"$field\"\\s*:\\s*\\[([^\\]]*)]").find(metaText)
                ?: fail("meta.json of $stem has no array field '$field'")
            return match.groupValues[1].split(',').map { it.trim().toFloat() }.toFloatArray()
        }
    }

    fun readLittleEndianFloats(file: File): FloatArray {
        val bytes = file.readBytes()
        val floats = FloatArray(bytes.size / 4)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(floats)
        return floats
    }

    /**
     * Decodes an 8-bit RGB/RGBA PNG to raw samples. Reads the raster directly so ImageIO applies no
     * colour or gamma conversion: the golden PNGs are already sRGB-encoded values.
     */
    fun readPngAsRgba8(file: File): Rgba8Image {
        val image = ImageIO.read(file) ?: fail("ImageIO could not decode $file")
        val raster = image.raster
        val bands = raster.numBands
        if (bands != 3 && bands != 4) fail("$file has $bands bands; expected 8-bit RGB or RGBA")
        if (image.colorModel.componentSize.any { it != 8 }) fail("$file is not 8 bits per channel")
        val width = image.width
        val height = image.height
        val samples = raster.getPixels(0, 0, width, height, null as IntArray?)
        val rgba = ByteArray(width * height * 4)
        for (pixel in 0 until width * height) {
            val src = pixel * bands
            val dst = pixel * 4
            rgba[dst] = samples[src].toByte()
            rgba[dst + 1] = samples[src + 1].toByte()
            rgba[dst + 2] = samples[src + 2].toByte()
            rgba[dst + 3] = if (bands == 4) samples[src + 3].toByte() else 0xff.toByte()
        }
        return Rgba8Image(width, height, rgba)
    }
}
