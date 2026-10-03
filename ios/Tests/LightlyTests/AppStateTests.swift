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

/// Camera permission stub: the outcome of the system prompt is the test's choice.
private final class StubCameraAccess: CameraAccessing, @unchecked Sendable {
    var status: CameraAuthorization
    var grantsWhenAsked: Bool
    var captureAvailable: Bool
    private(set) var requestCount = 0

    init(status: CameraAuthorization, grantsWhenAsked: Bool = true, captureAvailable: Bool = true) {
        self.status = status
        self.grantsWhenAsked = grantsWhenAsked
        self.captureAvailable = captureAvailable
    }

    @MainActor var isCaptureAvailable: Bool { captureAvailable }
    func authorization() -> CameraAuthorization { status }
    func requestAccess() async -> Bool {
        requestCount += 1
        status = grantsWhenAsked ? .authorized : .denied
        return grantsWhenAsked
    }
}

@MainActor
final class AppStateTests: XCTestCase {

    private let suiteName = "AppStateTests.\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makeState(
        outcome: StubPhotoLoader.Outcome = .success,
        camera: StubCameraAccess = StubCameraAccess(status: .authorized)
    ) -> AppState {
        AppState(
            photoLoader: StubPhotoLoader(outcome: outcome),
            cameraAccess: camera,
            preferences: PreferencesStore(defaults: defaults),
            favourites: FavouritePresetsStore(defaults: defaults)
        )
    }

    // MARK: - Welcome

    func testStartsOnWelcomeWithNothingPresented() {
        let state = makeState()

        XCTAssertEqual(state.route, .welcome)
        XCTAssertNil(state.activeSource)
        XCTAssertNil(state.moreEntry)
        XCTAssertNil(state.selectedPhoto)
    }

    func testChooseAPhotoPresentsTheSystemPicker() {
        let state = makeState()

        state.chooseFromLibrary()

        XCTAssertEqual(state.activeSource, .photoLibrary)
        XCTAssertEqual(state.route, .welcome)
    }

    /// Cancelling the picker returns to Welcome with nothing changed.
    func testCancellingThePickerChangesNothing() {
        let state = makeState()
        state.chooseFromLibrary()

        state.cancelPhotoSelection()

        XCTAssertNil(state.activeSource)
        XCTAssertEqual(state.route, .welcome)
        XCTAssertNil(state.selectedPhoto)
        XCTAssertFalse(state.isLoadingPhoto)
    }

    // MARK: - Camera permission

    func testCameraAlreadyAllowedOpensTheCamera() async {
        let camera = StubCameraAccess(status: .authorized)
        let state = makeState(camera: camera)

        await state.chooseCamera()

        XCTAssertEqual(state.activeSource, .camera)
        XCTAssertEqual(camera.requestCount, 0, "No prompt once decided")
    }

    func testFirstCameraUseAsksAndOpensWhenAllowed() async {
        let camera = StubCameraAccess(status: .notDetermined, grantsWhenAsked: true)
        let state = makeState(camera: camera)

        await state.chooseCamera()

        XCTAssertEqual(camera.requestCount, 1)
        XCTAssertEqual(state.activeSource, .camera)
    }

    func testDeclinedPromptShowsCameraAccessOff() async {
        let state = makeState(camera: StubCameraAccess(status: .notDetermined, grantsWhenAsked: false))

        await state.chooseCamera()

        XCTAssertEqual(state.route, .cameraAccessOff)
        XCTAssertNil(state.activeSource)
    }

    func testPreviouslyDeniedShowsCameraAccessOffWithoutAsking() async {
        let camera = StubCameraAccess(status: .denied)
        let state = makeState(camera: camera)

        await state.chooseCamera()

        XCTAssertEqual(state.route, .cameraAccessOff)
        XCTAssertEqual(camera.requestCount, 0)
    }

    func testChooseAPhotoInsteadLeavesCameraAccessOffForThePicker() async {
        let state = makeState(camera: StubCameraAccess(status: .denied))
        await state.chooseCamera()

        state.chooseFromLibrary()

        XCTAssertEqual(state.route, .welcome)
        XCTAssertEqual(state.activeSource, .photoLibrary)
    }

    func testNoCameraOnTheDeviceShowsAnAlertNotALibraryPicker() async {
        let state = makeState(camera: StubCameraAccess(status: .authorized, captureAvailable: false))

        await state.chooseCamera()

        XCTAssertTrue(state.isCameraUnavailableAlertPresented)
        XCTAssertNil(state.activeSource)
        XCTAssertEqual(state.route, .welcome)
    }

    // MARK: - Opening a photo

    func testSuccessfulLoadRoutesToEditor() async {
        let state = makeState()

        await state.loadPhoto(from: Data(), source: .photoLibrary)

        XCTAssertNotNil(state.selectedPhoto)
        XCTAssertFalse(state.isLoadingPhoto)
        guard case .editor = state.route else {
            return XCTFail("Expected the editor route after a successful load")
        }
    }

    func testUndecodablePhotoShowsThePhotoCannotBeOpenedScreen() async {
        let state = makeState(outcome: .failure(.unsupportedImageFormat))

        await state.loadPhoto(from: Data(), source: .photoLibrary)

        XCTAssertEqual(state.route, .photoCannotBeOpened)
        XCTAssertNil(state.selectedPhoto)
        // Spec section 28 forbids leaving a spinner running after a failure.
        XCTAssertFalse(state.isLoadingPhoto)
    }

    func testUnreadableAssetShowsThePhotoCannotBeOpenedScreen() async {
        let state = makeState()

        await state.openPhoto(source: .photoLibrary) { throw LightlyError.photoLoadingFailed }

        XCTAssertEqual(state.route, .photoCannotBeOpened)
    }

    /// Try again repeats the same request: an iCloud download can succeed the second time.
    func testTryAgainRepeatsTheSameRequest() async {
        let state = makeState()
        let attempts = AttemptCounter()

        await state.openPhoto(source: .photoLibrary) {
            if await attempts.next() == 1 { throw LightlyError.photoLoadingFailed }
            return Data()
        }
        XCTAssertEqual(state.route, .photoCannotBeOpened)

        await state.retryLastPhoto()

        let count = await attempts.count
        XCTAssertEqual(count, 2)
        guard case .editor = state.route else { return XCTFail("Retry should open the photo") }
    }

    /// Spec section 28 models cancellation explicitly so that backing out has no
    /// side effects and never presents an error.
    func testCancelledLoadProducesNoErrorScreen() async {
        let state = makeState()

        await state.openPhoto(source: .photoLibrary) { throw LightlyError.userCancelled }

        XCTAssertEqual(state.route, .welcome)
    }

    // MARK: - Leaving

    func testCloseOnARecoveryScreenReturnsToWelcome() async {
        let state = makeState(outcome: .failure(.unsupportedImageFormat))
        await state.loadPhoto(from: Data(), source: .photoLibrary)

        state.returnToWelcome()

        XCTAssertEqual(state.route, .welcome)
    }

    func testLeavingTheEditorDiscardsThePhoto() async {
        let state = makeState()
        await state.loadPhoto(from: Data(), source: .camera)

        state.returnToWelcome()

        XCTAssertEqual(state.route, .welcome)
        XCTAssertNil(state.selectedPhoto)
    }

    /// One session per photo: opening another photo ends the previous photo's session, so no work
    /// for it can land later; the new photo gets a fresh session.
    func testSwitchingPhotosInvalidatesThePreviousSession() async {
        let state = makeState()
        await state.loadPhoto(from: Data(), source: .camera)
        let first = state.editorSession(for: state.selectedPhoto!)
        XCTAssertTrue(state.editorSession(for: state.selectedPhoto!) === first, "Kept for as long as the photo is open")

        await state.loadPhoto(from: Data(), source: .camera)
        let second = state.editorSession(for: state.selectedPhoto!)
        XCTAssertTrue(first.isSessionClosed)
        XCTAssertFalse(second.isSessionClosed)
        XCTAssertFalse(first === second)

        state.returnToWelcome()
        XCTAssertTrue(second.isSessionClosed)
    }

    func testChoosingAnotherPhotoFromTheEditorEndsItsSession() async {
        let state = makeState()
        await state.loadPhoto(from: Data(), source: .camera)
        let session = state.editorSession(for: state.selectedPhoto!)
        state.chooseFromLibrary()
        XCTAssertTrue(session.isSessionClosed)
        XCTAssertNil(state.selectedPhoto)
        XCTAssertEqual(state.activeSource, .photoLibrary)
    }

    // MARK: - More

    func testMoreAndThePrivacyLinkOpenTheirEntries() {
        let state = makeState()

        state.openMore()
        XCTAssertEqual(state.moreEntry, .menu)
        state.closeMore()
        XCTAssertNil(state.moreEntry)

        state.openPrivacyPolicyFromWelcome()
        XCTAssertEqual(state.moreEntry, .privacyPolicyFromWelcome)
        state.closeMore()
        XCTAssertEqual(state.route, .welcome, "Back from the policy returns to Welcome")
    }
}

/// Counts provider calls across the async boundary.
private actor AttemptCounter {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
