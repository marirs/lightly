import CoreGraphics
import XCTest
@testable import Lightly

/// Photo loader stub whose outcome the test dictates.
private struct StubPhotoLoader: PhotoLoading {
    enum Outcome: Sendable {
        case success
        case failure(LightlyError)
    }

    let outcome: Outcome

    // The stub sidesteps decoding entirely, so it neither normalises
    // orientation nor re-encodes. Reported as `true` so this stub never stands
    // in for the shipping loader's deferred work (see DeferredWorkTests).
    let normalisesOrientation = true
    let preservesOriginalEncoding = true

    func loadPhoto(from data: Data, source: PhotoSource) async throws -> SelectedPhoto {
        switch outcome {
        case .success:
            return SelectedPhoto(
                image: Self.makeImage(),
                source: source,
                originalData: Data()
            )
        case .failure(let error):
            throw error
        }
    }

    /// Smallest valid image that satisfies the domain model.
    static func makeImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        // Force-unwrapping is confined to test scaffolding; a failure here means
        // the test environment itself is broken, which should fail loudly.
        return context!.makeImage()!
    }
}

@MainActor
final class AppStateTests: XCTestCase {

    // MARK: - Navigation

    func testStartsOnLaunchRoute() {
        let state = AppState(photoLoader: StubPhotoLoader(outcome: .success))

        XCTAssertEqual(state.route, .launch)
        XCTAssertFalse(state.isSourceSheetPresented)
        XCTAssertNil(state.selectedPhoto)
    }

    func testSwipeRevealsSourceSheet() {
        let state = AppState(photoLoader: StubPhotoLoader(outcome: .success))

        state.revealSourceSelection()

        XCTAssertTrue(state.isSourceSheetPresented)
    }

    func testSelectingSourceDismissesSheetAndRecordsSource() {
        let state = AppState(photoLoader: StubPhotoLoader(outcome: .success))
        state.revealSourceSelection()

        state.selectSource(.photoLibrary)

        XCTAssertFalse(state.isSourceSheetPresented)
        XCTAssertEqual(state.activeSource, .photoLibrary)
    }

    // MARK: - Loading

    func testSuccessfulLoadRoutesToEditor() async {
        let state = AppState(photoLoader: StubPhotoLoader(outcome: .success))

        await state.loadPhoto(from: Data(), source: .photoLibrary)

        XCTAssertNotNil(state.selectedPhoto)
        XCTAssertNil(state.activeError)
        XCTAssertFalse(state.isLoadingPhoto)
        guard case .editor = state.route else {
            return XCTFail("Expected the editor route after a successful load")
        }
    }

    func testFailedLoadStaysOnLaunchAndSurfacesDefinedError() async {
        let state = AppState(
            photoLoader: StubPhotoLoader(outcome: .failure(.unsupportedImageFormat))
        )

        await state.loadPhoto(from: Data(), source: .photoLibrary)

        XCTAssertEqual(state.route, .launch)
        XCTAssertNil(state.selectedPhoto)
        XCTAssertEqual(state.activeError, .unsupportedImageFormat)
        // Spec section 28 forbids leaving a spinner running after a failure.
        XCTAssertFalse(state.isLoadingPhoto)
    }

    // MARK: - Cancellation

    /// Spec section 28 models cancellation explicitly so that backing out has no
    /// side effects and never presents an error.
    func testCancellationProducesNoErrorAndNoSideEffects() {
        let state = AppState(photoLoader: StubPhotoLoader(outcome: .success))
        state.selectSource(.camera)

        state.cancelPhotoSelection()

        XCTAssertNil(state.activeSource)
        XCTAssertNil(state.activeError)
        XCTAssertFalse(state.isLoadingPhoto)
        XCTAssertEqual(state.route, .launch)
    }

    func testUserCancelledIsNeverPresentedAsAnError() {
        let state = AppState(photoLoader: StubPhotoLoader(outcome: .success))

        state.present(.userCancelled)

        XCTAssertNil(state.activeError)
    }

    // MARK: - Returning

    func testReturningToLaunchDiscardsThePhoto() async {
        let state = AppState(photoLoader: StubPhotoLoader(outcome: .success))
        await state.loadPhoto(from: Data(), source: .camera)

        state.returnToLaunch()

        XCTAssertEqual(state.route, .launch)
        XCTAssertNil(state.selectedPhoto)
    }
}
