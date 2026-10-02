import CoreGraphics
import XCTest
@testable import Lightly

/// A small first-party look-book of synthetic LUTs (no vendor presets).
/// Test fixtures only: formula Looks never ship as app content.
enum TestLookBook {
    static let fixtureProvenance = LookProvenance(
        lutSource: "lr-model-approximation", validation: "unvalidated", omittedOperators: [], approximatedGlobally: []
    )
    static let warm = LUTLook(id: "test.warm", version: "test-v1", name: "Warm",
                              lut: .lut(dimension: 33) { SIMD3(min($0.x * 1.15, 1.2), $0.y, $0.z * 0.85) },
                              provenance: fixtureProvenance)
    static let cool = LUTLook(id: "test.cool", version: "test-v1", name: "Cool",
                              lut: .lut(dimension: 33) { SIMD3($0.x * 0.85, $0.y, min($0.z * 1.15, 1.2)) },
                              provenance: fixtureProvenance)
    static let mono = LUTLook(id: "test.mono", version: "test-v1", name: "Mono",
                              lut: .lut(dimension: 33) { SIMD3(repeating: ($0.x + $0.y + $0.z) / 3) },
                              provenance: fixtureProvenance)
    static let book = LUTLookBook(looks: [warm, cool, mono])
}

/// Delegates to Metal after a delay, counting calls, so latest-wins is
/// observable on a fast GPU.
final class SlowLUTRenderer: LUTRendering, @unchecked Sendable {
    private let wrapped: MetalLUTRenderer
    private let delay: TimeInterval
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }

    init(wrapping renderer: MetalLUTRenderer, delay: TimeInterval = 0.03) {
        wrapped = renderer
        self.delay = delay
    }

    func apply(_ passes: [LUT3D], toRGBA8 pixels: [UInt8], width: Int, height: Int, maximumTileSide: Int) throws -> [UInt8] {
        lock.withLock { calls += 1 }
        Thread.sleep(forTimeInterval: delay)
        return try wrapped.apply(passes, toRGBA8: pixels, width: width, height: height, maximumTileSide: maximumTileSide)
    }
}

/// Records the analysis proxy it was handed and returns fixed weights.
private actor ProxyRecorder {
    private(set) var sizes: [(Int, Int)] = []
    func record(_ image: CGImage) { sizes.append((image.width, image.height)) }
}

@MainActor
final class LUTEditSessionTests: XCTestCase {

    private var metal: MetalLUTRenderer!

    override func setUpWithError() throws {
        metal = try MetalLUTRenderer()
    }

    /// 1600×1200 gradient with noise, encoded so the analysis proxy path
    /// (decode from bytes) is exercised.
    static func makePhoto(width: Int = 1_600, height: Int = 1_200) -> SelectedPhoto {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: ColorPipeline.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for band in 0..<16 {
            let t = CGFloat(band) / 15
            context.setFillColor(red: 0.15 + 0.7 * t, green: 0.3 + 0.4 * (1 - t), blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: band * height / 16, width: width, height: height / 16 + 1))
        }
        let image = context.makeImage()!
        return SelectedPhoto(image: image, source: .photoLibrary, originalData: TestFixtures.makeJPEGData(for: image))
    }

    private static let autoBasis: [LUT3D] = [
        .identity(),
        .lut(dimension: 33) { 1.3 * $0 - SIMD3(repeating: 0.1) }   // brightening, out of range
    ]

    private func makeSession(
        auto: any AutoEnhancing = ModelNotBundledAutoEnhancer(),
        renderer: (any LUTRendering)? = nil
    ) throws -> LUTEditSession {
        try LUTEditSession(
            photo: Self.makePhoto(), autoEnhancer: auto, lookBook: TestLookBook.book,
            renderer: renderer ?? metal, previewLongEdge: 400
        )
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] { try MetalLUTRenderer.rgba8Bytes(of: image) }

    /// What the preview must show for `passes`, rendered directly.
    private func expectedPreview(_ session: LUTEditSession, passes: [LUT3D]) throws -> [UInt8] {
        let base = session.previewBase
        return try metal.apply(passes, toRGBA8: base.pixels, width: base.width, height: base.height)
    }

    // MARK: - Auto

    func testAutoIsExplicitlyUnavailableWithoutABundledModel() async throws {
        let session = try makeSession()
        await session.prepareAuto()

        XCTAssertEqual(session.autoAvailability, .unavailable(.modelNotBundled))
        session.setAutoStrength(1)
        await session.settleRendering()
        XCTAssertEqual(session.committedState, .original, "Unavailable Auto must not be recorded")
        XCTAssertEqual(try pixels(session.displayedImage), session.previewBase.pixels)
    }

    func testInjectedBasisDrivesAutoFromTheAnalysisProxy() async throws {
        let recorder = ProxyRecorder()
        let session = try makeSession(auto: BasisAutoEnhancer(basis: Self.autoBasis) { proxy in
            await recorder.record(proxy)
            return [0.25, 0.75]
        })
        await session.prepareAuto()
        XCTAssertEqual(session.autoAvailability, .available)
        let sizes = await recorder.sizes
        XCTAssertEqual(sizes.first?.0, 1_024, "Auto must see the 1024 analysis proxy, not the preview")

        session.setAutoStrength(1)
        await session.settleRendering()

        let fused = try XCTUnwrap(session.autoLUT)
        let index = (24 + 24 * 33 + 24 * 33 * 33) * 4
        XCTAssertEqual(fused.values[index], 0.25 * 0.75 + 0.75 * (1.3 * 0.75 - 0.1), accuracy: 1e-5)
        XCTAssertEqual(try pixels(session.displayedImage), try expectedPreview(session, passes: [fused]))
    }

    // MARK: - Looks

    func testLookIsAppliedAsASecondPassAfterAuto() async throws {
        let session = try makeSession(auto: BasisAutoEnhancer(basis: Self.autoBasis) { _ in [0, 1] })
        await session.prepareAuto()
        session.setAutoStrength(1)
        session.applyLook(id: TestLookBook.warm.id)
        await session.settleRendering()

        let auto = try XCTUnwrap(session.autoLUT)
        XCTAssertEqual(session.passes(for: session.committedState), [auto, TestLookBook.warm.lut])
        XCTAssertEqual(try pixels(session.displayedImage), try expectedPreview(session, passes: [auto, TestLookBook.warm.lut]))
    }

    func testApplyingASecondLookReplacesTheFirst() async throws {
        let session = try makeSession()
        session.applyLook(id: TestLookBook.warm.id)
        session.applyLook(id: TestLookBook.cool.id)
        await session.settleRendering()

        XCTAssertEqual(session.passes(for: session.committedState), [TestLookBook.cool.lut])
        let shown = try pixels(session.displayedImage)
        XCTAssertEqual(shown, try expectedPreview(session, passes: [TestLookBook.cool.lut]))
        XCTAssertNotEqual(shown, try expectedPreview(session, passes: [TestLookBook.warm.lut, TestLookBook.cool.lut]),
                          "Looks must replace, not stack")
    }

    /// Codex finding 2: re-committing the already committed Look while a
    /// different Look is being previewed must settle the preview back to the
    /// committed Look, without adding an undo step. Before the fix `commit`
    /// returned early and the preview of B stayed on screen while export
    /// rendered A.
    func testReapplyingTheCommittedLookSettlesAPreviewOfAnotherLook() async throws {
        let session = try makeSession()
        session.applyLook(id: TestLookBook.warm.id)
        await session.settleRendering()
        let historyCountAfterFirstApply = session.history.count
        let historyIndexAfterFirstApply = session.historyIndex

        session.previewLook(id: TestLookBook.cool.id)
        await session.settleRendering()
        session.applyLook(id: TestLookBook.warm.id)
        await session.settleRendering()

        let warmPreview = try expectedPreview(session, passes: [TestLookBook.warm.lut])
        let coolPreview = try expectedPreview(session, passes: [TestLookBook.cool.lut])
        let shown = try pixels(session.displayedImage)
        // Bool comparisons with a named outcome: an XCTAssertEqual on pixel
        // arrays prints megabytes of numbers and hides which image is shown.
        XCTAssertTrue(shown == warmPreview,
                      "Settling on the committed Look must display it, not the abandoned preview; showing the cool preview: \(shown == coolPreview)")
        XCTAssertEqual(session.history.count, historyCountAfterFirstApply, "Re-applying the same Look is not a new step")
        XCTAssertEqual(session.historyIndex, historyIndexAfterFirstApply)
        XCTAssertEqual(session.passes(for: session.committedState), [TestLookBook.warm.lut], "Export renders the committed Look")
    }

    func testUnknownLookIsRefusedNotSubstituted() throws {
        let session = try makeSession()
        XCTAssertFalse(session.applyLook(id: "test.war"))
        XCTAssertEqual(session.committedState, .original)
    }

    func testRapidLookChangesShowOnlyTheLast() async throws {
        let slow = SlowLUTRenderer(wrapping: metal)
        let session = try makeSession(renderer: slow)
        let ids = [TestLookBook.warm.id, TestLookBook.cool.id, TestLookBook.mono.id]
        for step in 0..<20 { session.previewLook(id: ids[step % 3]) }
        session.previewLook(id: TestLookBook.mono.id)
        await session.settleRendering()

        XCTAssertEqual(try pixels(session.displayedImage), try expectedPreview(session, passes: [TestLookBook.mono.lut]))
        XCTAssertLessThanOrEqual(slow.callCount, 2, "Only the running and the newest request may render")
        let stats = await session.schedulerStatistics()
        XCTAssertLessThanOrEqual(stats.peakOutstanding, 2)
        XCTAssertEqual(session.publishedRenderCount, 1)
        XCTAssertEqual(session.committedState, .original, "Previewing never commits")
    }

    // MARK: - Compare, Undo, Reset

    func testCompareUndoAndReset() async throws {
        let session = try makeSession()
        session.applyLook(id: TestLookBook.warm.id)
        session.applyLook(id: TestLookBook.mono.id, strength: 0.5)
        await session.settleRendering()
        let mono = try expectedPreview(session, passes: [TestLookBook.mono.lut.blendedTowardIdentity(strength: 0.5)])
        XCTAssertEqual(try pixels(session.displayedImage), mono)

        session.beginCompare()
        XCTAssertEqual(try pixels(session.displayedImage), session.previewBase.pixels)
        session.endCompare()
        XCTAssertEqual(try pixels(session.displayedImage), mono)

        session.undo()
        await session.settleRendering()
        XCTAssertEqual(session.committedState.lookID, TestLookBook.warm.id)
        XCTAssertEqual(try pixels(session.displayedImage), try expectedPreview(session, passes: [TestLookBook.warm.lut]))

        // Reset to Auto clears the Look as an undoable step (spec §3, D10);
        // it no longer wipes history back to `.original`.
        session.resetToAuto()
        await session.settleRendering()
        XCTAssertEqual(session.committedState, .original, "No Auto here, so dropping the Look leaves the original")
        XCTAssertTrue(session.canUndo, "Reset is an undoable step, not a history wipe")
        XCTAssertEqual(try pixels(session.displayedImage), session.previewBase.pixels)
    }

    // MARK: - Reset to Auto (Codex finding 3)

    func testResetToAutoKeepsAutoAndClearsTheLook() async throws {
        let session = try makeSession(auto: BasisAutoEnhancer(basis: Self.autoBasis) { _ in [0, 1] })
        await session.prepareAuto()
        session.setAutoStrength(1)
        session.applyLook(id: TestLookBook.warm.id)

        session.resetToAuto()
        await session.settleRendering()

        XCTAssertEqual(session.committedState.autoStrength, 1, "Reset to Auto must keep Auto")
        XCTAssertNil(session.committedState.lookID, "Reset to Auto must clear the Look")
        let auto = try XCTUnwrap(session.autoLUT)
        XCTAssertTrue(try pixels(session.displayedImage) == expectedPreview(session, passes: [auto]),
                      "After Reset the screen shows Auto alone")
    }

    func testUndoAfterResetRestoresTheLook() async throws {
        let session = try makeSession(auto: BasisAutoEnhancer(basis: Self.autoBasis) { _ in [0, 1] })
        await session.prepareAuto()
        session.setAutoStrength(1)
        session.applyLook(id: TestLookBook.warm.id)
        let withLook = session.committedState

        session.resetToAuto()
        session.undo()
        await session.settleRendering()

        XCTAssertEqual(session.committedState, withLook, "Undo after Reset must bring the Look back")
        let auto = try XCTUnwrap(session.autoLUT)
        XCTAssertTrue(try pixels(session.displayedImage) == expectedPreview(session, passes: [auto, TestLookBook.warm.lut]))
    }

    func testResetTwiceAddsOneStep() throws {
        let session = try makeSession()
        session.applyLook(id: TestLookBook.mono.id)
        let countBeforeReset = session.history.count

        session.resetToAuto()
        session.resetToAuto()

        XCTAssertEqual(session.history.count, countBeforeReset + 1, "A Reset that changes nothing is not a step")
        XCTAssertEqual(session.historyIndex, session.history.count - 1)
    }

    /// Spec §3: the stack is capped at 50 entries, dropping the oldest.
    /// Mirrors Android `UndoStack`: the capacity counts the starting entry.
    func testHistoryIsCappedAtFiftyEntriesAndUndoReachesTheOldestRetained() throws {
        let session = try makeSession()
        let specCapacity = 50   // spec §3; literal so the test does not just mirror the implementation
        let commitCount = 60
        var committed: [LUTEditState] = [session.committedState]
        for step in 1...commitCount {
            // Distinct strengths so every commit is a real change.
            session.applyLook(id: TestLookBook.warm.id, strength: Float(step) / Float(commitCount))
            committed.append(session.committedState)
        }

        XCTAssertEqual(session.history.count, specCapacity)
        XCTAssertEqual(session.historyIndex, specCapacity - 1)
        XCTAssertEqual(session.committedState, committed.last)

        var undoCount = 0
        while session.canUndo {
            session.undo()
            undoCount += 1
        }
        XCTAssertEqual(undoCount, specCapacity - 1)
        XCTAssertEqual(session.committedState, committed[committed.count - specCapacity],
                       "Undo stops at the oldest retained entry")
        XCTAssertNotEqual(session.committedState, .original, "The oldest entries were dropped")
    }
}
