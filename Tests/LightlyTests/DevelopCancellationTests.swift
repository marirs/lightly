import CoreGraphics
import XCTest
@testable import Lightly

/// A one-shot latch a test opens to let a controlled dependency proceed.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until opened. Deliberately ignores task cancellation, like a
    /// real engine stuck in non-cancellable work.
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// A developer that, once released, reports a stage and then fails —
/// regardless of whether its run was cancelled in the meantime.
private struct LateReportingDeveloper: PhotoDeveloping {
    let gate: Gate
    let implementationKind: DevelopImplementationKind = .production
    let performedStages: [DevelopStage] = [.exposure]

    func develop(
        _ photo: SelectedPhoto,
        onStageCompleted: @escaping @Sendable (DevelopStage) -> Void
    ) async throws -> DevelopRecipe {
        await gate.wait()
        onStageCompleted(.exposure)
        throw LightlyError.developFailed
    }
}

/// Cancelling Develop (Cancel, Reset or close) must leave no trace of the run.
@MainActor
final class DevelopCancellationTests: XCTestCase {

    private func waitUntilRenderStarts(_ renderer: SlowEncodingRenderer) async {
        var attempts = 0
        while await renderer.callCount == 0, attempts < 500 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Lets main-actor hops queued by the cancelled run (stage callbacks) run.
    private func drainMainActor() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// - Parameter expectedPublishes: Reset legitimately shows the original
    ///   once; nothing from the Develop run may be shown on top of it.
    private func assertPreDevelopState(
        _ editor: EditorViewModel,
        expectedPublishes: Int = 0,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(editor.phase, .readyToDevelop, file: file, line: line)
        XCTAssertTrue(editor.history.operations.isEmpty, "No history entry", file: file, line: line)
        XCTAssertTrue(editor.renderedImage === editor.original.image, "Nothing rendered shown", file: file, line: line)
        XCTAssertEqual(editor.publishedRenderCount, expectedPublishes, file: file, line: line)
        XCTAssertTrue(editor.completedStages.isEmpty, file: file, line: line)
        XCTAssertNil(editor.activeError, file: file, line: line)
    }

    private func cancelMidRender(using cancel: (EditorViewModel) -> Void) async -> EditorViewModel {
        let renderer = SlowEncodingRenderer(delay: .milliseconds(150), ignoresCancellation: true)
        let editor = EditorViewModel(
            original: TestFixtures.makePhoto(),
            developer: StubProductionDeveloper(),
            previewRenderer: renderer
        )
        editor.develop()
        await waitUntilRenderStarts(renderer)
        let started = await renderer.callCount
        XCTAssertEqual(started, 1, "Precondition: the Develop render is running")

        cancel(editor)
        // Let the non-cancellable render finish and every hop settle.
        await editor.developTask?.value
        await editor.settleRendering()
        await drainMainActor()
        let completed = await renderer.completedCount
        XCTAssertEqual(completed, 1, "Precondition: the render ran to completion despite Cancel")
        return editor
    }

    func testCancelDuringDevelopRenderCommitsNothing() async {
        let editor = await cancelMidRender { $0.cancelDevelop() }
        assertPreDevelopState(editor)
    }

    func testResetDuringDevelopRenderCommitsNothing() async {
        let editor = await cancelMidRender { $0.reset() }
        assertPreDevelopState(editor, expectedPublishes: 1)
    }

    func testStaleProgressAndErrorFromACancelledRunAreIgnored() async {
        let gate = Gate()
        let editor = EditorViewModel(
            original: TestFixtures.makePhoto(),
            developer: LateReportingDeveloper(gate: gate)
        )
        editor.develop()
        editor.cancelDevelop()

        await gate.open()
        await editor.developTask?.value
        await drainMainActor()

        assertPreDevelopState(editor)
    }
}
