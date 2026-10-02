import SwiftUI
import XCTest
@testable import Lightly

/// Guards the snapshot harness's environment pinning itself.
@MainActor
final class SnapshotEnvironmentTests: XCTestCase {

    private let size = CGSize(width: 300, height: 120)

    private func probe() -> some View {
        Text("Lightly").font(.body).foregroundStyle(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
    }

    /// Rows containing dark (text) pixels — a proxy for rendered text height.
    private func inkRows(_ image: CGImage) -> Int {
        let bytes = TestFixtures.rgbaBytes(of: image)
        var rows = 0
        for row in 0..<image.height {
            let start = row * image.width * 4
            let hasInk = stride(from: start, to: start + image.width * 4, by: 4).contains { bytes[$0] < 128 }
            if hasInk { rows += 1 }
        }
        return rows
    }

    /// Whatever the simulator's Settings → Text Size is, the default render
    /// is identical to an explicit `large` render.
    func testDefaultRenderIsPinnedToLargeText() throws {
        let pinned = try XCTUnwrap(SnapshotAssertion.render(probe(), size: size, colorScheme: .light))
        let explicitLarge = try XCTUnwrap(SnapshotAssertion.render(
            probe().environment(\.dynamicTypeSize, .large), size: size, colorScheme: .light
        ))

        XCTAssertEqual(TestFixtures.rgbaBytes(of: pinned), TestFixtures.rgbaBytes(of: explicitLarge))
    }

    /// Accessibility snapshots set AX3 on the view; the outer pin must not
    /// flatten that back to `large`.
    func testExplicitAccessibilitySizeSurvivesThePin() throws {
        let large = try XCTUnwrap(SnapshotAssertion.render(probe(), size: size, colorScheme: .light))
        let ax3 = try XCTUnwrap(SnapshotAssertion.render(
            probe().environment(\.dynamicTypeSize, .accessibility3), size: size, colorScheme: .light
        ))

        XCTAssertGreaterThan(inkRows(ax3), inkRows(large) * 3 / 2, "AX3 text must render much taller than large")
    }

    // MARK: - Runtime sidecar

    private func directory(with environment: SnapshotEnvironment?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let environment {
            try JSONEncoder().encode(environment).write(to: url.appendingPathComponent(SnapshotEnvironment.fileName))
        }
        return url
    }

    func testMatchingEnvironmentAllowsComparison() throws {
        XCTAssertNil(SnapshotEnvironment.mismatch(referenceDirectory: try directory(with: .current)))
    }

    func testDifferentRuntimeIsReportedClearly() throws {
        let other = SnapshotEnvironment(deviceName: "iPhone 17", runtimeVersion: "18.0", runtimeBuild: "22A0")
        let message = try XCTUnwrap(SnapshotEnvironment.mismatch(referenceDirectory: try directory(with: other)))

        XCTAssertTrue(message.contains("iOS 18.0 (22A0)"), message)
        XCTAssertTrue(message.contains(SnapshotEnvironment.current.summary), message)
    }

    func testMissingSidecarIsReported() throws {
        XCTAssertNotNil(SnapshotEnvironment.mismatch(referenceDirectory: try directory(with: nil)))
    }

    /// The checked-in sidecar describes the environment the suite runs on.
    func testCheckedInSidecarMatchesThisSimulator() {
        let references = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("__Snapshots__")
        XCTAssertNil(SnapshotEnvironment.mismatch(referenceDirectory: references))
    }
}
