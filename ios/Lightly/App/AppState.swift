import CoreGraphics
import Foundation
import Observation

/// The screen the user is currently on.
///
/// Modelled as an explicit enum rather than a `NavigationStack` path because the entry flow is
/// linear and shallow, and "one clear next step" is far easier to guarantee when the set of
/// reachable states is enumerable and testable.
///
/// The approved Launch (the mark alone, centred) is the system launch screen
/// (`UILaunchScreen` in project.yml); it has no route because nothing in the app holds it.
// v3 differs: v1 started on a launch screen with a swipe-up gesture that revealed a source
// sheet. The approved design replaces both with Welcome's Choose a photo and Camera buttons.
enum AppRoute: Equatable, Sendable {
    /// Mark, wordmark, tagline, Choose a photo, Camera, the privacy line and Privacy Policy.
    case welcome
    /// Camera permission was denied or is restricted.
    case cameraAccessOff
    /// The chosen photo could not be read or decoded.
    case photoCannotBeOpened
    /// A photograph is loaded and ready to develop.
    case editor(SelectedPhotoReference)
}

/// A lightweight, equatable handle to the selected photograph.
///
/// `AppRoute` must be `Equatable` for SwiftUI diffing, but `CGImage` is not a
/// meaningful thing to compare. Routing therefore carries only the identity;
/// the image itself lives on `AppState`.
struct SelectedPhotoReference: Equatable, Sendable {
    let id: UUID
}

/// What the More sheet (⋮) opens on.
enum MoreEntry: Identifiable, Equatable, Sendable {
    /// More › Preferences, Legal, About (from Welcome or the editor).
    case menu
    /// Welcome's Privacy Policy link: the policy alone; its back button returns to Welcome.
    case privacyPolicyFromWelcome

    var id: Self { self }
}

/// Produces the bytes of a chosen photo. Kept so "Try again" on "This photo can’t be opened"
/// repeats the same request (an iCloud download can succeed the second time).
typealias PhotoDataProvider = @Sendable () async throws -> Data

/// Root application state.
///
/// Owns navigation, the current photograph and the preferences. Views
/// read from it and call intent methods on it; they never mutate it directly.
/// Isolated to the main actor because every property here drives UI.
@MainActor
@Observable
final class AppState {

    // MARK: - Navigation

    /// The current screen.
    private(set) var route: AppRoute = .welcome

    /// The system picker or camera to present, if any.
    private(set) var activeSource: PhotoSource?

    /// The More sheet, if presented.
    var moreEntry: MoreEntry?

    /// No camera on this device (the simulator): a plain alert instead of a capture screen.
    var isCameraUnavailableAlertPresented = false

    // MARK: - Content

    /// The photograph currently loaded, if any.
    private(set) var selectedPhoto: SelectedPhoto?

    /// True while a chosen asset is being read and decoded.
    private(set) var isLoadingPhoto: Bool = false

    // MARK: - Preferences

    let preferences: PreferencesStore
    let favourites: FavouritePresetsStore
    let presetCatalogue: DevelopPresetCatalogue
    let releaseContent: ReleaseContent
    let appVersion: AppVersion

    // MARK: - Dependencies

    private let photoLoader: any PhotoLoading
    private let cameraAccess: any CameraAccessing

    /// The editing session of the photo being edited: one continuous session per photo.
    ///
    /// SwiftUI may re-evaluate `body` many times; building the session inline would discard the
    /// edit history on every re-render. It is kept here for as long as the photo is open, and
    /// closed (all work for it invalidated) when another photo is opened or the editor closes.
    private var editorSessions: [UUID: EditorSession] = [:]

    private let libraryWriter: any PhotoLibraryWriting
    private let autoEnhancer: any AutoEnhancing
    private let personDetector: any PersonDetecting
    /// Model, preset pack, bake cache and renderer, loaded once per launch.
    let developLibrary: DevelopLibrary

    /// The last photo request, for "Try again".
    @ObservationIgnored private var lastPhotoRequest: (source: PhotoSource, provider: PhotoDataProvider)?

    init(
        photoLoader: any PhotoLoading,
        libraryWriter: any PhotoLibraryWriting = PhotoKitLibraryWriter(),
        autoEnhancer: any AutoEnhancing = ModelNotBundledAutoEnhancer(),
        personDetector: any PersonDetecting = VisionPersonDetector(),
        // The composition root passes a library that is loading the bundled pack; the default (an
        // empty, never-loaded library) keeps entry-screen tests from compiling a GPU kernel.
        developLibrary: DevelopLibrary? = nil,
        cameraAccess: any CameraAccessing = SystemCameraAccess(),
        preferences: PreferencesStore? = nil,
        favourites: FavouritePresetsStore? = nil,
        presetCatalogue: DevelopPresetCatalogue = .empty,
        releaseContent: ReleaseContent = .none,
        appVersion: AppVersion = AppVersion(bundle: .main)
    ) {
        self.photoLoader = photoLoader
        self.libraryWriter = libraryWriter
        self.autoEnhancer = autoEnhancer
        self.personDetector = personDetector
        self.developLibrary = developLibrary ?? DevelopLibrary()
        self.cameraAccess = cameraAccess
        // Default stores are built here, not in the signature: default arguments are evaluated
        // outside the main actor, and both stores are main-actor isolated.
        self.preferences = preferences ?? PreferencesStore()
        self.favourites = favourites ?? FavouritePresetsStore(catalogue: presetCatalogue)
        self.presetCatalogue = presetCatalogue
        self.releaseContent = releaseContent
        self.appVersion = appVersion
    }

    /// The editing session for a photograph, created on first request. Creating it opens the
    /// photo and runs automatic Develop at once: selecting a photo develops it.
    func editorSession(for photo: SelectedPhoto) -> EditorSession {
        if let existing = editorSessions[photo.id] { return existing }
        let preferences = preferences
        let session = EditorSession(
            photo: photo, library: developLibrary, autoEnhancer: autoEnhancer, personDetector: personDetector,
            libraryWriter: libraryWriter,
            // Read at each save, so a switch changed in More applies to the next copy.
            saveSettings: { preferences.saveCopySettings })
        editorSessions[photo.id] = session
        return session
    }

    // MARK: - Intents: choosing a photo

    /// Welcome › Choose a photo (also "Choose a photo instead" and "Choose another photo").
    ///
    /// Apple's picker needs no Photos permission, so there is nothing to ask first.
    func chooseFromLibrary() {
        // From the editor (Saved › Choose another photo) this ends the photo's session: the picker
        // sits over Welcome, and whatever is chosen next starts a new session.
        if let photo = selectedPhoto {
            closeEditor(for: photo.id)
            selectedPhoto = nil
        }
        route = .welcome
        activeSource = .photoLibrary
    }

    /// Welcome › Camera: the system permission flow, then the system camera.
    func chooseCamera() async {
        switch cameraAccess.authorization() {
        case .authorized:
            presentCameraIfAvailable()
        case .notDetermined:
            if await cameraAccess.requestAccess() {
                presentCameraIfAvailable()
            } else {
                route = .cameraAccessOff
            }
        case .denied:
            route = .cameraAccessOff
        }
    }

    private func presentCameraIfAvailable() {
        if cameraAccess.isCaptureAvailable {
            activeSource = .camera
        } else {
            isCameraUnavailableAlertPresented = true
        }
    }

    /// The system picker or capture flow finished presenting.
    func clearActiveSource() {
        activeSource = nil
    }

    /// The user backed out of the system picker or camera: back where they were, nothing changed.
    func cancelPhotoSelection() {
        activeSource = nil
        isLoadingPhoto = false
    }

    /// Reads and decodes a chosen photo, then opens the editor.
    ///
    /// Any failure (unreadable, undownloadable or unsupported) leads to "This photo can’t be
    /// opened"; cancellation leads nowhere.
    func openPhoto(source: PhotoSource, data provider: @escaping PhotoDataProvider) async {
        lastPhotoRequest = (source, provider)
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }

        do {
            let data = try await provider()
            let photo = try await photoLoader.loadPhoto(from: data, source: source)
            if let previous = selectedPhoto, previous.id != photo.id {
                // Switching photos ends the previous session; its in-flight
                // renders must not land after the new photo is shown.
                closeEditor(for: previous.id)
            }
            selectedPhoto = photo
            lastPhotoRequest = nil
            route = .editor(SelectedPhotoReference(id: photo.id))
        } catch LightlyError.userCancelled {
            return
        } catch {
            // Every other throw is the same defined state: never a hung spinner or a silent no-op.
            route = .photoCannotBeOpened
        }
    }

    /// Decodes bytes already in hand (the camera).
    func loadPhoto(from data: Data, source: PhotoSource) async {
        await openPhoto(source: source, data: { data })
    }

    /// "This photo can’t be opened" › Try again.
    func retryLastPhoto() async {
        guard let request = lastPhotoRequest else {
            route = .welcome
            return
        }
        await openPhoto(source: request.source, data: request.provider)
    }

    // MARK: - Intents: leaving

    /// Close on a recovery screen, or leaving the editor: back to Welcome.
    ///
    /// The original asset in the user's library is untouched — Lightly never
    /// writes to it (spec §2.6).
    func returnToWelcome() {
        if let photo = selectedPhoto {
            closeEditor(for: photo.id)
        }
        selectedPhoto = nil
        lastPhotoRequest = nil
        route = .welcome
    }

    private func closeEditor(for photoID: UUID) {
        editorSessions.removeValue(forKey: photoID)?.close()
    }

    // MARK: - Intents: More

    func openMore() { moreEntry = .menu }
    func openPrivacyPolicyFromWelcome() { moreEntry = .privacyPolicyFromWelcome }
    func closeMore() { moreEntry = nil }
}
