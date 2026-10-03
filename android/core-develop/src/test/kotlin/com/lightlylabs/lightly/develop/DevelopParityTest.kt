package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.lut.Lut3D
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Recipe → LUT parity against shared/fixtures/look-pack (docs/v1/preset-pack.md › Parity): for each
 * of the 40 parity presets, the 17³ bake, the 24 direct probes, the probes through a 33³ bake, and
 * the recomputed lookVersion. Every case is checked; failures are collected and reported together.
 */
class DevelopParityTest {
    private val golden = LookPackFixtures.golden
    private val model = LookPackFixtures.model
    private val tolerances = golden.getValue("tolerances").jsonObject
    private val lutNodeTolerance = tolerances.getValue("lutNode").jsonPrimitive.double
    private val probeDirectTolerance = tolerances.getValue("probeDirect").jsonPrimitive.double
    private val probeViaLutTolerance = tolerances.getValue("probeViaLut33").jsonPrimitive.double
    private val probes: List<DoubleArray> = golden.getValue("probes").jsonArray.map { p -> p.jsonArray.map { it.jsonPrimitive.double }.toDoubleArray() }
    private val cases = golden.getValue("cases").jsonArray.map { it.jsonObject }

    @Test
    fun `the contract's model constants match their published digest`() {
        assertEquals(golden.getValue("renderingContract").jsonObject.getValue("constantsSha256").jsonPrimitive.content, model.constantsSha256)
    }

    @Test
    fun `all forty parity presets are covered`() {
        assertEquals(40, cases.size)
        assertEquals(40, LookPackFixtures.parityPack.presetCount)
    }

    @Test
    fun `17-cubed bake matches every golden LUT node within tolerance`() {
        val failures = mutableListOf<String>()
        var worst = 0.0
        for (case in cases) {
            val preset = presetOf(case)
            val expected = LookPackFixtures.readLut17(case.getValue("lutFile").jsonPrimitive.content)
            val baked = LutBaker.bake(DevelopGlobal(preset.recipe.global, model), dimension = 17)
            var caseWorst = 0.0
            for (node in 0 until 17 * 17 * 17) for (channel in 0 until 3) {
                caseWorst = maxOf(caseWorst, abs(baked.rgba[node * 4 + channel] - expected[node * 3 + channel]).toDouble())
            }
            worst = maxOf(worst, caseWorst)
            if (caseWorst > lutNodeTolerance) failures += "${preset.id} (${preset.displayName}): worst node ${"%.2e".format(caseWorst)}"
        }
        println("17³ bake worst node difference over ${cases.size} presets: ${"%.3e".format(worst)}")
        if (failures.isNotEmpty()) fail("LUT nodes beyond $lutNodeTolerance:\n" + failures.joinToString("\n"))
    }

    @Test
    fun `direct evaluation matches every golden probe within tolerance`() {
        val failures = mutableListOf<String>()
        var worst = 0.0
        val out = DoubleArray(3)
        for (case in cases) {
            val preset = presetOf(case)
            val stage = DevelopGlobal(preset.recipe.global, model)
            val expected = case.getValue("probesDirect").jsonArray
            probes.forEachIndexed { index, probe ->
                stage.evaluate(probe[0], probe[1], probe[2], out)
                val e = expected[index].jsonArray.map { it.jsonPrimitive.double }
                val diff = (0 until 3).maxOf { abs(out[it] - e[it]) }
                worst = maxOf(worst, diff)
                if (diff > probeDirectTolerance) failures += "${preset.id} probe $index ${probe.toList()}: got ${out.toList()} expected $e"
            }
        }
        println("direct probes worst difference: ${"%.3e".format(worst)}")
        if (failures.isNotEmpty()) fail("Direct probes beyond $probeDirectTolerance:\n" + failures.take(40).joinToString("\n"))
    }

    @Test
    fun `33-cubed bake then trilinear lookup matches the golden probes`() {
        val failures = mutableListOf<String>()
        var worst = 0.0
        val out = FloatArray(3)
        for (case in cases) {
            val preset = presetOf(case)
            val lut = LutBaker.bake(DevelopGlobal(preset.recipe.global, model), dimension = Lut3D.CONTRACT_DIMENSION)
            val expected = case.getValue("probesViaLut33").jsonArray
            probes.forEachIndexed { index, probe ->
                lut.sample(probe[0].toFloat(), probe[1].toFloat(), probe[2].toFloat(), out)
                val e = expected[index].jsonArray.map { it.jsonPrimitive.double }
                val diff = (0 until 3).maxOf { abs(out[it] - e[it]) }
                worst = maxOf(worst, diff)
                if (diff > probeViaLutTolerance) failures += "${preset.id} probe $index: got ${out.toList()} expected $e"
            }
        }
        println("probes via 33³ bake worst difference: ${"%.3e".format(worst)}")
        if (failures.isNotEmpty()) fail("Probes via LUT beyond $probeViaLutTolerance:\n" + failures.take(40).joinToString("\n"))
    }

    @Test
    fun `lookVersion recomputed from each recipe equals the pack's`() {
        for (case in cases) {
            val preset = presetOf(case)
            assertEquals(case.getValue("lookVersion").jsonPrimitive.content, preset.lookVersion, "fixture and manifest disagree for ${preset.id}")
            assertEquals(preset.lookVersion, LookVersion.of(preset.recipeObject, preset.recipeVersion, model, null), "lookVersion of ${preset.id}")
        }
    }

    @Test
    fun `lowbias32 vectors match exactly`() {
        val vectors = golden.getValue("portableRandom").jsonObject.getValue("lowbias32").jsonArray
        for (pair in vectors) {
            val (input, expected) = (pair as JsonArray).map { it.jsonPrimitive.long }
            assertEquals(expected, PortableRandom.toUnsigned(PortableRandom.lowbias32(input.toInt())), "lowbias32($input)")
        }
    }

    @Test
    fun `gaussian field matches within 1e-6`() {
        val field = golden.getValue("portableRandom").jsonObject.getValue("gaussianField").jsonObject
        val rows = field.getValue("rows").jsonPrimitive.int
        val cols = field.getValue("cols").jsonPrimitive.int
        val values = PortableRandom.field(field.getValue("seed").jsonPrimitive.long, field.getValue("layer").jsonPrimitive.int, rows, cols)
        val expected = field.getValue("values").jsonArray.flatMap { row -> row.jsonArray.map { it.jsonPrimitive.double } }
        val tolerance = field.getValue("tolerance").jsonPrimitive.double
        expected.forEachIndexed { index, value -> assertTrue(abs(values[index] - value) <= tolerance, "field[$index] ${values[index]} vs $value") }
    }

    private fun presetOf(case: kotlinx.serialization.json.JsonObject): LookPreset {
        val id = case.getValue("presetId").jsonPrimitive.content
        return LookPackFixtures.parityPack.preset(id) ?: fail("$id missing from manifest-parity.json")
    }
}
