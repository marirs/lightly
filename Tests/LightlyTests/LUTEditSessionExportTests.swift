import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Lightly

/// Save copy from the LUT pipeline: what was previewed is what is saved.
@MainActor
final class LUTEditSessionExportTests: XCTestCase {

    private var metal: MetalLUTRenderer!
    private let previewLongEdge = 400

    override func setUpWithError() throws {
        metal = try MetalLUTRenderer()
    }

    private func makeSession() throws -> LUTEditSession {
        try LUTEditSession(
            photo: LUTEditSessionTests.makePhoto(),
            autoEnhancer: BasisAutoEnhancer(basis: [.identity(), .lut(dimension: 33) { 1.3 * $0 - SIMD3(repeating: 0.1) }]) { _ in [0.5, 0.5] },
            lookBook: TestLookBook.book, renderer: metal, previewLongEdge: previewLongEdge
        )
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Mean and 99th-percentile absolute channel difference, in 1/255 units.
    private func difference(_ lhs: [UInt8], _ rhs: [UInt8]) -> (mean: Double, p99: Int) {
        var histogram = [Int](repeating: 0, count: 256)
        var total = 0, count = 0
        for index in stride(from: 0, to: min(lhs.count, rhs.count), by: 4) {
            for channel in 0..<3 {
                let delta = abs(Int(lhs[index + channel]) - Int(rhs[index + channel]))
                histogram[delta] += 1
                total += delta
                count += 1
            }
        }
        var cumulative = 0, p99 = 0
        for (delta, n) in histogram.enumerated() {
            cumulative += n
            if Double(cumulative) >= 0.99 * Double(count) { p99 = delta; break }
        }
        return (Double(total) / Double(count), p99)
    }

    /// The same EditState exported at full resolution and downsampled to
    /// the preview's size matches the preview.
    func testExportDownsampledMatchesThePreview() async throws {
        let session = try makeSession()
        await session.prepareAuto()
        session.setAutoStrength(0.8)
        session.applyLook(id: TestLookBook.warm.id, strength: 0.7)
        await session.settleRendering()

        let jpeg = try await session.exportData()
        let exported = try decode(jpeg)
        XCTAssertEqual(exported.width, 1_600)
        XCTAssertEqual(exported.height, 1_200)

        let downsampled = try XCTUnwrap(AnalysisProxy.downscaled(exported, maximumLongEdge: previewLongEdge))
        let stats = difference(
            try MetalLUTRenderer.rgba8Bytes(of: downsampled),
            try MetalLUTRenderer.rgba8Bytes(of: session.displayedImage)
        )
        print("preview vs downsampled export: mean \(stats.mean)/255, p99 \(stats.p99)/255")
        XCTAssertLessThanOrEqual(stats.mean, 1.0, "Mean difference \(stats.mean)/255")
        XCTAssertLessThanOrEqual(stats.p99, 4, "p99 difference \(stats.p99)/255")
        // And the edit is genuinely in the export, not the original.
        let original = try XCTUnwrap(AnalysisProxy.downscaled(session.photo.image, maximumLongEdge: previewLongEdge))
        XCTAssertGreaterThan(
            difference(try MetalLUTRenderer.rgba8Bytes(of: downsampled), try MetalLUTRenderer.rgba8Bytes(of: original)).mean, 5
        )
    }

    /// Spec §5.4 step 1: the committed state is exported, not a transient
    /// preview.
    func testTransientPreviewIsNotExported() async throws {
        let session = try makeSession()
        session.applyLook(id: TestLookBook.cool.id)
        await session.settleRendering()
        let committedExport = try await session.exportData()

        session.previewLook(id: TestLookBook.mono.id)
        await session.settleRendering()
        let duringPreview = try await session.exportData()

        XCTAssertEqual(
            try MetalLUTRenderer.rgba8Bytes(of: decode(duringPreview)),
            try MetalLUTRenderer.rgba8Bytes(of: decode(committedExport))
        )
    }

    func testSaveCopyWritesOneJPEGAndLeavesTheOriginal() async throws {
        let session = try makeSession()
        let originalBytes = session.photo.originalData
        session.applyLook(id: TestLookBook.mono.id)
        await session.settleRendering()

        let writer = SpyLibraryWriter()
        try await session.saveCopy(to: writer)

        let saved = await writer.lastSave()
        XCTAssertEqual(saved.ext, "jpg")
        let data = try XCTUnwrap(saved.data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        XCTAssertEqual(session.photo.originalData, originalBytes)
        // Mono: the saved photo has (near) equal channels.
        let mean = TestFixtures.meanColour(of: try decode(data))
        XCTAssertEqual(mean.red, mean.blue, accuracy: 0.02)
    }
}
