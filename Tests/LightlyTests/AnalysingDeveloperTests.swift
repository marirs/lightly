import CoreGraphics
import XCTest
@testable import Lightly

final class AnalysingDeveloperTests: XCTestCase {

    func testReportsProductionKind() {
        let developer = AnalysingDeveloper(analyser: HistogramAnalyser())
        XCTAssertEqual(developer.implementationKind, .production)
    }

    func testPerformsAllStages() {
        let developer = AnalysingDeveloper(analyser: HistogramAnalyser())
        XCTAssertEqual(developer.performedStages, DevelopStage.allCases)
    }

    func testDevelopProducesNonIdentityRecipe() async throws {
        let developer = AnalysingDeveloper(analyser: HistogramAnalyser())
        let photo = TestFixtures.makePhoto()

        let recipe = try await developer.develop(photo) { _ in }

        XCTAssertNotEqual(recipe, .unmodified)
    }

    func testStagesReportedInOrder() async throws {
        let developer = AnalysingDeveloper(analyser: HistogramAnalyser())
        let photo = TestFixtures.makePhoto()
        
        var reportedStages = [DevelopStage]()
        _ = try await developer.develop(photo) { stage in
            reportedStages.append(stage)
        }

        XCTAssertEqual(reportedStages, DevelopStage.allCases)
    }

    func testRecipeValuesWithinBounds() async throws {
        let developer = AnalysingDeveloper(analyser: HistogramAnalyser())
        let photo = TestFixtures.makePhoto()

        let recipe = try await developer.develop(photo) { _ in }

        // Checking conservative bounds derived from AnalysingDeveloper implementation
        XCTAssertGreaterThanOrEqual(recipe.exposure, -0.3)
        XCTAssertLessThanOrEqual(recipe.exposure, 0.5)

        XCTAssertGreaterThanOrEqual(recipe.highlights, -0.6)
        XCTAssertLessThanOrEqual(recipe.highlights, 0)

        XCTAssertGreaterThanOrEqual(recipe.shadows, 0)
        XCTAssertLessThanOrEqual(recipe.shadows, 0.4)
    }

    func testCancellationDuringDevelop() async throws {
        let developer = AnalysingDeveloper(analyser: HistogramAnalyser())
        let photo = TestFixtures.makePhoto()

        let task = Task {
            try await developer.develop(photo) { _ in }
        }
        
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Success
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
}
