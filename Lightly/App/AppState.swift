import CoreGraphics
import Foundation
import Observation

/// The screen the user is currently on.
///
/// Modelled as an explicit enum rather than a `NavigationStack` path because the
/// V1 flow is linear and shallow (spec §3), and because "one clear next step"
/// (§2.2) is far easier to guarantee when the set of reachable states is
/// enumerable and testable.
enum AppRoute: Equatable, Sendable {
    /// Launch screen with the brand mark and swipe affordance.
    case launch
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

/// Root application state.
///
/// Owns navigation, the current photograph, and the active error state. Views
/// read from it and call intent methods on it; they never mutate it directly.
/// Isolated to the main actor because every property here drives UI.
@MainActor
@Observable
final class AppState {

    // MARK: - Navigation

    /// The current screen.
    private(set) var route: AppRoute = .launch

    /// Whether the source-selection sheet is presented.
    var isSourceSheetPresented: Bool = false

    /// The source the user chose, once the sheet has been dismissed and a
    /// system picker or capture flow should be presented.
    private(set) var activeSource: PhotoSource?

    // MARK: - Content

    /// The photograph currently loaded, if any.
    private(set) var selectedPhoto: SelectedPhoto?

    /// True while a chosen asset is being decoded.
    private(set) var isLoadingPhoto: Bool = false

    // MARK: - Failure

    /// The active recoverable failure, if any (spec §28).
    ///
    /// Presentation is the view layer's concern; the state machine only records
    /// that a defined failure occurred. Cancellation never lands here.
    private(set) var activeError: LightlyError?

    // MARK: - Dependencies

    private let photoLoader: any PhotoLoading

    /// Editor view models, retained per photograph.
    ///
    /// SwiftUI may re-evaluate `body` many times; building the editor inline
    /// would discard the edit history on every re-render. Caching by photo
    /// identity means the history survives for as long as the photograph is
    /// loaded, which is what spec §27 requires.
    private var editorViewModels: [UUID: LUTEditorViewModel] = [:]

    private let libraryWriter: any PhotoLibraryWriting
    private let autoEnhancer: any AutoEnhancing
    private let lookBook: LUTLookBook
    private let lutRenderer: (any LUTRendering)?

    init(
        photoLoader: any PhotoLoading,
        libraryWriter: any PhotoLibraryWriting = PhotoKitLibraryWriter(),
        autoEnhancer: any AutoEnhancing = ModelNotBundledAutoEnhancer(),
        lookBook: LUTLookBook = .empty,
        // nil makes the editor report a failure. The composition root passes
        // the Metal renderer; the default keeps previews and launch-screen
        // tests from compiling a GPU kernel they never use.
        lutRenderer: (any LUTRendering)? = nil
    ) {
        self.photoLoader = photoLoader
        self.libraryWriter = libraryWriter
        self.autoEnhancer = autoEnhancer
        self.lookBook = lookBook
        self.lutRenderer = lutRenderer
    }

    /// Returns the editor for a photograph, creating it on first request.
    ///
    /// Creating it starts Auto at once: selecting a photo develops it
    /// (spec D2).
    func makeEditorViewModel(for photo: SelectedPhoto) -> LUTEditorViewModel {
        if let existing = editorViewModels[photo.id] {
            return existing
        }
        let viewModel = LUTEditorViewModel(
            photo: photo,
            autoEnhancer: autoEnhancer,
            lookBook: lookBook,
            renderer: lutRenderer,
            libraryWriter: libraryWriter
        )
        editorViewModels[photo.id] = viewModel
        return viewModel
    }

    // MARK: - Intents

    /// The user completed the upward swipe on the launch screen.
    func revealSourceSelection() {
        guard route == .launch else { return }
        isSourceSheetPresented = true
    }

    /// The user chose Camera or Photo Library.
    ///
    /// Dismisses the sheet and records the pending source so the view layer can
    /// present the corresponding *system* interface. Lightly presents no custom
    /// gallery here (spec §0.1).
    func selectSource(_ source: PhotoSource) {
        isSourceSheetPresented = false
        activeSource = source
    }

    /// The system picker or capture flow finished presenting.
    func clearActiveSource() {
        activeSource = nil
    }

    /// Decodes bytes returned by a system picker or the camera.
    ///
    /// Failures are mapped onto the §28 catalogue rather than propagated, so no
    /// caller can accidentally leave the UI in an indeterminate state.
    func loadPhoto(from data: Data, source: PhotoSource) async {
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }

        do {
            let photo = try await photoLoader.loadPhoto(from: data, source: source)
            if let previous = selectedPhoto, previous.id != photo.id {
                // Switching photos ends the previous session; its in-flight
                // renders must not land after the new photo is shown.
                closeEditor(for: previous.id)
            }
            selectedPhoto = photo
            route = .editor(SelectedPhotoReference(id: photo.id))
        } catch let error as LightlyError {
            present(error)
        } catch {
            // Any unexpected throw is still a defined product state; it must
            // never surface as an unhandled failure or a hung spinner.
            present(.photoLoadingFailed)
        }
    }

    /// The user backed out of the system picker or capture flow.
    ///
    /// Modelled explicitly so cancellation unwinds through one path with no
    /// side effects (spec §28, `userCancelled`).
    func cancelPhotoSelection() {
        activeSource = nil
        isLoadingPhoto = false
    }

    /// Returns to the launch screen, discarding the loaded photograph.
    ///
    /// The original asset in the user's library is untouched — Lightly never
    /// writes to it (spec §2.6).
    func returnToLaunch() {
        if let photo = selectedPhoto {
            closeEditor(for: photo.id)
        }
        selectedPhoto = nil
        route = .launch
    }

    private func closeEditor(for photoID: UUID) {
        editorViewModels.removeValue(forKey: photoID)?.close()
    }

    // MARK: - Error handling

    /// Records a failure for presentation.
    ///
    /// Cancellation is filtered out here rather than at each call site, so a
    /// future contributor cannot accidentally show the user an error banner for
    /// having changed their mind.
    func present(_ error: LightlyError) {
        guard error.isFault else { return }
        activeError = error
    }

    /// Dismisses the active failure.
    func dismissError() {
        activeError = nil
    }
}
