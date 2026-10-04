import SwiftUI
import XCTest
@testable import Lightly

/// Approved mapping (2026-10-04): iOS XXL is the prototype's large text, ×1.24 for every size.
final class ApprovedTypeScalingTests: XCTestCase {

    func testDefaultSizeIsThePrototypeSize() {
        XCTAssertEqual(ApprovedType.scaledSize(13, for: .large), 13, accuracy: 1e-9)
        XCTAssertEqual(ApprovedType.scaledSize(17, for: .large), 17, accuracy: 1e-9)
    }

    func testXXLargeIsExactlyThePrototypeLargeFactor() {
        XCTAssertEqual(ApprovedType.scaledSize(13, for: .xxLarge), 16.12, accuracy: 1e-9)
        XCTAssertEqual(ApprovedType.scaledSize(13.5, for: .xxLarge), 16.74, accuracy: 1e-9)
        XCTAssertEqual(ApprovedType.scaledSize(17, for: .xxLarge), 21.08, accuracy: 1e-9)
    }

    func testTextNeverShrinksAsTheSettingGrows() {
        let factors = DynamicTypeSize.allCases.map(ApprovedType.scaleFactor(for:))
        for (smaller, larger) in zip(factors, factors.dropFirst()) {
            XCTAssertLessThan(smaller, larger, "factors by setting: \(factors)")
        }
        XCTAssertGreaterThan(ApprovedType.scaleFactor(for: .xLarge), 1)
        XCTAssertLessThan(ApprovedType.scaleFactor(for: .xLarge), 1.24)
        XCTAssertGreaterThan(ApprovedType.scaleFactor(for: .xxxLarge), 1.24)
    }
}
