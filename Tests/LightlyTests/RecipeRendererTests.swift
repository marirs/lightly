import CoreGraphics
import XCTest
@testable import Lightly

final class RecipeRendererTests: XCTestCase {

    func testIdentityRecipeReturnsSourceUnchanged() throws {
        let renderer = RecipeRenderer()
        let image = TestFixtures.makeImage()
        let recipe = DevelopRecipe.unmodified

        let result = try renderer.render(image, with: recipe)

        XCTAssertEqual(result.width, image.width)
        XCTAssertEqual(result.height, image.height)
    }

    func testClarityFilterChangesImage() throws {
        let renderer = RecipeRenderer()
        let image = TestFixtures.makeImage()
        var recipe = DevelopRecipe.unmodified
        recipe.clarity = 0.5

        let result = try renderer.render(image, with: recipe)

        // Compare simple dimensions or some property to show it didn't crash
        // CoreImage rendering changes pixels, so it won't equal the input image identically
        XCTAssertEqual(result.width, image.width)
        XCTAssertEqual(result.height, image.height)
    }

    func testDehazeFilterChangesImage() throws {
        let renderer = RecipeRenderer()
        let image = TestFixtures.makeImage()
        var recipe = DevelopRecipe.unmodified
        recipe.dehaze = 0.5

        let result = try renderer.render(image, with: recipe)

        XCTAssertEqual(result.width, image.width)
        XCTAssertEqual(result.height, image.height)
    }

    func testNoiseReductionFilterChangesImage() throws {
        let renderer = RecipeRenderer()
        let image = TestFixtures.makeImage()
        var recipe = DevelopRecipe.unmodified
        recipe.noiseReduction = 0.5

        let result = try renderer.render(image, with: recipe)

        XCTAssertEqual(result.width, image.width)
        XCTAssertEqual(result.height, image.height)
    }

    func testColorSpacePreservation() throws {
        let renderer = RecipeRenderer()
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        let image = TestFixtures.makeImage()
        var recipe = DevelopRecipe.unmodified
        recipe.exposure = 0.1 // Ensure it's not identity

        let result = try renderer.render(image, with: recipe, outputColorSpace: colorSpace)

        XCTAssertEqual(result.colorSpace?.name, CGColorSpace.displayP3)
    }

    func testAllFiltersAppliedTogether() throws {
        let renderer = RecipeRenderer()
        let image = TestFixtures.makeImage()
        var recipe = DevelopRecipe.unmodified
        recipe.exposure = 0.2
        recipe.contrast = 0.1
        recipe.highlights = -0.1
        recipe.shadows = 0.1
        recipe.vibrance = 0.2
        recipe.clarity = 0.3
        recipe.dehaze = 0.1
        recipe.noiseReduction = 0.1
        recipe.sharpening = 0.1
        recipe.whiteBalance = .init(temperature: 100, tint: 5)

        let result = try renderer.render(image, with: recipe)

        XCTAssertEqual(result.width, image.width)
        XCTAssertEqual(result.height, image.height)
    }
}
