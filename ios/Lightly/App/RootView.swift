import OSLog
import PhotosUI
import SwiftUI
import UIKit

/// Hosts the current route and owns presentation of the system photo interfaces and the More
/// sheet.
///
/// System pickers are presented here rather than inside Welcome so that the screens stay pure
/// presentations of state, and the picker choice (spec §0.1) lives in one auditable place.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Selection binding for Apple's system photo picker.
    @State private var pickerSelection: PhotosPickerItem?
    /// True while this scene shows the editor. Scene storage survives the system ending the app
    /// and is dropped when the person force-quits it, which is exactly when a stored session should
    /// (and should not) come back.
    @SceneStorage("lightly.sceneIsEditing") private var sceneIsEditing = false

    var body: some View {
        @Bindable var appState = appState

        GeometryReader { geometry in
            routeView
                .sheet(item: $appState.moreEntry) { entry in
                    moreSheet(entry, windowSize: fullSize(of: geometry))
                }
                .overlay { signatureSheet(isTablet: fullSize(of: geometry).width > 700) }
                .overlay { if let toast = appState.toast { StageToast(text: toast) } }
        }
        .ignoresSafeArea(.keyboard)
        // Apple's native picker. Presenting it this way requires no Photos
        // authorisation and no NSPhotoLibraryUsageDescription entry — which is
        // precisely why §0.1 mandates it over a custom gallery. Cancelling it
        // leaves Welcome exactly as it was.
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
        .alert(Text("camera.unavailable.title", bundle: .main), isPresented: $appState.isCameraUnavailableAlertPresented) {
            Button(String(localized: "common.ok")) {}
        }
        .task(id: pickerSelection) {
            await handlePickerSelection()
        }
        .onChange(of: appState.preferences.appearance, initial: true) { _, appearance in
            Self.apply(appearance)
        }
        .onChange(of: appState.route) { _, route in
            if case .editor = route { sceneIsEditing = true } else { sceneIsEditing = false }
        }
        .task { await restoreIfInterrupted() }
        #if DEBUG
        .task { await Self.runDebugLaunchActions(on: appState) }
        #endif
    }

    /// Draw signature / Import signature opened from Preferences, in place of More.
    @ViewBuilder
    private func signatureSheet(isTablet: Bool) -> some View {
        switch appState.signatureSheet {
        case .draw?:
            ApprovedSheetOverlay(isTablet: isTablet, onDismiss: { appState.signatureSheet = nil }) {
                DrawSignatureSheetContent(pad: appState.signaturePad, onCancel: { appState.signatureSheet = nil },
                                          onSave: { appState.saveSignatureFromPreferences(drawn: $0) })
            }
        case .importSignature(let extracted)?:
            ApprovedSheetOverlay(isTablet: isTablet, onDismiss: { appState.signatureSheet = nil }) {
                ImportSignatureSheetContent(extracted: extracted, onCancel: { appState.signatureSheet = nil },
                                            onUse: { appState.saveSignatureFromPreferences(importedPNG: $0) })
            }
        case nil:
            EmptyView()
        }
    }

    private func restoreIfInterrupted() async {
        #if DEBUG
        // Launches that open a photo themselves (captures, UI tests) start clean.
        let arguments = DebugArguments.current
        if arguments.contains("--open-photo") || arguments.contains("--capture-commands") || arguments.contains("--reset-preferences") {
            appState.sessionStore.clear()
            return
        }
        #endif
        Self.restoreLog.notice("launch: scene was editing \(sceneIsEditing, privacy: .public)")
        await appState.restoreInterruptedSession(sceneWasEditing: sceneIsEditing)
    }

    private static let restoreLog = Logger(subsystem: "com.lightlylabs.lightly", category: "restore")

    #if DEBUG
    /// `--open-unreadable-photo` (DEBUG only): opens bytes that are not an image through the real
    /// open path, so UI tests and design captures reach "This photo can’t be opened" without a
    /// broken asset in the simulator's library.
    private static func runDebugLaunchActions(on appState: AppState) async {
        DebugCaptureTiming.mark("launched")
        let arguments = DebugArguments.current
        if arguments.contains("--open-unreadable-photo") {
            await appState.openPhoto(source: .photoLibrary) { Data("not an image".utf8) }
        }
        // `--open-photo <path>`: a file on the host (the simulator reads it directly), opened through
        // the real open path, so captures show the prototype's own photographs.
        if let flag = arguments.firstIndex(of: "--open-photo"), arguments.indices.contains(flag + 1) {
            let url = URL(fileURLWithPath: arguments[flag + 1])
            await appState.openPhoto(source: .photoLibrary) { try Data(contentsOf: url) }
        }
        // `--capture-commands <file>`: design captures step through a cell's screens in this one
        // launch (DebugCaptureDriver); runs until the app quits.
        await DebugCaptureDriver.runIfRequested(appState: appState)
    }
    #endif

    @ViewBuilder
    private var routeView: some View {
        switch appState.route {
        case .welcome:
            WelcomeView()
        case .cameraAccessOff:
            CameraAccessOffView()
        case .photoCannotBeOpened:
            PhotoCannotBeOpenedView()
        case .editor:
            if let photo = appState.selectedPhoto {
                // Identified by the photo so that selecting a different
                // photograph builds a fresh editor rather than reusing the
                // previous one's history.
                EditorScreen(
                    session: appState.editorSession(for: photo),
                    favourites: appState.favourites,
                    preferredBorder: { appState.preferences.preferredBorder },
                    onClose: { appState.returnToWelcome() },
                    onMore: { appState.openMore() },
                    onChooseAnotherPhoto: { appState.chooseFromLibrary() }
                )
                .id(photo.id)
            }
        }
    }

    // MARK: - More

    /// Phones: a sheet 88% of the screen tall with its grabber (the prototype's `.sheet`: 92%
    /// requested, capped by `max-height: 88%`). Tablets: a
    /// centred form sheet 540 pt wide (at most 92% of the width) and 70% of the height.
    @ViewBuilder
    private func moreSheet(_ entry: MoreEntry, windowSize: CGSize) -> some View {
        let isTablet = horizontalSizeClass == .regular
        let content = MoreSheet(entry: entry, initialPath: moreInitialPath)
            // The prototype's sheet puts the page header below its grabber (8 + 15 pt) on
            // phones, and 8 pt from the top of the form sheet on tablets.
            .padding(.top, isTablet ? 8 : 23)
            .presentationBackground(ApprovedColor.sheet.dynamic)
            .presentationCornerRadius(14)
        if isTablet {
            content
                .frame(idealWidth: min(540, windowSize.width * 0.92), idealHeight: windowSize.height * 0.7)
                .modifier(FittedFormSheetSizing())
                .presentationDragIndicator(.hidden)
        } else {
            // A height, not `.fraction`: fractions are of the largest sheet height, not of the
            // screen, and `.large` would shrink Welcome behind the sheet, which the design does
            // not do. The system caps the height at its largest sheet.
            content
                .presentationDetents([.height(windowSize.height * 0.88)])
                .presentationDragIndicator(.visible)
        }
    }

    /// Captures open More at a page (`pref-signature`); the app always opens its first page.
    private var moreInitialPath: [MorePage]? {
        #if DEBUG
        return appState.debugMoreInitialPath
        #else
        return nil
        #endif
    }

    private func fullSize(of geometry: GeometryProxy) -> CGSize {
        CGSize(
            width: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing,
            height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
        )
    }

    // MARK: - Appearance

    /// Applies Preferences › Appearance to every window at once, sheets and system pickers
    /// included, the moment it changes. A window override is used rather than
    /// `preferredColorScheme` because returning to System must restore the system setting
    /// immediately everywhere, including an already-presented sheet.
    static func apply(_ appearance: AppearancePreference) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = appearance.interfaceStyle
            }
        }
    }

    // MARK: - Picker

    /// Hands the system picker's selection to `AppState`.
    ///
    /// A nil selection means the sheet was dismissed without a choice, which is
    /// cancellation rather than failure (spec §28).
    private func handlePickerSelection() async {
        guard let item = pickerSelection else { return }

        // Reset immediately so re-picking the same asset still triggers `task`.
        defer { pickerSelection = nil }

        appState.clearActiveSource()
        await appState.openPhoto(source: .photoLibrary) {
            // Kept by AppState so "Try again" repeats the same request (e.g. an iCloud download).
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw LightlyError.photoLoadingFailed
            }
            return data
        }
    }
}

/// Lets the form sheet take its content's ideal size (iOS 18+). On iOS 17 the system's standard
/// form sheet size is used.
private struct FittedFormSheetSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.presentationSizing(.fitted)
        } else {
            content
        }
    }
}
