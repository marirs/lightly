import CoreGraphics
import XCTest
@testable import Lightly

/// Full-resolution LUT rendering in tiles: identical pixels, bounded memory.
final class TiledLUTRenderTests: XCTestCase {

    private var renderer: MetalLUTRenderer!

    override func setUpWithError() throws {
        renderer = try MetalLUTRenderer()
    }

    /// A non-trivial image: gradients plus per-pixel hash noise, so a tile
    /// placed at the wrong offset (or a seam) cannot go unnoticed.
    private static func syntheticPixels(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let hash = (x &* 73_856_093) ^ (y &* 19_349_663)
                pixels[index] = UInt8((x * 255 / max(width - 1, 1) + (hash & 15)) & 255)
                pixels[index + 1] = UInt8((y * 255 / max(height - 1, 1) + ((hash >> 4) & 15)) & 255)
                pixels[index + 2] = UInt8((hash >> 8) & 255)
            }
        }
        return pixels
    }

    /// Auto-like (out of range) then Look-like passes, as in the editor.
    private let passes: [LUT3D] = [
        LUT3D.lut(dimension: 33) { 1.2 * $0 - SIMD3(repeating: 0.08) },
        LUT3D.lut(dimension: 33) { SIMD3($0.y, $0.z, $0.x) * 0.9 + SIMD3(repeating: 0.05) }
    ]

    func testTiledOutputIsIdenticalToUntiled() throws {
        let width = 2_500, height = 1_700
        let pixels = Self.syntheticPixels(width: width, height: height)

        let untiled = try renderer.apply(passes, toRGBA8: pixels, width: width, height: height, maximumTileSide: 4_096)
        let tiled = try renderer.apply(passes, toRGBA8: pixels, width: width, height: height, maximumTileSide: 512)

        XCTAssertEqual(renderer.lastRenderStatistics?.tileCount, 5 * 4, "2500x1700 in 512 tiles")
        XCTAssertEqual(tiled.count, untiled.count)
        let firstDifference = zip(tiled, untiled).enumerated().first { $0.element.0 != $0.element.1 }
        XCTAssertNil(firstDifference.map { "byte \($0.offset): tiled \($0.element.0) vs untiled \($0.element.1)" })
    }

    /// GPU working memory is bounded by the tile, not the frame.
    func testPeakGPUBufferBytesAreBoundedByTheTile() throws {
        let width = 3_000, height = 2_000, tileSide = 1_024
        let pixels = Self.syntheticPixels(width: width, height: height)

        _ = try renderer.apply(passes, toRGBA8: pixels, width: width, height: height, maximumTileSide: tileSide)
        let statistics = try XCTUnwrap(renderer.lastRenderStatistics)

        let tileArea = tileSide * tileSide
        // rgba8 in + two float4 ping-pong buffers + rgba8 out, per tile.
        let perTileBound = tileArea * (4 + 16 + 16 + 4)
        let lutBound = passes.count * 2 * 33 * 33 * 33 * 16   // texture + staging per LUT
        XCTAssertLessThanOrEqual(statistics.peakBufferBytes, perTileBound + lutBound)
        XCTAssertLessThan(
            statistics.peakBufferBytes, width * height * 16,
            "Peak must not scale with the frame at 16 B/px (\(statistics.peakBufferBytes) bytes)"
        )
    }

    func testDefaultTileIs2048() {
        XCTAssertEqual(MetalLUTRenderer.defaultMaximumTileSide, 2_048)
    }
}
