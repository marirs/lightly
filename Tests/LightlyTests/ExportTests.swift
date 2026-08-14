import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Lightly

/// Records what it was asked to save; never touches the real library.
private actor SpyLibraryWriter: PhotoLibraryWriting {
    enum Behaviour: Sendable {
        case succeed
        case fail(LightlyError)
    }

    private let behaviour: Behaviour
    private(set) var savedData: Data?
    private(set) var savedExtension: String?

    init(behaviour: Behaviour = .succeed) {
        self.behaviour = behaviour
    }

    func save(_ data: Data, fileExtension: String) async throws {
        if case .fail(let error) = behaviour { throw error }
        savedData = data
        savedExtension = fileExtension
    }

    func lastSave() -> (data: Data?, ext: String?) { (savedData, savedExtension) }
}

private struct FailingExporter: PhotoExporting {
    func encode(_ image: CGImage, originalData: Data, settings: ExportSettings) throws -> Data {
        throw LightlyError.exportFailed
    }
}

private struct ProEntitlements: EntitlementResolving {
    let level: EntitlementLevel = .pro
    let generativeCredits: Int = 0
    func canApply(_ capability: PaidCapability) -> Bool { true }
}

// MARK: - Encoder

final class ImageIOPhotoExporterTests: XCTestCase {

    private let exporter = ImageIOPhotoExporter()

    /// Source JPEG carrying EXIF, GPS, and a camera make.
    private func makeOriginalData() throws -> Data {
        let image = TestFixtures.makeImage(width: 120, height: 80)
        let data = NSMutableData()

        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw XCTSkip("Cannot create a JPEG destination")
        }

        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:01:15 09:41:00"
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Lightly Labs"
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 51.5,
                kCGImagePropertyGPSLongitude: 0.12
            ]
        ]

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("Cannot finalise JPEG")
        }
        return data as Data
    }

    private func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return [:] }
        return props
    }

    // MARK: Formats

    func testEncodesEveryV1Format() throws {
        let original = try makeOriginalData()
        let image = TestFixtures.makeImage(width: 60, height: 40)

        for format in ExportFormat.allCases {
            var settings = ExportSettings.default
            settings.format = format

            let encoded = try exporter.encode(image, originalData: original, settings: settings)

            XCTAssertFalse(encoded.isEmpty, "\(format) produced no data")

            let source = CGImageSourceCreateWithData(encoded as CFData, nil)
            let type = source.flatMap { CGImageSourceGetType($0) as String? }
            XCTAssertEqual(
                type, format.utType.identifier,
                "\(format) encoded as the wrong container"
            )
        }
    }

    func testEncodedImagePreservesPixelDimensions() throws {
        let original = try makeOriginalData()
        let image = TestFixtures.makeImage(width: 123, height: 77)

        let encoded = try exporter.encode(
            image, originalData: original, settings: .default
        )

        let props = properties(of: encoded)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 123)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 77)
    }

    // MARK: Metadata

    func testPreservesCaptureDateAndCameraWhenEnabled() throws {
        let original = try makeOriginalData()
        var settings = ExportSettings.default
        settings.format = .jpeg
        settings.preservesMetadata = true

        let encoded = try exporter.encode(
            TestFixtures.makeImage(), originalData: original, settings: settings
        )

        let props = properties(of: encoded)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        XCTAssertEqual(
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            "2024:01:15 09:41:00"
        )
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "Lightly Labs")
    }

    func testStripsAllMetadataWhenDisabled() throws {
        let original = try makeOriginalData()
        var settings = ExportSettings.default
        settings.format = .jpeg
        settings.preservesMetadata = false

        let encoded = try exporter.encode(
            TestFixtures.makeImage(), originalData: original, settings: settings
        )

        let props = properties(of: encoded)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
    }

    /// Location is the field that discloses something about the person, so it
    /// must never travel unless explicitly opted into (spec §13, §19).
    func testLocationIsStrippedByDefault() throws {
        let original = try makeOriginalData()
        var settings = ExportSettings.default
        settings.format = .jpeg

        XCTAssertFalse(
            settings.preservesLocation,
            "Location must default to off."
        )

        let encoded = try exporter.encode(
            TestFixtures.makeImage(), originalData: original, settings: settings
        )

        XCTAssertNil(
            properties(of: encoded)[kCGImagePropertyGPSDictionary],
            "GPS data leaked into an export that did not opt in."
        )
    }

    func testLocationIsCarriedOnlyOnExplicitOptIn() throws {
        let original = try makeOriginalData()
        var settings = ExportSettings.default
        settings.format = .jpeg
        settings.preservesMetadata = true
        settings.preservesLocation = true

        let encoded = try exporter.encode(
            TestFixtures.makeImage(), originalData: original, settings: settings
        )

        XCTAssertNotNil(properties(of: encoded)[kCGImagePropertyGPSDictionary])
    }

    /// The rendered image is already upright, so the file must declare
    /// orientation 1 — otherwise viewers rotate it a second time.
    func testExportDeclaresUprightOrientation() throws {
        let original = try makeOriginalData()
        var settings = ExportSettings.default
        settings.format = .jpeg

        let encoded = try exporter.encode(
            TestFixtures.makeImage(), originalData: original, settings: settings
        )

        let props = properties(of: encoded)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int, 1)

        // ImageIO synthesises a TIFF orientation to match the destination's, so
        // the field is present by design. What matters is that it agrees with
        // the corrected orientation rather than carrying the source's value.
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        if let tiffOrientation = tiff?[kCGImagePropertyTIFFOrientation] as? Int {
            XCTAssertEqual(
                tiffOrientation, 1,
                "TIFF orientation must agree with the corrected orientation."
            )
        }
    }

    /// A source tagged as rotated must not pass that tag on: the exported
    /// pixels are already upright, so re-declaring the rotation would make
    /// every viewer turn the photograph a second time.
    func testRotatedSourceDoesNotLeakItsOrientationIntoTheExport() throws {
        let rotatedSource = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            rotatedSource, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw XCTSkip("Cannot create a JPEG destination")
        }
        CGImageDestinationAddImage(
            destination,
            TestFixtures.makeImage(width: 120, height: 80),
            [
                kCGImagePropertyOrientation: 3,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 3]
            ] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        var settings = ExportSettings.default
        settings.format = .jpeg
        settings.preservesMetadata = true

        let encoded = try exporter.encode(
            TestFixtures.makeImage(),
            originalData: rotatedSource as Data,
            settings: settings
        )

        let props = properties(of: encoded)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int, 1)

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNotEqual(
            tiff?[kCGImagePropertyTIFFOrientation] as? Int, 3,
            "The source's rotation tag leaked into the export."
        )
    }

    func testMissingSourceMetadataIsNotAnExportFailure() throws {
        var settings = ExportSettings.default
        settings.format = .jpeg

        let encoded = try exporter.encode(
            TestFixtures.makeImage(), originalData: Data(), settings: settings
        )

        XCTAssertFalse(encoded.isEmpty)
    }

    func testMaximumQualityProducesLargerFileThanHigh() throws {
        let original = try makeOriginalData()
        let image = TestFixtures.makeImage(width: 400, height: 300)

        var high = ExportSettings.default
        high.format = .jpeg
        high.quality = .high

        var maximum = high
        maximum.quality = .maximum

        let highData = try exporter.encode(image, originalData: original, settings: high)
        let maxData = try exporter.encode(image, originalData: original, settings: maximum)

        XCTAssertGreaterThan(
            maxData.count, highData.count,
            "Maximum quality should encode with less compression."
        )
    }
}

// MARK: - View model

@MainActor
final class ExportViewModelTests: XCTestCase {

    private func makeViewModel(
        entitlements: any EntitlementResolving = FreeTierEntitlementResolver(),
        exporter: any PhotoExporting = ImageIOPhotoExporter(),
        writer: any PhotoLibraryWriting = SpyLibraryWriter()
    ) -> ExportViewModel {
        ExportViewModel(
            renderedImage: TestFixtures.makeImage(),
            originalData: Data(),
            exporter: exporter,
            libraryWriter: writer,
            entitlements: entitlements
        )
    }

    // MARK: Defaults

    func testDefaultsToHeicHighWithLocationOff() {
        let viewModel = makeViewModel()

        XCTAssertEqual(viewModel.settings.format, .heic)
        XCTAssertEqual(viewModel.settings.quality, .high)
        XCTAssertTrue(viewModel.settings.preservesMetadata)
        XCTAssertFalse(viewModel.settings.preservesLocation)
    }

    // MARK: Settings coupling

    func testSelectingPNGDropsBackToHighQuality() {
        let viewModel = makeViewModel()
        viewModel.select(quality: .maximum)

        viewModel.select(format: .png)

        XCTAssertEqual(
            viewModel.settings.quality, .high,
            "PNG is lossless; offering a quality choice alongside it is meaningless."
        )
    }

    func testDisablingMetadataAlsoDisablesLocation() {
        let viewModel = makeViewModel()
        viewModel.setPreservesMetadata(true)
        viewModel.setPreservesLocation(true)

        viewModel.setPreservesMetadata(false)

        XCTAssertFalse(
            viewModel.settings.preservesLocation,
            "Location cannot survive its parent setting being switched off."
        )
    }

    func testLocationCannotBeEnabledWhileMetadataIsOff() {
        let viewModel = makeViewModel()
        viewModel.setPreservesMetadata(false)

        viewModel.setPreservesLocation(true)

        XCTAssertFalse(viewModel.settings.preservesLocation)
    }

    // MARK: Entitlement

    /// Maximum is freely selectable; the gate is at export (spec §26.2).
    func testFreeTierCanSelectMaximumQualityWithoutPrompt() {
        let viewModel = makeViewModel(entitlements: FreeTierEntitlementResolver())

        viewModel.select(quality: .maximum)

        XCTAssertEqual(viewModel.settings.quality, .maximum)
        XCTAssertNil(
            viewModel.paywallPrompt,
            "Choosing a setting must never raise a paywall."
        )
    }

    func testExportingMaximumOnFreeTierRaisesPaywallAndDoesNotSave() async {
        let writer = SpyLibraryWriter()
        let viewModel = makeViewModel(
            entitlements: FreeTierEntitlementResolver(), writer: writer
        )
        viewModel.select(quality: .maximum)

        viewModel.export(to: .photoLibrary)
        await viewModel.inFlightExport?.value

        XCTAssertEqual(viewModel.paywallPrompt, .maximumQualityExport)
        XCTAssertEqual(viewModel.outcome, .idle)
        let saved = await writer.lastSave()
        XCTAssertNil(saved.data, "A gated export must not write anything.")
    }

    func testExportingHighQualityOnFreeTierSucceeds() async {
        let writer = SpyLibraryWriter()
        let viewModel = makeViewModel(
            entitlements: FreeTierEntitlementResolver(), writer: writer
        )

        viewModel.export(to: .photoLibrary)
        await viewModel.inFlightExport?.value

        XCTAssertEqual(viewModel.outcome, .savedToLibrary)
        XCTAssertNil(viewModel.paywallPrompt)
        let saved = await writer.lastSave()
        XCTAssertNotNil(saved.data)
    }

    func testProCanExportAtMaximumQuality() async {
        let writer = SpyLibraryWriter()
        let viewModel = makeViewModel(entitlements: ProEntitlements(), writer: writer)
        viewModel.select(quality: .maximum)

        viewModel.export(to: .photoLibrary)
        await viewModel.inFlightExport?.value

        XCTAssertEqual(viewModel.outcome, .savedToLibrary)
        XCTAssertNil(viewModel.paywallPrompt)
    }

    // MARK: Destinations

    func testSaveUsesTheSelectedFormatExtension() async {
        let writer = SpyLibraryWriter()
        let viewModel = makeViewModel(writer: writer)
        viewModel.select(format: .png)

        viewModel.export(to: .photoLibrary)
        await viewModel.inFlightExport?.value

        let saved = await writer.lastSave()
        XCTAssertEqual(saved.ext, "png")
    }

    func testShareProducesAFileOnDisk() async throws {
        let viewModel = makeViewModel()

        viewModel.export(to: .share)
        await viewModel.inFlightExport?.value

        guard case .readyToShare(let url) = viewModel.outcome else {
            return XCTFail("Expected a shareable file, got \(viewModel.outcome)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "heic")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Failures

    func testEncodingFailureSurfacesAsADefinedError() async {
        let viewModel = makeViewModel(exporter: FailingExporter())

        viewModel.export(to: .photoLibrary)
        await viewModel.inFlightExport?.value

        XCTAssertEqual(viewModel.outcome, .failed(.exportFailed))
    }

    func testPermissionDenialSurfacesAsPermissionDenied() async {
        let viewModel = makeViewModel(
            writer: SpyLibraryWriter(behaviour: .fail(.permissionDenied))
        )

        viewModel.export(to: .photoLibrary)
        await viewModel.inFlightExport?.value

        XCTAssertEqual(viewModel.outcome, .failed(.permissionDenied))
    }

    func testStorageFullSurfacesAsStorageFull() async {
        let viewModel = makeViewModel(
            writer: SpyLibraryWriter(behaviour: .fail(.storageFull))
        )

        viewModel.export(to: .photoLibrary)
        await viewModel.inFlightExport?.value

        XCTAssertEqual(viewModel.outcome, .failed(.storageFull))
    }

    func testDismissingAFailureReturnsToIdle() async {
        let viewModel = makeViewModel(exporter: FailingExporter())
        viewModel.export(to: .photoLibrary)
        await viewModel.inFlightExport?.value

        viewModel.dismissOutcome()

        XCTAssertEqual(viewModel.outcome, .idle)
    }

    func testConcurrentExportsAreIgnoredWhileOneIsRunning() async {
        let viewModel = makeViewModel()

        viewModel.export(to: .photoLibrary)
        XCTAssertTrue(viewModel.isExporting)
        // A second tap while exporting must not start a duplicate write.
        viewModel.export(to: .share)

        await viewModel.inFlightExport?.value
        XCTAssertEqual(viewModel.outcome, .savedToLibrary)
    }
}

// MARK: - Non-destructive guarantee

@MainActor
final class ExportPreservesOriginalTests: XCTestCase {

    /// Spec §22: the original must be unchanged after an export.
    func testExportingDoesNotAlterTheOriginalOrTheHistory() async {
        let photo = TestFixtures.makePhoto()
        let editor = EditorViewModel(original: photo, developer: DebugFixedRecipeDeveloper())
        editor.develop()
        await editor.developTask?.value

        let originalImage = editor.original.image
        let originalBytes = editor.original.originalData
        let historyBefore = editor.history

        let writer = SpyLibraryWriter()
        let exportViewModel = ExportViewModel(
            renderedImage: editor.renderedImage,
            originalData: photo.originalData,
            exporter: ImageIOPhotoExporter(),
            libraryWriter: writer,
            entitlements: FreeTierEntitlementResolver()
        )

        exportViewModel.export(to: .photoLibrary)
        await exportViewModel.inFlightExport?.value

        XCTAssertEqual(exportViewModel.outcome, .savedToLibrary)
        XCTAssertTrue(
            editor.original.image === originalImage,
            "Export must not replace the original image."
        )
        XCTAssertEqual(
            editor.original.originalData, originalBytes,
            "Export must not alter the original bytes."
        )
        XCTAssertEqual(
            editor.history, historyBefore,
            "Export is not an edit and must not appear in history."
        )
    }
}
