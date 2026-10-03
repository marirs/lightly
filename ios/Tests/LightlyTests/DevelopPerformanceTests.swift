import Foundation
import XCTest
@testable import Lightly

/// Simulator performance evidence for docs/v1/slice2-ios.md (device numbers stay pending):
/// - 33³ bake: median ≤ 16 ms, p95 ≤ 33 ms;
/// - manifest parse + index of the bundled pack ≤ 300 ms.
/// Timings are asserted only in optimised builds (`SWIFT_OPTIMIZATION_LEVEL=-O`); an unoptimised
/// test build prints them and skips the assertion.
final class DevelopPerformanceTests: XCTestCase {

    private func percentile(_ values: [Duration], _ p: Double) -> Duration {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    private func ms(_ d: Duration) -> String {
        String(format: "%.2f ms", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
    }

    @MainActor
    func testBakeTimeOverTheParityPresets() throws {
        let model = try EditorTestSupport.model()
        let pack = try EditorTestSupport.parityPack(model: model)
        let presets = pack.categories.flatMap(\.presets)
        let clock = ContinuousClock()
        var durations: [Duration] = []
        for _ in 0..<3 {
            for preset in presets {
                let program = DevelopGlobalProgram(recipe: preset.recipe.global, model: model)
                let start = clock.now
                _ = program.bakeLUT()
                durations.append(clock.now - start)
            }
        }
        let median = percentile(durations, 0.5), p95 = percentile(durations, 0.95)
        print("BAKE 33³ median \(ms(median)), p95 \(ms(p95)), max \(ms(durations.max()!)) over \(durations.count) bakes, "
              + "optimised: \(!_isDebugAssertConfiguration()), cores: \(ProcessInfo.processInfo.activeProcessorCount)")
        try XCTSkipIf(_isDebugAssertConfiguration(), "Unoptimised build: bake time recorded, not asserted")
        XCTAssertLessThanOrEqual(median, .milliseconds(16))
        XCTAssertLessThanOrEqual(p95, .milliseconds(33))
    }

    /// The full catalogue as bundled in this build: format 3, all 2,591 presets, nothing dropped,
    /// the approved catalogue's categories in order, parsed within the target.
    func testBundledPackIsTheFullFormatThreeCatalogue() throws {
        let model = try DevelopModel.loadBundled()
        let result = PresetPackLoader.loadBundled(model: model)
        // A build without the pack (shared/look-pack/out not built) fails here: it must not be installed.
        XCTAssertNil(result.problem, result.problem?.explanation ?? "")
        XCTAssertEqual(result.droppedPresets, [])
        XCTAssertEqual(result.pack.presetCount, 2_591)
        let catalogue = DevelopPresetCatalogue.loadBundled()
        XCTAssertEqual(result.pack.categories.map(\.id), catalogue.categories.map(\.id))
        XCTAssertEqual(result.pack.categories.map(\.name), catalogue.categories.map(\.name))
        XCTAssertEqual(result.pack.categories.map { $0.presets.map(\.id) }, catalogue.categories.map { $0.presets.map(\.id) })
        XCTAssertEqual(result.pack.categories.map { $0.presets.map(\.displayName) }, catalogue.categories.map { $0.presets.map(\.displayName) })
        print("PACK parse+index \(ms(result.parseDuration)), optimised: \(!_isDebugAssertConfiguration())")
        try XCTSkipIf(_isDebugAssertConfiguration(), "Unoptimised build: parse time recorded, not asserted")
        XCTAssertLessThanOrEqual(result.parseDuration, .milliseconds(300))
    }

    /// The bundled contract is the repository's, byte for byte.
    func testBundledRenderingContractIsTheSharedOne() throws {
        let bundled = try Data(contentsOf: try XCTUnwrap(Bundle.main.url(forResource: "rendering-v2", withExtension: "json")))
        let shared = try Data(contentsOf: DevelopParityTests.fixture("shared/contracts/rendering-v2.json"))
        XCTAssertEqual(bundled, shared)
    }
}

/// Where a preview frame's time goes at the default preview size (1600 px long edge).
final class PreviewFrameTimingTests: XCTestCase {
    @MainActor
    func testPreviewFrameTiming() throws {
        let model = try EditorTestSupport.model()
        let pack = try EditorTestSupport.parityPack(model: model)
        let metal = try MetalLUTRenderer()
        let renderer = DevelopFrameRenderer(lutApplier: metal, model: model)
        let cache = DevelopLUTCache(model: model)
        let image = TestFixtures.makeImage(width: 1_600, height: 1_067)
        let pixels = try MetalLUTRenderer.rgba8Bytes(of: image)
        let presets = pack.categories.flatMap(\.presets)
        let clock = ContinuousClock()
        var global: [Duration] = [], full: [Duration] = [], wrap: [Duration] = []
        for preset in presets.prefix(12) {
            let plan = DevelopRenderPlan.look(preset, strength: 1, cache: cache)
            var start = clock.now
            let out = try renderer.render(plan, pixels: pixels, width: 1_600, height: 1_067, includePixelStages: false)
            global.append(clock.now - start)
            start = clock.now
            _ = try MetalLUTRenderer.makeImage(rgba8: out, width: 1_600, height: 1_067)
            wrap.append(clock.now - start)
            start = clock.now
            _ = try renderer.render(plan, pixels: pixels, width: 1_600, height: 1_067, includePixelStages: true)
            full.append(clock.now - start)
        }
        func median(_ d: [Duration]) -> Duration { d.sorted()[d.count / 2] }
        print("FRAME 1600px global median \(median(global)) max \(global.max()!), image wrap \(median(wrap)), full median \(median(full)) max \(full.max()!)")
    }
}
