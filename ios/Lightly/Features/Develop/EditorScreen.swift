import SwiftUI

/// The approved editor (`editorHTML`) in every iOS layout: the top bar, the photo stage, the tool
/// panel and the tool navigation; before it, the loading screen (`loadingHTML`) while the photo
/// opens and Develop runs.
struct EditorScreen: View {
    let session: EditorSession
    @State private var panel: DevelopPanelModel
    @State private var tool: EditorTool = .develop
    @State private var isLeaveAlertShown = false
    @State private var shareItem: ShareItem?

    let onClose: () -> Void
    let onMore: () -> Void
    let onChooseAnotherPhoto: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    init(session: EditorSession, favourites: FavouritePresetsStore, onClose: @escaping () -> Void,
         onMore: @escaping () -> Void, onChooseAnotherPhoto: @escaping () -> Void) {
        self.session = session
        _panel = State(initialValue: DevelopPanelModel(session: session, favourites: favourites))
        self.onClose = onClose
        self.onMore = onMore
        self.onChooseAnotherPhoto = onChooseAnotherPhoto
    }

    var body: some View {
        GeometryReader { geometry in
            let screen = CGSize(width: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing,
                                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
            let layout = EditorLayout.resolve(screen: screen, horizontalSizeClass: horizontalSizeClass, verticalSizeClass: verticalSizeClass)
            ZStack {
                if session.phase == .ready {
                    editor(layout)
                } else {
                    loading(layout)
                }
                overlays(layout)
            }
        }
        .background(ApprovedColor.background.resolved(colorScheme).ignoresSafeArea())
        .task {
            session.start()
            #if DEBUG
            if let scenario = DebugScenario.current { await scenario.apply(session: session, panel: panel) }
            #endif
        }
        .alert(Text("Leave without saving?"), isPresented: $isLeaveAlertShown) {
            Button("Save copy") { session.saveCopy() }.keyboardShortcut(.defaultAction)
            Button("Discard edits", role: .destructive) { onClose() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your original photo is unchanged. Edits that are not saved as a copy will be lost.")
        }
        .alert(Text("Can’t save to Photos"), isPresented: alertBinding(.permissionDenied)) {
            Button("Open Settings") {
                session.dismissSaveState()
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }.keyboardShortcut(.defaultAction)
            Button("Not now", role: .cancel) { session.dismissSaveState() }
        } message: { Text("Allow Lightly to add photos in Settings. Your edits are kept.") }
        .alert(Text("Not enough storage"), isPresented: alertBinding(.storageFull)) {
            Button("Try again") { session.dismissSaveState(); session.saveCopy() }.keyboardShortcut(.defaultAction)
            Button("OK", role: .cancel) { session.dismissSaveState() }
        } message: { Text("Free up some space and try again. Your edits are kept.") }
        .alert(Text("Couldn’t save the copy"), isPresented: alertBinding(.failed)) {
            Button("Try again") { session.dismissSaveState(); session.saveCopy() }.keyboardShortcut(.defaultAction)
            Button("Keep editing", role: .cancel) { session.dismissSaveState() }
        } message: { Text("Something went wrong while saving. Your edits are kept and the original is unchanged.") }
        .sheet(item: $shareItem) { item in ActivityView(items: [item.url]).ignoresSafeArea() }
    }

    private func alertBinding(_ state: EditorSession.SaveState) -> Binding<Bool> {
        Binding(get: { session.saveState == state }, set: { if !$0, session.saveState == state { session.dismissSaveState() } })
    }

    private func close() {
        if session.hasUnsavedEdits { isLeaveAlertShown = true } else { onClose() }
    }

    // MARK: - Editor layouts

    @ViewBuilder
    private func editor(_ layout: EditorLayout) -> some View {
        let tools = EditorTool.available(hasPerson: session.hasPerson ?? false)
        let used: Set<EditorTool> = session.recipe.look != nil ? [.develop] : []
        let topBar = EditorTopBar(session: session, onClose: close, onSave: session.saveCopy, onMore: onMore)
        let stage = PhotoStage(image: session.isShowingOriginal ? session.originalImage : session.displayedImage,
                               showsOriginalBadge: session.isShowingOriginal) {
            if let toast = session.toast { StageToast(text: toast) }
        }
        switch layout.mode {
        case .below:
            VStack(spacing: 0) {
                topBar
                stage
                VStack(spacing: 0) {
                    CappedScrollView(maximumHeight: layout.panelMaximumHeight) { toolPanel(style: .tabs) }
                    ToolNavigation(kind: .dockScrolls, tools: tools, selected: tool, used: used, onSelect: select)
                }
                .background(ApprovedColor.background.resolved(colorScheme))
            }
        case .wide:
            VStack(spacing: 0) {
                topBar
                stage
                VStack(spacing: 0) {
                    CappedScrollView(maximumHeight: layout.panelMaximumHeight) {
                        toolPanel(style: .wrappedTabs).padding(.top, 4)
                    }
                    .frame(maxWidth: layout.contentWidth)
                    .frame(maxWidth: .infinity)
                    ToolNavigation(kind: .dockFits, tools: tools, selected: tool, used: used, onSelect: select)
                }
                .background(ApprovedColor.background.resolved(colorScheme))
            }
        case .side:
            VStack(spacing: 0) {
                topBar
                HStack(spacing: 0) {
                    stage
                    ScrollView(.vertical, showsIndicators: false) { toolPanel(style: .list) }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(width: layout.panelWidth)
                        .overlay(alignment: .leading) { ApprovedVerticalHairline() }
                    ToolNavigation(kind: .rail, tools: tools, selected: tool, used: used, onSelect: select)
                }
            }
        }
    }

    private func select(_ next: EditorTool) {
        #if DEBUG
        tool = next
        #else
        // DEFERRED(slices 3–5): in release builds the unbuilt tools stay listed but do not open; the
        // development stub exists only in DEBUG builds.
        if next == .develop { tool = next }
        #endif
    }

    @ViewBuilder
    private func toolPanel(style: DevelopPanelStyle) -> some View {
        if tool == .develop {
            DevelopPanelView(model: panel, style: style)
        } else {
            ToolStubPanel(tool: tool, roomy: style == .list)
        }
    }

    // MARK: - Loading (`loadingHTML`)

    @ViewBuilder
    private func loading(_ layout: EditorLayout) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ApprovedIconButton(icon: .close, accessibilityLabel: Text("Cancel"), identifier: "loading.cancel") {
                    session.close()
                    onClose()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 48)
            PhotoStage(image: session.displayedImage) {
                if session.phase == .opening {
                    ProgressBox(title: "Opening photo…", barFraction: 0.3, maximumWidth: layout.screen.width / 2) { EmptyView() }
                        .accessibilityIdentifier("loading.opening")
                } else {
                    ProgressBox(title: "Developing…", subtitle: "Applying thoughtful enhancements.", barFraction: 0.7,
                                maximumWidth: layout.screen.width / 2) { EmptyView() }
                        .accessibilityIdentifier("loading.developing")
                }
            }
            Color.clear.frame(height: layout.mode == .side ? 20 : 120)
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private func overlays(_ layout: EditorLayout) -> some View {
        let isTabletSheet = layout.screen.width > 700
        if session.saveState == .saving {
            // `.scrim.middle` covers the whole screen, status bar included, and centres the box in it.
            ZStack {
                ApprovedColor.scrim(colorScheme)
                ProgressBox(title: "Saving a copy…", barFraction: 0.55) {
                    Button("Cancel") { session.cancelSave() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 64, minHeight: 44)
                        .padding(.top, 6)
                        .accessibilityIdentifier("saving.cancel")
                }
                .accessibilityIdentifier("saving")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
        if case .saved(let data) = session.saveState {
            ApprovedSheetOverlay(isTablet: isTabletSheet, onDismiss: session.dismissSaveState) {
                SavedSheetContent(
                    onShare: { shareItem = ShareItem(data: data) },
                    onKeepEditing: session.dismissSaveState,
                    onChooseAnother: { session.dismissSaveState(); onChooseAnotherPhoto() })
            }
        }
        if panel.isReplaceSheetShown {
            ApprovedSheetOverlay(isTablet: isTabletSheet, onDismiss: { panel.isReplaceSheetShown = false }) {
                ReplaceFavouriteSheetContent(model: panel)
            }
        }
    }
}

/// A DEBUG-only placeholder for a tool a later slice builds. It is marked as such so it can never
/// be mistaken for the approved panel.
struct ToolStubPanel: View {
    let tool: EditorTool
    let roomy: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if roomy {
                Text(tool.title).approvedText(13, weight: .semibold)
                    .foregroundStyle(ApprovedColor.inkSecondary.resolved(colorScheme))
                    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
            }
            DevelopNotice(icon: .warn, bold: "Development stub.",
                          text: " \(tool.title) is built in slice \(tool.slice). This placeholder exists only in development builds and is not the approved panel.",
                          actions: [])
        }
        .padding(.bottom, 8)
        .accessibilityIdentifier("tool.stub.\(tool.rawValue)")
    }
}

extension ApprovedColor {
    /// `--scrim`: 32 % black in light, 50 % in dark.
    static func scrim(_ scheme: ColorScheme) -> Color { .black.opacity(scheme == .dark ? 0.5 : 0.32) }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL

    /// The saved JPEG as a file named for the share sheet ("Lightly copy").
    init(data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lightly copy.jpg")
        try? data.write(to: url, options: .atomic)
        self.url = url
    }
}

/// The system share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// `.toast`: bottom-centre of the stage, 24 pt up, dark translucent.
struct StageToast: View {
    let text: String
    var body: some View {
        Text(text)
            .approvedText(13.5)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.9)))
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 24)
            .accessibilityIdentifier("editor.toast")
    }
}
