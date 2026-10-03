import CoreGraphics
import Foundation
import XCTest
@testable import Lightly

/// Editor sessions over the shared parity pack (`shared/fixtures/look-pack/manifest-parity.json`:
/// 40 real presets in the format-3 pack format) and the real Metal LUT renderer.
@MainActor
enum EditorTestSupport {

    static func model() throws -> DevelopModel {
        try DevelopModel.load(contractData: Data(contentsOf: DevelopParityTests.fixture("shared/contracts/rendering-v2.json")))
    }

    static func parityPack(model: DevelopModel) throws -> PresetPack {
        let data = try Data(contentsOf: DevelopParityTests.fixture("shared/fixtures/look-pack/manifest-parity.json"))
        return PresetPackLoader.read(data, model: model, expectedCatalogueSha256: nil).pack
    }

    static func library() throws -> DevelopLibrary {
        let model = try model()
        return DevelopLibrary(pack: try parityPack(model: model), model: model, lutApplier: try MetalLUTRenderer())
    }

    /// A photo with real detail (gradients and edges) so spatial operators have something to do.
    static func photo(width: Int = 640, height: Int = 426) async throws -> SelectedPhoto {
        let image = TestFixtures.makeImage(width: width, height: height)
        return try await ImageIOPhotoLoader().loadPhoto(from: TestFixtures.makeTIFFData(for: image), source: .photoLibrary)
    }

    static func readySession(
        photo: SelectedPhoto? = nil,
        library: DevelopLibrary? = nil,
        autoEnhancer: any AutoEnhancing = ModelNotBundledAutoEnhancer(),
        personDetector: any PersonDetecting = FixedPersonDetector(result: false),
        writer: any PhotoLibraryWriting = SpyLibraryWriter(),
        exporter: any PhotoExporting = ImageIOPhotoExporter(),
        settings: @escaping @MainActor () -> ExportSettings = { .default },
        previewLongEdge: Int = 640
    ) async throws -> EditorSession {
        let resolvedPhoto: SelectedPhoto
        if let photo { resolvedPhoto = photo } else { resolvedPhoto = try await Self.photo() }
        let session = EditorSession(photo: resolvedPhoto, library: try library ?? Self.library(), autoEnhancer: autoEnhancer,
                                    personDetector: personDetector, libraryWriter: writer, exporter: exporter,
                                    saveSettings: settings, previewLongEdge: previewLongEdge)
        session.start()
        await session.waitUntilReady()
        await session.settleRendering()
        return session
    }

    static func waitForSave(_ session: EditorSession, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while session.saveState == .saving, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Mean colour of an image, 0…1.
    static func mean(_ image: CGImage) -> SIMD3<Double> {
        let colour = TestFixtures.meanColour(of: image)
        return SIMD3(colour.red, colour.green, colour.blue)
    }
}

/// An Auto that fails the way a real model could (retryable).
struct FailingAutoEnhancer: AutoEnhancing {
    func autoLUT(forAnalysisProxy proxy: CGImage) async -> AutoResult { .unavailable(.analysisFailed) }
}
