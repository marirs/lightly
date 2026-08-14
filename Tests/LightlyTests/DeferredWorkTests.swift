import XCTest
@testable import Lightly

/// Pins known-incomplete behaviour so it cannot become accepted silently.
///
/// These tests assert what is *not yet true*. That inversion is deliberate: an
/// unimplemented capability tends to fade into the background until someone
/// assumes it works. Here, implementing the capability breaks the test, which
/// forces the corresponding acceptance criterion to be revisited on purpose.
///
/// Each assertion names the criterion it blocks. When one of these fails
/// because the work has been done, update the assertion, tick the criterion,
/// and remove the entry from `docs/phase-2-deferred.md`.
final class DeferredWorkTests: XCTestCase {

    /// RESOLVED. Kept as a regression guard rather than deleted: orientation
    /// handling is easy to lose in a refactor and the failure is silent to
    /// anyone testing with upright screenshots.
    func testOrientationNormalisationIsImplemented() {
        let loader = ImageIOPhotoLoader()

        XCTAssertTrue(
            loader.normalisesOrientation,
            "EXIF orientation normalisation regressed; rotated photos will display wrong."
        )
    }

    /// Blocks the product expectation that editing begins from the original
    /// data, not a re-encoded copy.
    func testLosslessIngestIsStillOutstanding() {
        let loader = ImageIOPhotoLoader()

        XCTAssertFalse(
            loader.preservesOriginalEncoding,
            """
            Lossless ingest appears to be implemented. \
            If so: update this assertion and remove the item from \
            docs/phase-2-deferred.md.
            """
        )
    }

    /// Blocks any claim that Develop is functional.
    ///
    /// The shipped engine renders genuinely but performs no analysis. Until a
    /// production engine exists, the app must keep disclosing this.
    func testDevelopEngineIsStillNonProduction() {
        let developer = DebugFixedRecipeDeveloper()

        XCTAssertEqual(developer.implementationKind, .debugFixedRecipe)
        XCTAssertTrue(
            developer.implementationKind.requiresDebugDisclosure,
            "A non-production engine must always require visible disclosure."
        )
    }

    /// Blocks V1 acceptance criterion: "Toolbar is contextual."
    ///
    /// Scene classification is Phase 4. Until then every photograph resolves to
    /// `.unclassified`, so the toolbar is not genuinely contextual yet.
    func testSceneClassificationIsStillOutstanding() {
        // The production composition performs no classification, so nothing can
        // yet produce a scene other than `.unclassified`.
        XCTAssertEqual(
            SceneKind.unclassified.toolbar,
            [.looks, .magic, .repairTools, .blackAndWhite, .more],
            """
            The unclassified toolbar changed. If scene classification now \
            exists, wire it through and update docs/phase-2-deferred.md.
            """
        )
    }
}
