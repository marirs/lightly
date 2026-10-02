import CoreGraphics
import XCTest
@testable import Lightly

/// Every render stage must hand on sRGB-tagged pixels (spec §4.3), so no
/// stage silently reinterprets values in an uncalibrated space.
final class ColorPipelineRenderTests: XCTestCase {

    private var brighten: DevelopRecipe {
        var recipe = DevelopRecipe.unmodified
        recipe.exposure = 0.5
        return recipe
    }

    private func source(width: Int = 64, height: Int = 48) -> CGImage {
        TestFixtures.makeSolidImage(width: width, height: height, red: 0.3, green: 0.4, blue: 0.5)
    }

    func testRecipeRendererOutputsSRGB() throws {
        let rendered = try RecipeRenderer().render(source(), with: brighten)

        XCTAssertEqual(rendered.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertGreaterThan(TestFixtures.meanColour(of: rendered).green, 0.45, "Exposure must brighten")
    }

    func testPreviewDownsampleOutputsSRGB() async throws {
        let photo = SelectedPhoto(image: source(width: 400, height: 300), source: .photoLibrary, originalData: Data())
        let preview = try await PreviewRenderer(maximumPreviewDimension: 100)
            .renderPreview(photo.image, identity: photo.fingerprint, with: .unmodified)

        XCTAssertEqual(max(preview.width, preview.height), 100)
        XCTAssertEqual(preview.colorSpace?.name, CGColorSpace.sRGB)
    }

    func testThumbnailDownsampleOutputsSRGB() async throws {
        let photo = SelectedPhoto(image: source(width: 400, height: 300), source: .photoLibrary, originalData: Data())
        let look = LightlyPreset(id: "t", name: "t", category: .film, isIncludedInFreeTier: true, recipe: .unmodified)
        let thumbnail = try await CoreImageThumbnailRenderer().thumbnail(
            for: look, from: LookThumbnailSource(photo: photo, editBase: .unmodified), maximumDimension: 100
        )

        XCTAssertEqual(thumbnail.colorSpace?.name, CGColorSpace.sRGB)
    }
}
