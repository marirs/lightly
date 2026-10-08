import Foundation
import XCTest
@testable import Lightly

/// Checks for 9fa7f16 (each MetalLUTRenderer call drains its own autoreleased Metal objects), 2026-10-08:
/// - output is unchanged across tile boundaries for the effects Save copy runs (the LUT on the GPU in 2,048 px tiles, the
///   spatial and finishing stages on the CPU in 1,024 px tiles with a halo), using the preset of the export measurement,
///   Landscape · Hiking 5;
/// - GPU workspaces are returned after every call made off the main thread, including calls that fail and renders that
///   are cancelled part-way, and the renderer keeps working afterwards (its lock is released).
/// Every command buffer is committed and waited for (`waitUntilCompleted`) inside the call, so the pool never drains
/// objects the GPU is still using; these tests check the observable consequences.
final class GPUResourceReleaseTests: XCTestCase {

    /// A photo-like frame: smooth gradients with fine hash detail, so sharpening, texture and noise reduction all have
    /// something to act on and a misplaced tile or a seam changes bytes.
    private static func syntheticFrame(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    let hash = (x &* 73_856_093) ^ (y &* 19_349_663)
                    base[index] = UInt8(truncatingIfNeeded: x * 200 / width + 20 + (hash & 15))
                    base[index + 1] = UInt8(truncatingIfNeeded: y * 180 / height + 30 + ((hash >> 4) & 15))
                    base[index + 2] = UInt8(truncatingIfNeeded: (x + y) * 160 / (width + height) + 40 + ((hash >> 8) & 31))
                }
            }
        }
        return pixels
    }

    private struct Difference: CustomStringConvertible {
        var differingBytes = 0
        var worst = 0
        var firstOffset: Int?
        var description: String { "\(differingBytes) bytes differ, worst \(worst), first at \(firstOffset.map(String.init) ?? "-")" }
    }

    private static func compare(_ a: [UInt8], _ b: [UInt8]) -> Difference {
        var difference = Difference()
        for index in 0..<min(a.count, b.count) where a[index] != b[index] {
            difference.differingBytes += 1
            difference.worst = max(difference.worst, abs(Int(a[index]) - Int(b[index])))
            if difference.firstOffset == nil { difference.firstOffset = index }
        }
        return difference
    }

    @MainActor
    private func hikingFivePlan() async throws -> (DevelopRenderPlan, DevelopFrameRenderer) {
        let library = DevelopLibrary()
        await library.loadBundled(lutApplier: try MetalLUTRenderer())
        let presetID = try XCTUnwrap(DevelopPresetCatalogue.loadBundled().preset(inCategory: "landscape", atStop: 37)?.id)
        let preset = try XCTUnwrap(library.pack.preset(id: presetID))
        let plan = DevelopRenderPlan.look(preset, strength: 1, cache: try XCTUnwrap(library.cache))
        XCTAssertTrue(plan.hasPixelStages, "Hiking 5 must exercise the tiled spatial and finishing stages")
        return (plan, try XCTUnwrap(library.renderer))
    }

    // MARK: - Tile boundaries

    /// 2,100 × 1,200 crosses the GPU's 2,048 px tiles once, and the CPU stages' tiles
    /// many times. The whole-frame CPU region (one tile) still renders its LUT in GPU tiles, so the three renders put
    /// the boundaries in different places.
    func testHikingFiveIsUnchangedAcrossTileBoundaries() async throws {
        let (plan, renderer) = try await hikingFivePlan()
        let width = 2_100, height = 1_200
        let pixels = Self.syntheticFrame(width: width, height: height)

        let wholeFrameRegion = try renderer.render(plan, pixels: pixels, width: width, height: height, tileSide: 8_192)
        let exportTiles = try renderer.render(plan, pixels: pixels, width: width, height: height)
        let oddTiles = try renderer.render(plan, pixels: pixels, width: width, height: height, tileSide: 500)

        let exportDifference = Self.compare(wholeFrameRegion, exportTiles)
        let oddDifference = Self.compare(wholeFrameRegion, oddTiles)
        print("TILE BOUNDARY Hiking 5 \(width)x\(height): export tiles vs whole frame: \(exportDifference); 500 px tiles vs whole frame: \(oddDifference)")
        XCTAssertEqual(exportDifference.differingBytes, 0, "\(exportDifference)")
        XCTAssertEqual(oddDifference.differingBytes, 0, "\(oddDifference)")
    }

    /// The LUT stage alone (what Auto and Looks without spatial operators run): GPU tiles versus one GPU tile.
    func testHikingFiveLUTIsUnchangedAcrossGPUTileBoundaries() async throws {
        let (plan, _) = try await hikingFivePlan()
        let lut = try XCTUnwrap(plan.lookLUT)
        let renderer = try MetalLUTRenderer()
        let width = 2_100, height = 1_200
        let pixels = Self.syntheticFrame(width: width, height: height)

        let oneTile = try renderer.apply([lut], toRGBA8: pixels, width: width, height: height, maximumTileSide: 8_192)
        let tiled = try renderer.apply([lut], toRGBA8: pixels, width: width, height: height)
        XCTAssertEqual(renderer.lastRenderStatistics?.tileCount, 2)
        let difference = Self.compare(oneTile, tiled)
        print("TILE BOUNDARY Hiking 5 LUT \(width)x\(height): \(difference)")
        XCTAssertEqual(difference.differingBytes, 0, "\(difference)")
    }

    // MARK: - Release

    /// Growth in this process's footprint after `body` ran on a detached task, which, like Save copy, has no
    /// autorelease pool drained by a run loop.
    private static func footprintGrowthMB(of body: @escaping @Sendable () throws -> Void) async throws -> Int {
        let before = try XCTUnwrap(SaveTiming.currentFootprintMB())
        try await Task.detached { try body() }.value
        let after = try XCTUnwrap(SaveTiming.currentFootprintMB())
        return after - before
    }

    /// Ten 12 MP renders in a row off the main thread. Each call allocates about 170 MB of GPU workspace (2,048² tile);
    /// measured 2026-10-08 in the Simulator (optimised build): growth 297 MB before 9fa7f16, 0 MB after.
    func testRepeatedRendersOffTheMainThreadReturnTheirWorkspace() async throws {
        let renderer = try MetalLUTRenderer()
        let width = 4_000, height = 3_000
        let pixels = Self.syntheticFrame(width: width, height: height)
        let lut = LUT3D.lut(dimension: 33) { SIMD3($0.y, $0.z, $0.x) }
        _ = try renderer.apply([lut], toRGBA8: pixels, width: width, height: height)   // warm-up: pipelines, caches

        let growth = try await Self.footprintGrowthMB {
            for _ in 0..<10 { _ = try renderer.apply([lut], toRGBA8: pixels, width: width, height: height) }
        }
        print("GPU RELEASE 10 renders off the main thread: footprint growth \(growth) MB")
        XCTAssertLessThan(growth, 100, "Each render's GPU workspace must be returned when the call ends")
    }

    /// A failing call (here a size mismatch) releases the render lock, and later calls work and match a fresh renderer.
    func testAFailedCallLeavesTheRendererUsable() async throws {
        let renderer = try MetalLUTRenderer()
        let width = 1_500, height = 1_000
        let pixels = Self.syntheticFrame(width: width, height: height)
        let lut = LUT3D.lut(dimension: 33) { 1.1 * $0 - SIMD3(repeating: 0.05) }

        let finished = expectation(description: "renders after failures finish (no lock left held)")
        Task.detached {
            for _ in 0..<5 {
                XCTAssertThrowsError(try renderer.apply([lut], toRGBA8: [UInt8](pixels.dropLast(4)), width: width, height: height))
                XCTAssertThrowsError(try renderer.applyUnencoded([lut], toRGBA8: [UInt8](pixels.dropLast(4)), width: width, height: height))
            }
            let afterFailures = try? renderer.apply([lut], toRGBA8: pixels, width: width, height: height)
            let fresh = try? MetalLUTRenderer().apply([lut], toRGBA8: pixels, width: width, height: height)
            XCTAssertNotNil(afterFailures)
            XCTAssertEqual(afterFailures, fresh)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 60)
    }

    /// Forwards to Metal and cancels the calling task after `cancelAfterCalls` GPU calls, so a render is cancelled with
    /// GPU work done and more to come, as Save copy › Cancel does mid-export.
    private final class CancellingApplier: DevelopLUTApplying, @unchecked Sendable {
        let metal: MetalLUTRenderer
        let cancelAfterCalls: Int
        private let lock = NSLock()
        private var calls = 0
        init(metal: MetalLUTRenderer, cancelAfterCalls: Int) { self.metal = metal; self.cancelAfterCalls = cancelAfterCalls }

        func apply(_ passes: [LUT3D], toRGBA8 pixels: [UInt8], width: Int, height: Int, maximumTileSide: Int) throws -> [UInt8] {
            defer { countCall() }
            return try metal.apply(passes, toRGBA8: pixels, width: width, height: height, maximumTileSide: maximumTileSide)
        }
        func applyUnencoded(_ passes: [LUT3D], toRGBA8 pixels: [UInt8], width: Int, height: Int) throws -> [SIMD4<Float>] {
            defer { countCall() }
            return try metal.applyUnencoded(passes, toRGBA8: pixels, width: width, height: height)
        }
        func reset() { lock.withLock { calls = 0 } }
        private func countCall() {
            let reached = lock.withLock { calls += 1; return calls == cancelAfterCalls }
            if reached { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }

    /// Hiking 5 renders cancelled after three tiles, five times over: each throws CancellationError, the memory comes
    /// back, and the next complete render matches one that was never interrupted.
    func testCancelledRendersReleaseTheirWorkAndLeaveNoState() async throws {
        let (plan, reference) = try await hikingFivePlan()
        let applier = CancellingApplier(metal: try MetalLUTRenderer(), cancelAfterCalls: 3)
        let renderer = DevelopFrameRenderer(lutApplier: applier, model: reference.model)
        let width = 2_100, height = 1_200
        let pixels = Self.syntheticFrame(width: width, height: height)
        let uninterrupted = try reference.render(plan, pixels: pixels, width: width, height: height)

        let growth = try await Self.footprintGrowthMB {
            for _ in 0..<5 {
                applier.reset()
                XCTAssertThrowsError(try renderer.render(plan, pixels: pixels, width: width, height: height)) { error in
                    XCTAssertTrue(error is CancellationError, "\(error)")
                }
            }
        }
        print("GPU RELEASE 5 cancelled Hiking 5 renders: footprint growth \(growth) MB")
        XCTAssertLessThan(growth, 250)

        let afterCancellations = try DevelopFrameRenderer(lutApplier: applier.metal, model: reference.model)
            .render(plan, pixels: pixels, width: width, height: height)
        XCTAssertEqual(Self.compare(afterCancellations, uninterrupted).differingBytes, 0)
    }
}
