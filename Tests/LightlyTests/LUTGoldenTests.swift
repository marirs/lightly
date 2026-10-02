import CoreGraphics
import ImageIO
import XCTest
@testable import Lightly

/// GPU LUT application against the desktop golden references (spec §4.4).
///
/// Each golden case holds `source.png` (oriented 8-bit sRGB), `fused_lut.f32`
/// (33³ RGBA float32) and `reference.png` (exact-grid trilinear, reference
/// rounding). Target: max |Δ| ≤ 1/255 (CIColorCube measured 5/255).
///
/// The golden set is git-ignored (large binaries). Lookup order:
/// `LIGHTLY_GOLDEN_DIR` (set `TEST_RUNNER_LIGHTLY_GOLDEN_DIR` for
/// xcodebuild), then this checkout's `experiments/lut3d/golden`, then — when
/// running from a `.claude/worktrees/<name>` worktree, which does not carry the
/// ignored files — the main checkout that contains it.
final class LUTGoldenTests: XCTestCase {

    private static let maximumAllowedDifference = 1

    private static var candidateDirectories: [URL] {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["LIGHTLY_GOLDEN_DIR"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repositoryRoot.appendingPathComponent("experiments/lut3d/golden"))
        // Worktrees live at <main checkout>/.claude/worktrees/<name> and lack the ignored files; fall back to the
        // main checkout derived from that layout (no machine-specific path).
        let path = repositoryRoot.path
        if let range = path.range(of: "/.claude/worktrees/") {
            candidates.append(URL(fileURLWithPath: String(path[..<range.lowerBound])).appendingPathComponent("experiments/lut3d/golden"))
        }
        return candidates
    }

    private static func goldenCases() throws -> [URL] {
        for directory in candidateDirectories {
            let cases = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ))?.filter {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("fused_lut.f32").path)
            } ?? []
            if !cases.isEmpty { return cases.sorted { $0.lastPathComponent < $1.lastPathComponent } }
        }
        let searched = candidateDirectories.map(\.path).joined(separator: ", ")
        XCTFail("""
        LUT golden set not found (searched: \(searched)). It is git-ignored; generate it with \
        experiments/lut3d/reference/make_golden.py or set LIGHTLY_GOLDEN_DIR.
        """)
        return []
    }

    /// Reads PNG bytes as sRGB values without colour conversion: the golden
    /// files are sRGB by contract but may carry no profile, and a conversion
    /// from an assumed space would corrupt the comparison.
    private static func sRGBBytes(of url: URL) throws -> (pixels: [UInt8], width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let retagged = decoded.copy(colorSpace: ColorPipeline.sRGB) else {
            throw LUTError.renderFailed("cannot decode \(url.lastPathComponent)")
        }
        return (try MetalLUTRenderer.rgba8Bytes(of: retagged), retagged.width, retagged.height)
    }

    func testGoldenCasesMatchTheReferenceWithinOneLevel() throws {
        let renderer = try MetalLUTRenderer()
        let cases = try Self.goldenCases()
        var summary: [String] = []

        for directory in cases {
            try autoreleasepool {
                let name = directory.lastPathComponent
                let lut = try LUT3D(contentsOf: directory.appendingPathComponent("fused_lut.f32"))
                let source = try Self.sRGBBytes(of: directory.appendingPathComponent("source.png"))
                let reference = try Self.sRGBBytes(of: directory.appendingPathComponent("reference.png"))
                XCTAssertEqual(source.width, reference.width, name)
                XCTAssertEqual(source.height, reference.height, name)

                let output = try renderer.apply([lut], toRGBA8: source.pixels, width: source.width, height: source.height)
                let stats = Self.difference(output, reference.pixels)
                summary.append("\(name) \(source.width)x\(source.height): max \(stats.maximum)/255, >1: \(stats.overOne)")
                XCTAssertLessThanOrEqual(stats.maximum, Self.maximumAllowedDifference, "\(name): max |Δ| \(stats.maximum)/255")
            }
        }
        XCTAssertGreaterThan(cases.count, 0)
        print("LUT golden results:\n" + summary.joined(separator: "\n"))
    }

    private static func difference(_ lhs: [UInt8], _ rhs: [UInt8]) -> (maximum: Int, overOne: Int) {
        var maximum = 0, overOne = 0
        for index in stride(from: 0, to: min(lhs.count, rhs.count), by: 4) {
            var pixelMax = 0
            for channel in 0..<3 {
                pixelMax = max(pixelMax, abs(Int(lhs[index + channel]) - Int(rhs[index + channel])))
            }
            maximum = max(maximum, pixelMax)
            if pixelMax > 1 { overOne += 1 }
        }
        return (maximum, overOne)
    }
}
