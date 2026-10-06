import CoreGraphics
import XCTest
@testable import Lightly

/// iOS Auto = Core Image auto enhancement (owner approval 2026-10-06).
@MainActor
final class CoreImageAutoTests: XCTestCase {

    func testNoFilterBakesTheIdentityLUT() throws {
        let lut = try XCTUnwrap(CoreImageAutoCorrection(filters: [], omitted: []).lut(dimension: 9))
        let identity = LUT3D.identity(dimension: 9)
        let worst = zip(lut.values, identity.values).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 1e-3, "grid order and orientation of the bake match the LUT layout")
    }

    func testTheStoredCorrectionRebuildsTheSameLUT() throws {
        let correction = CoreImageAutoCorrection(filters: [
            .init(name: "CIVibrance", parameters: ["inputAmount": .init(isVector: false, values: [0.4])]),
            .init(name: "CIToneCurve", parameters: [
                "inputPoint0": .init(isVector: true, values: [0, 0.03]), "inputPoint1": .init(isVector: true, values: [0.25, 0.3]),
                "inputPoint2": .init(isVector: true, values: [0.5, 0.56]), "inputPoint3": .init(isVector: true, values: [0.75, 0.8]),
                "inputPoint4": .init(isVector: true, values: [1, 1])]),
        ], omitted: ["CIHighlightShadowAdjust"])
        let json = try JSONSerialization.data(withJSONObject: correction.json)
        let decoded = try XCTUnwrap(CoreImageAutoCorrection(json: try JSONSerialization.jsonObject(with: json)))
        XCTAssertEqual(decoded, correction)
        XCTAssertEqual(decoded.lut(), correction.lut(), "deterministic: a restore renders exactly what was shown")
        XCTAssertNotEqual(correction.lut(), LUT3D.identity(), "the filters change colour")
    }

    func testAutoIsTheStartingPointAndEachToggleIsOneStepAndSaveCopyUsesIt() async throws {
        let photo = try await EditorTestSupport.photo(width: 1_200, height: 800)
        let session = try await EditorTestSupport.readySession(photo: photo, autoEnhancer: CoreImageAutoEnhancer())
        XCTAssertEqual(session.autoState, .applied)
        XCTAssertEqual(session.recipe.auto.modelId, CoreImageAutoCorrection.recipeModelID)
        XCTAssertEqual(session.history.count, 1, "the approved flow: Auto is the starting state, not an edit")
        let withAuto = try await session.exportedData()

        session.toggleAuto()
        XCTAssertEqual(session.history.count, 2, "switching Auto off is one Undo step")
        XCTAssertEqual(session.recipe.auto.strength, 0)
        let withoutAuto = try await session.exportedData()
        XCTAssertNotEqual(withAuto, withoutAuto, "Save copy carries the committed Auto state")
        session.undo()
        XCTAssertEqual(session.autoState, .applied)
        XCTAssertEqual(session.recipe.auto.strength, 1)
    }
}
