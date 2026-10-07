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
        // The scene this launch is shown in, read the same way the editor records it (EditorSession.sceneSessionID).
        // `UIApplication.openSessions` was used before; after the previous scene session had been discarded it was
        // still empty when this ran, so a restore after a system kill was declined (UI test R2, 2026-10-05).
        let current = UIApplication.shared.connectedScenes.first(where: { $0.activationState != .unattached })?.session.persistentIdentifier
            ?? UIApplication.shared.connectedScenes.first?.session.persistentIdentifier
        let open = Set(UIApplication.shared.openSessions.map(\.persistentIdentifier))
        Self.restoreLog.notice("launch: scene \(current.map { String($0.prefix(8)) } ?? "none", privacy: .public); \(open.count, privacy: .public) open scene sessions")
        await appState.restoreInterruptedSession(currentSceneSessionID: current)
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
            // A relative path names a file in the app's Documents (a device run copies it there with devicectl;
            // device execution unverified as of 2026-10-05).
            let path = arguments[flag + 1]
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL.documentsDirectory.appending(path: path)
            await appState.openPhoto(source: .photoLibrary) { try Data(contentsOf: url) }
            // `--then-open-photo <path> [--then-after <s>]` (device check, 2026-10-07): opens a second photo the way
            // the picker's result does, while the first photo's scenario (e.g. Background) is still working.
            if let next = arguments.firstIndex(of: "--then-open-photo"), arguments.indices.contains(next + 1) {
                let delay = arguments.firstIndex(of: "--then-after").flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 5
                let path = arguments[next + 1]
                let second = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL.documentsDirectory.appending(path: path)
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    // The second photo opens as a person's pick would: without the first photo's scenario.
                    var plain = DebugArguments.current
                    if let scenario = plain.firstIndex(of: "--scenario"), plain.indices.contains(scenario + 1) { plain.removeSubrange(scenario...(scenario + 1)) }
                    DebugArguments.replace(with: plain)
                    DiagnosticTrace.note("open: second photo requested (\(second.lastPathComponent))")
                    await appState.openPhoto(source: .photoLibrary) { try Data(contentsOf: second) }
                }
            }
        }
        // `--mem-cycles <n> --mem-photos <a.jpg,b.jpg>` (device memory check, 2026-10-07): n cycles of: open photo a,
        // Save copy, one Remove stroke, Save copy; open photo b; 5 s idle. The current and peak physical footprint
        // are traced after each step. Use with --keep-stored-session and --save-to-documents.
        if let flag = arguments.firstIndex(of: "--mem-cycles"), arguments.indices.contains(flag + 1), let cycles = Int(arguments[flag + 1]),
           let list = arguments.firstIndex(of: "--mem-photos"), arguments.indices.contains(list + 1) {
            let names = arguments[list + 1].split(separator: ",").map(String.init)
            await DebugMemoryCycles.run(appState: appState, cycles: cycles, photos: names)
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

#if DEBUG
/// Device memory check over repeated operations (2026-10-07): see `--mem-cycles` in RootView.
@MainActor
enum DebugMemoryCycles {
    static func mark(_ step: String) {
        DiagnosticTrace.note("mem: \(step): footprint \(SaveTiming.currentFootprintMB() ?? -1) MB, peak \(SaveTiming.peakFootprintMB() ?? -1) MB")
    }

    static func run(appState: AppState, cycles: Int, photos: [String]) async {
        mark("start")
        for cycle in 0..<cycles {
            for (index, name) in photos.enumerated() {
                let url = URL.documentsDirectory.appending(path: name)
                await appState.openPhoto(source: .photoLibrary) { try Data(contentsOf: url) }
                guard let photo = appState.selectedPhoto else { mark("cycle \(cycle) \(name): did not open"); return }
                let session = appState.editorSession(for: photo)
                await session.waitUntilReady()
                mark("cycle \(cycle) \(name) open")
                guard index == 0 else { continue }
                await save(session, "cycle \(cycle) \(name) saved")
                await session.debugRemove(points: [.init(x: 0.62, y: 0.36), .init(x: 0.72, y: 0.33)], radius: 0.03)
                mark("cycle \(cycle) \(name) removed (\(session.removeState))")
                await save(session, "cycle \(cycle) \(name) saved after remove")
            }
            try? await Task.sleep(for: .seconds(5))
            mark("cycle \(cycle) idle")
        }
        mark("cycles done")
    }

    private static func save(_ session: EditorSession, _ step: String) async {
        session.saveCopy()
        await session.debugWait { session.saveState != .saving }
        mark(step)
    }
}
#endif
