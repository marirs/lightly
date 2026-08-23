import PhotosUI
import SwiftUI

/// Hosts the current route and owns presentation of the system photo
/// interfaces.
///
/// System pickers are presented here rather than inside `LaunchView` so that the
/// launch screen stays a pure presentation of state, and so the picker choice
/// (spec §0.1) lives in one auditable place.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    /// Selection binding for Apple's system photo picker.
    @State private var pickerSelection: PhotosPickerItem?

    var body: some View {
        @Bindable var appState = appState

        Group {
            switch appState.route {
            case .launch:
                LaunchView()
            case .editor:
                if let photo = appState.selectedPhoto {
                    // Identified by the photo so that selecting a different
                    // photograph builds a fresh editor rather than reusing the
                    // previous one's history.
                    EditorView(
                        viewModel: appState.makeEditorViewModel(for: photo),
                        onBack: { appState.returnToLaunch() },
                        makeLooksViewModel: { appState.makeLooksViewModel(for: photo) },
                        makeExportViewModel: { recipe in
                            appState.makeExportViewModel(for: photo, recipe: recipe)
                        }
                    )
                    .id(photo.id)
                }
            }
        }
        .sheet(isPresented: $appState.isSourceSheetPresented) {
            SourceSelectionSheet()
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(LightlyRadius.sheet)
        }
        // Apple's native picker. Presenting it this way requires no Photos
        // authorisation and no NSPhotoLibraryUsageDescription entry — which is
        // precisely why §0.1 mandates it over a custom gallery.
        .photosPicker(
            isPresented: .init(
                get: { appState.activeSource == .photoLibrary },
                set: { isPresented in
                    if !isPresented { appState.cancelPhotoSelection() }
                }
            ),
            selection: $pickerSelection,
            matching: .images,
            photoLibrary: .shared()
        )
        .fullScreenCover(
            isPresented: .init(
                get: { appState.activeSource == .camera },
                set: { isPresented in
                    if !isPresented { appState.cancelPhotoSelection() }
                }
            )
        ) {
            CameraCaptureView(
                onCapture: { data in
                    appState.clearActiveSource()
                    Task { await appState.loadPhoto(from: data, source: .camera) }
                },
                onCancel: { appState.cancelPhotoSelection() }
            )
            .ignoresSafeArea()
        }
        .task(id: pickerSelection) {
            await handlePickerSelection()
        }
        .alert(
            Text("error.title", bundle: .main),
            isPresented: .init(
                get: { appState.activeError != nil },
                set: { isPresented in
                    if !isPresented { appState.dismissError() }
                }
            )
        ) {
            Button(String(localized: "error.action.dismiss")) {
                appState.dismissError()
            }
        } message: {
            if let error = appState.activeError {
                Text(error.localizedMessageKey, bundle: .main)
            }
        }
    }

    /// Loads bytes from the system picker selection.
    ///
    /// A nil selection means the sheet was dismissed without a choice, which is
    /// cancellation rather than failure (spec §28).
    private func handlePickerSelection() async {
        guard let item = pickerSelection else { return }

        // Reset immediately so re-picking the same asset still triggers `task`.
        defer { pickerSelection = nil }

        appState.clearActiveSource()

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                appState.present(.photoLoadingFailed)
                return
            }
            await appState.loadPhoto(from: data, source: .photoLibrary)
        } catch {
            appState.present(.photoLoadingFailed)
        }
    }
}
