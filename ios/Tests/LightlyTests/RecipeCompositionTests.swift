import XCTest
@testable import Lightly

/// Covers the recipe arithmetic that intensity depends on.
final class RecipeCompositionTests: XCTestCase {

    private var sample: DevelopRecipe {
        DevelopRecipe(
            whiteBalance: .init(temperature: 200, tint: -4),
            exposure: 0.2,
            highlights: -0.4,
            shadows: 0.3,
            contrast: 0.1,
            vibrance: 0.2,
            clarity: 0.05,
            dehaze: 0.02,
            sharpening: 0.1,
            noiseReduction: 0.05
        )
    }

    func testScalingByOneIsIdentity() {
        XCTAssertEqual(sample.scaled(by: 1), sample)
    }

    func testScalingByZeroYieldsNoChange() {
        XCTAssertEqual(sample.scaled(by: 0), .unmodified)
    }

    func testScalingIsProportional() {
        let half = sample.scaled(by: 0.5)

        XCTAssertEqual(half.exposure, 0.1, accuracy: 0.0001)
        XCTAssertEqual(half.whiteBalance.temperature, 100, accuracy: 0.0001)
        XCTAssertEqual(half.highlights, -0.2, accuracy: 0.0001)
    }

    func testScalingClampsOutOfRangeFactors() {
        XCTAssertEqual(sample.scaled(by: 3), sample)
        XCTAssertEqual(sample.scaled(by: -2), .unmodified)
    }

    func testCombiningWithIdentityIsUnchanged() {
        XCTAssertEqual(sample.combined(with: .unmodified), sample)
    }

    func testCombiningIsAdditive() {
        let doubled = sample.combined(with: sample)

        XCTAssertEqual(doubled.exposure, 0.4, accuracy: 0.0001)
        XCTAssertEqual(doubled.whiteBalance.tint, -8, accuracy: 0.0001)
    }
}
