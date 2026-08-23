import SwiftUI
import XCTest
@testable import Lightly

private struct NoopLibraryWriter: PhotoLibraryWriting {
    func save(_ data: Data, fileExtension: String) async throws {}
}

private struct SnapshotProEntitlements: EntitlementResolving {
    let level: EntitlementLevel = .pro
    let generativeCredits: Int = 0
    func canApply(_ capability: PaidCapability) -> Bool { true }
}

@MainActor
final class ExportSnapshotTests: XCTestCase {

    private let sheetSize = CGSize(width: 402, height: 560)

    private func makeViewModel(
        entitlements: any EntitlementResolving = FreeTierEntitlementResolver()
    ) -> ExportViewModel {
        ExportViewModel(
            originalImage: TestFixtures.makeImage(),
            recipe: .unmodified,
            originalData: TestFixtures.makeJPEGData(),
            exporter: ImageIOPhotoExporter(),
            libraryWriter: NoopLibraryWriter(),
            entitlements: entitlements
        )
    }

    private func sheet(_ viewModel: ExportViewModel) -> some View {
        ExportSheet(viewModel: viewModel, onClose: {})
    }

    // MARK: - Appearance

    func testExportSheetLight() {
        SnapshotAssertion.assert(
            of: sheet(makeViewModel()), named: "export-light", size: sheetSize
        )
    }

    func testExportSheetDark() {
        SnapshotAssertion.assert(
            of: sheet(makeViewModel()),
            named: "export-dark",
            size: sheetSize,
            colorScheme: .dark
        )
    }

    func testExportSheetAccessibilityTextSize() {
        let view = sheet(makeViewModel())
            .environment(\.dynamicTypeSize, .accessibility3)
        SnapshotAssertion.assert(
            of: view, named: "export-accessibility3", size: sheetSize
        )
    }

    // MARK: - Entitlement parity

    /// The free-tier sheet must be pixel-identical to the Pro sheet: no lock
    /// badge, no dimming, no hint of the boundary until export (spec §0.3).
    func testFreeTierSheet() {
        SnapshotAssertion.assert(
            of: sheet(makeViewModel(entitlements: FreeTierEntitlementResolver())),
            named: "export-free-tier",
            size: sheetSize
        )
    }

    func testProTierSheetIsIdenticalToFreeTier() {
        // Compared against the free-tier reference deliberately; divergence
        // means an entitlement affordance has leaked into the sheet.
        SnapshotAssertion.assert(
            of: sheet(makeViewModel(entitlements: SnapshotProEntitlements())),
            named: "export-free-tier",
            size: sheetSize
        )
    }

    /// Maximum selected on the free tier still shows no warning — the prompt
    /// belongs at export, not at selection.
    func testMaximumQualitySelectedOnFreeTierShowsNoWarning() {
        let viewModel = makeViewModel(entitlements: FreeTierEntitlementResolver())
        viewModel.select(quality: .maximum)

        SnapshotAssertion.assert(
            of: sheet(viewModel), named: "export-maximum-free-tier", size: sheetSize
        )
    }

    // MARK: - Format coupling

    /// PNG is lossless, so the quality section disappears entirely rather than
    /// offering a setting with no effect.
    func testPNGHidesTheQualitySection() {
        let viewModel = makeViewModel()
        viewModel.select(format: .png)

        XCTAssertFalse(viewModel.settings.format.isLossy)
        SnapshotAssertion.assert(
            of: sheet(viewModel), named: "export-png-no-quality", size: sheetSize
        )
    }

    // MARK: - Metadata

    func testLocationDisabledWhenMetadataIsOff() {
        let viewModel = makeViewModel()
        viewModel.setPreservesMetadata(false)

        SnapshotAssertion.assert(
            of: sheet(viewModel), named: "export-metadata-off", size: sheetSize
        )
    }
}
