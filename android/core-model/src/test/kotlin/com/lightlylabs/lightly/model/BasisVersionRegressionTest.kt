package com.lightlylabs.lightly.model

import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.CpuLutRenderer
import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.render.testing.SyntheticLuts
import com.lightlylabs.lightly.session.AutoGuardrail
import com.lightlylabs.lightly.session.AutoResult
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs

/**
 * Codex M2 finding 4: a saved edit must re-render with the basis of the model version that produced
 * its weights, or report Auto as unavailable. Never with whichever basis happens to be installed.
 */
class BasisVersionRegressionTest {

    @get:Rule
    val temporaryFolder = TemporaryFolder()

    private val basisV1 = BasisLuts(listOf(SyntheticLuts.strongLook(), Lut3D.identity(), SyntheticLuts.outOfRangeAuto()))
    private val basisV2 = BasisLuts(listOf(SyntheticLuts.outOfRangeAuto(), SyntheticLuts.strongLook(), Lut3D.identity()))
    private val weights = listOf(0.7f, 0.2f, 0.1f)

    private fun saved(version: String) = AutoResult("ia3dlut", version, weights, AutoGuardrail.ENDPOINT_V1, 1f)

    private fun bytesOf(basis: BasisLuts): ByteArray {
        val buffer = ByteBuffer.allocate(basis.luts.size * Lut3D.floatCount(basis.dimension) * 4).order(ByteOrder.LITTLE_ENDIAN)
        basis.luts.forEach { lut -> lut.rgba.forEach(buffer::putFloat) }
        return buffer.array()
    }

    /** Writes the basis file and registers it with the sha256 of the bytes as written (the manifest value). */
    private fun install(version: String, basis: BasisLuts): Pair<InstalledBasis, File> {
        val file = temporaryFolder.newFile("basis_$version.bin")
        val bytes = bytesOf(basis)
        file.writeBytes(bytes)
        return InstalledBasis.fromFile(ModelKey("ia3dlut", version), file, BasisRegistry.sha256Hex(bytes)) to file
    }

    private fun expectedLut(basis: BasisLuts) = AutoGuardrails.apply(AutoGuardrail.ENDPOINT_V1, basis.fuse(weights.toFloatArray()))

    private val photo = Rgba8Image(64, 64, ByteArray(64 * 64 * 4).also { Random(3).nextBytes(it) })

    @Test
    fun `with two bases installed each saved edit renders with its own basis`() {
        val resolver = RegistryAutoLutResolver(BasisRegistry(listOf(install("v1", basisV1).first, install("v2", basisV2).first)))

        val v1 = assertIs<AutoLutResolution.Ready>(resolver.resolve(saved("v1")))
        val v2 = assertIs<AutoLutResolution.Ready>(resolver.resolve(saved("v2")))

        assertContentEquals(expectedLut(basisV1).rgba, v1.lut.rgba)
        assertContentEquals(expectedLut(basisV2).rgba, v2.lut.rgba)
        val pixelsV1 = CpuLutRenderer.apply(photo, v1.lut).pixels
        val pixelsV2 = CpuLutRenderer.apply(photo, v2.lut).pixels
        assertContentEquals(CpuLutRenderer.apply(photo, expectedLut(basisV1)).pixels, pixelsV1)
        assertContentEquals(CpuLutRenderer.apply(photo, expectedLut(basisV2)).pixels, pixelsV2)
        assertFalse(pixelsV1.contentEquals(pixelsV2), "same weights, different bases must look different, or the test proves nothing")
    }

    @Test
    fun `restoring a v1 edit with only v2 installed is explicitly unavailable`() {
        val resolver = RegistryAutoLutResolver(BasisRegistry(listOf(install("v2", basisV2).first)))

        val resolution = resolver.resolve(saved("v1"))

        assertEquals(AutoLutResolution.AutoUnavailable("ia3dlut", "v1", BasisUnavailableReason.NotInstalled), resolution)
    }

    @Test
    fun `a tampered basis file is rejected by its sha256`() {
        val (entry, file) = install("v1", basisV1)
        val tampered = file.readBytes().also { it[1234] = (it[1234] + 1).toByte() }
        file.writeBytes(tampered)

        val resolution = RegistryAutoLutResolver(BasisRegistry(listOf(entry))).resolve(saved("v1"))

        val unavailable = assertIs<AutoLutResolution.AutoUnavailable>(resolution)
        val mismatch = assertIs<BasisUnavailableReason.HashMismatch>(unavailable.reason)
        assertEquals(entry.expectedSha256, mismatch.expectedSha256)
        assertEquals(BasisRegistry.sha256Hex(tampered), mismatch.actualSha256)
    }

    @Test
    fun `a model id mismatch is not resolved by version alone`() {
        val resolver = RegistryAutoLutResolver(BasisRegistry(listOf(install("v1", basisV1).first)))
        val otherFamily = saved("v1").copy(modelId = "other-model")
        assertIs<AutoLutResolution.AutoUnavailable>(resolver.resolve(otherFamily))
    }
}
