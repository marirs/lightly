import CoreGraphics
import ImageIO
import simd
import XCTest
@testable import Lightly

/// CPU port of `apply_lut_reference` (experiments/lut3d/reference/ia3dlut.py)
/// with the contract's stage-input clamp, used as the oracle.
private enum ReferenceLUT {
    static func apply(_ lut: LUT3D, to colour: SIMD3<Float>) -> SIMD3<Float> {
        let n = lut.dimension
        let x = simd_clamp(colour, SIMD3(repeating: 0), SIMD3(repeating: 1))
        let position = x * Float(n - 1)
        func cellIndex(_ value: Float) -> Int { min(max(Int(value.rounded(FloatingPointRoundingRule.down)), 0), n - 2) }
        let cell = SIMD3<Int>(cellIndex(position.x), cellIndex(position.y), cellIndex(position.z))
        let frac = position - SIMD3<Float>(Float(cell.x), Float(cell.y), Float(cell.z))
        var result = SIMD3<Float>(repeating: 0)
        for dr in 0..<2 {
            let wr: Float = dr == 1 ? frac.x : 1 - frac.x
            for dg in 0..<2 {
                let wg: Float = dg == 1 ? frac.y : 1 - frac.y
                for db in 0..<2 {
                    let wb: Float = db == 1 ? frac.z : 1 - frac.z
                    let texel: Int = (cell.x + dr) + (cell.y + dg) * n + (cell.z + db) * n * n
                    let index = texel * 4
                    let entry = SIMD3<Float>(lut.values[index], lut.values[index + 1], lut.values[index + 2])
                    result += (wr * wg * wb) * entry
                }
            }
        }
        return result
    }
}

/// The GPU LUT stage against the contract (spec §4.1, §4.2, §4.4).
final class MetalLUTRendererTests: XCTestCase {

    private var renderer: MetalLUTRenderer!

    override func setUpWithError() throws {
        renderer = try MetalLUTRenderer()
    }

    /// f(g) = 2g − 0.52 per channel: entries run from −0.52 to 1.48, and the
    /// grid nodes either side of 0.765625 are 0.98 and 1.0425, so a renderer
    /// that clamped entries to [0,1] would interpolate to 0.99 instead of
    /// 1.01125 there.
    private let stretch = LUT3D.lut(dimension: 33) { 2 * $0 - SIMD3(repeating: 0.52) }

    private func pixels(_ colours: [SIMD3<UInt8>]) -> [UInt8] {
        colours.flatMap { [$0.x, $0.y, $0.z, 255] }
    }

    // MARK: - Out-of-range entries

    func testOutOfRangeLUTEntriesAreNotClampedByStorage() throws {
        // 0.765625·255 is not an integer, so feed the float midpoint via a
        // LUT-friendly 8-bit value and compare against the CPU oracle.
        let inputs: [SIMD3<UInt8>] = [SIMD3(195, 195, 195), SIMD3(10, 10, 10), SIMD3(255, 0, 128)]
        let output = try renderer.applyUnencoded([stretch], toRGBA8: pixels(inputs), width: inputs.count, height: 1)

        for (input, result) in zip(inputs, output) {
            let expected = ReferenceLUT.apply(stretch, to: SIMD3<Float>(input) / 255)
            XCTAssertEqual(result.x, expected.x, accuracy: 1e-5)
            XCTAssertEqual(result.y, expected.y, accuracy: 1e-5)
            XCTAssertEqual(result.z, expected.z, accuracy: 1e-5)
        }
        XCTAssertGreaterThan(output[0].x, 1.0, "Above-range output must survive (195/255 → ~1.009)")
        XCTAssertLessThan(output[1].x, 0.0, "Below-range output must survive (10/255 → ~−0.44)")
        XCTAssertGreaterThan(output[2].x, 1.4)
    }

    /// Interpolating between an in-range and an out-of-range entry: clamped
    /// 8-bit entries would give 0.99 here; float entries give 1.01125.
    func testInterpolationUsesUnclampedNeighbours() throws {
        let x = Float(24.5) / 32
        let expected = ReferenceLUT.apply(stretch, to: SIMD3(repeating: x))
        XCTAssertEqual(expected.x, 2 * x - 0.52, accuracy: 1e-6, "Oracle sanity: the stretch is linear")
        XCTAssertGreaterThan(expected.x, 1.0)

        // 8-bit inputs cannot hit x exactly; the nearest code (195) still
        // lies between nodes 24 and 25, so the same argument holds.
        let output = try renderer.applyUnencoded([stretch], toRGBA8: pixels([SIMD3(195, 195, 195)]), width: 1, height: 1)
        XCTAssertGreaterThan(output[0].x, 1.0)
    }

    // MARK: - Two passes

    /// §4.1/§4.2: Auto then Look, each clamping its input. With Look =
    /// identity the result is clamp(Auto(x)), not Auto(x).
    func testSecondPassClampsItsInput() throws {
        let output = try renderer.applyUnencoded(
            [stretch, .identity()], toRGBA8: pixels([SIMD3(195, 195, 195), SIMD3(10, 10, 10)]), width: 2, height: 1
        )
        XCTAssertEqual(output[0].x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(output[1].x, 0.0, accuracy: 1e-6)
    }

    func testTwoPassesMatchTheCPUReferenceOnRandomColours() throws {
        let look = LUT3D.lut(dimension: 33) { g in
            let curved = SIMD3<Float>(powf(g.x, 1.1), powf(g.y, 1.1), powf(g.z, 1.1))
            return curved + SIMD3(0.04, 0, -0.04) * (curved.sum() / 3 - 0.4)
        }
        var generator = SystemRandomNumberGenerator()
        let inputs = (0..<4096).map { _ in
            SIMD3<UInt8>(UInt8.random(in: 0...255, using: &generator), UInt8.random(in: 0...255, using: &generator), UInt8.random(in: 0...255, using: &generator))
        }
        let output = try renderer.applyUnencoded([stretch, look], toRGBA8: pixels(inputs), width: inputs.count, height: 1)

        var worst: Float = 0
        for (input, result) in zip(inputs, output) {
            let expected = ReferenceLUT.apply(look, to: ReferenceLUT.apply(stretch, to: SIMD3<Float>(input) / 255))
            worst = max(worst, simd_reduce_max(simd_abs(SIMD3(result.x, result.y, result.z) - expected)))
        }
        XCTAssertLessThan(worst, 1e-5, "GPU two-pass must match the float reference")
    }

    /// Spec §4.1 forbids baking by default; this documents why the renderer
    /// takes a list of passes: the baked LUT is measurably different.
    func testTwoPassesDifferFromABakedLUT() throws {
        let identity = LUT3D.identity()
        let stretch = self.stretch
        let baked = LUT3D.lut(dimension: 33) { ReferenceLUT.apply(identity, to: ReferenceLUT.apply(stretch, to: $0)) }
        let input = pixels([SIMD3(195, 100, 30)])
        let twoPass = try renderer.applyUnencoded([stretch, .identity()], toRGBA8: input, width: 1, height: 1)[0]
        let onePass = try renderer.applyUnencoded([baked], toRGBA8: input, width: 1, height: 1)[0]
        XCTAssertGreaterThan(abs(twoPass.x - onePass.x) + abs(twoPass.y - onePass.y) + abs(twoPass.z - onePass.z), 1e-4)
    }

    func testStrengthBlendIsLinearTowardIdentity() {
        let half = stretch.blendedTowardIdentity(strength: 0.5)
        let index = (24 + 24 * 33 + 24 * 33 * 33) * 4
        let identity: Float = 24.0 / 32
        XCTAssertEqual(half.values[index], identity + 0.5 * (stretch.values[index] - identity), accuracy: 1e-6)
        XCTAssertEqual(stretch.blendedTowardIdentity(strength: 0).values, LUT3D.identity().values)
    }

    // MARK: - Encode

    func testEncodeClampsOnceAndRoundsLikeTheReference() throws {
        let output = try renderer.apply([stretch], toRGBA8: pixels([SIMD3(195, 10, 128)]), width: 1, height: 1)
        let expected = ReferenceLUT.apply(stretch, to: SIMD3<Float>(195, 10, 128) / 255)
        func encode(_ value: Float) -> UInt8 { UInt8(min(max(value * 255 + 0.5, 0), 255)) }
        XCTAssertEqual(Array(output.prefix(3)), [encode(expected.x), encode(expected.y), encode(expected.z)])
    }
}
