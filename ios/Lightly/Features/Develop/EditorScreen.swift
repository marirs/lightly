import SwiftUI

/// The approved editor (`editorHTML`) in every iOS layout: the top bar, the photo stage, the tool
/// panel and the tool navigation; before it, the loading screen (`loadingHTML`) while the photo
/// opens and Develop runs.
struct EditorScreen: View {
    let session: EditorSession
    @State private var panel: DevelopPanelModel
    @State private var backgroundPanel: BackgroundPanelModel
    @State private var portraitPanel: PortraitPanelModel
    /// Change background › Image: dragging the photo moves the background.
    @State private var replacementDragStart: (x: Double, y: Double)?
    /// Refine edges: the stroke being drawn (source coordinates).
    @State private var refinePoints: [EditRecipe.Point] = []
    @State private var tool: EditorTool = .develop
    #if DEBUG
    /// Capture sessions: the sequence this screen finished for (DebugCaptureDriver).
    @State private var captureReadySequence: String?
    #endif
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
        _backgroundPanel = State(initialValue: BackgroundPanelModel(session: session))
        _portraitPanel = State(initialValue: PortraitPanelModel(session: session))
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
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if let captureReadySequence {
                // Invisible and outside every approved element; only the capture test reads it.
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: "capture ready"))
                    .accessibilityIdentifier("capture.ready.\(captureReadySequence)")
            }
        }
        .transaction { transaction in
            if DebugCaptureDriver.isActive {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
        #endif
        .task {
            session.start()
            #if DEBUG
            if let scenario = DebugScenario.current {
                let ui = scenario.editorUI
                if ui.tool != .develop {
                    await session.waitUntilReady()
                    select(ui.tool)
                    backgroundPanel.mode = ui.backgroundMode
                    backgroundPanel.kind = ui.backgroundKind
                    portraitPanel.tab = ui.portraitTab
                    if ui.tool == .background, !["bg-separating", "bg-failed"].contains(scenario.screenID) {
                        session.analyseSubjectIfNeeded()
                        await session.debugWaitForSubject()
                    }
                    await scenario.applyBackgroundAndPortrait(session: session)
                } else {
                    await scenario.apply(session: session, panel: panel)
                    await scenario.applyBackgroundAndPortrait(session: session)
                }
                await markCaptureReady(scenario)
            }
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
        let used = usedTools
        let topBar = EditorTopBar(session: session, onClose: close, onSave: session.saveCopy, onMore: onMore)
        let stage = PhotoStage(image: session.isShowingOriginal ? session.originalImage : session.displayedImage,
                               showsOriginalBadge: session.isShowingOriginal,
                               overlay: { if let toast = session.toast { StageToast(text: toast) } },
                               marks: { if !session.isShowingOriginal { stageMarks } })
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

    #if DEBUG
    /// Capture sessions: the screen is ready once its renders for the current recipe have
    /// landed, its save state is the one the screen shows, and that frame is on the display.
    /// Then `capture.ready.<sequence>` appears for the UI test (no fixed waits).
    private func markCaptureReady(_ scenario: DebugScenario) async {
        DebugCaptureTiming.mark("scenario")
        // The launch-per-screen path only measures (its test still waits fixed times); the
        // one-launch runner waits for this before it photographs the screen.
        switch scenario.screenID {
        case "saved": await session.debugWait { if case .saved = session.saveState { true } else { false } }
        case "saving": await session.debugWait { session.saveState == .saving }
        default: break
        }
        await session.settleRendering()
        DebugCaptureTiming.mark("rendered")
        await DebugCaptureDriver.awaitScreenCommit()
        DebugCaptureTiming.mark("committed")
        guard DebugCaptureDriver.isActive, let sequence = DebugCaptureDriver.sequence else { return }
        captureReadySequence = sequence
        DebugCaptureDriver.reportReady(sequence)
    }
    #endif

    /// Prototype `toolUsed`: a dot on tools that hold edits.
    private var usedTools: Set<EditorTool> {
        var used: Set<EditorTool> = []
        let r = session.recipe
        if r.look != nil { used.insert(.develop) }
        if r.tools.background.replacement != nil || r.tools.background.focus.blur > 0 { used.insert(.background) }
        if r.tools.portrait.faces.contains(where: { portraitPanel.changeCount(for: $0) > 0 }) { used.insert(.portrait) }
        return used
    }

    private func select(_ next: EditorTool) {
        if next != tool {
            // Prototype `tool:` resets the sub-tool.
            backgroundPanel.mode = .focus
            backgroundPanel.kind = nil
            portraitPanel.tab = .skin
        }
        #if DEBUG
        tool = next
        #else
        // DEFERRED(slices 4–5): in release builds the unbuilt tools stay listed but do not open; the
        // development stub exists only in DEBUG builds.
        if [.develop, .background, .portrait].contains(next) { tool = next }
        #endif
    }

    @ViewBuilder
    private func toolPanel(style: DevelopPanelStyle) -> some View {
        switch tool {
        case .develop: DevelopPanelView(model: panel, style: style)
        case .background: BackgroundPanelView(model: backgroundPanel, roomy: style == .list, wraps: style == .wrappedTabs)
        case .portrait: PortraitPanelView(model: portraitPanel, roomy: style == .list, wraps: style == .wrappedTabs)
        default: ToolStubPanel(tool: tool, roomy: style == .list)
        }
    }

    // MARK: - Stage marks and gestures (prototype `marksFor`)

    @ViewBuilder
    private var stageMarks: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                switch tool {
                case .background:
                    backgroundMarks(size: size)
                case .portrait:
                    if let people = session.people {
                        FaceRingsMark(faces: people.usableFaces.map(\.ring), selected: portraitPanel.selectedFace,
                                      people: people.usableFaces.isEmpty ? people.people + people.faces.map(\.box) : [],
                                      onSelect: { portraitPanel.selectedFace = $0 })
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func backgroundMarks(size: CGSize) -> some View {
        let background = session.recipe.tools.background
        switch (session.subjectState, backgroundPanel.mode) {
        case (.separating, _):
            // `.progress` sits at the centre of the photo (left/top 50 %, translate −50 %).
            StageOperationProgress(title: "Finding the subject…", identifier: "background.separating",
                                   onCancel: session.cancelSubjectSeparation)
                .position(x: size.width / 2, y: size.height / 2)
        case (.ready, .refine):
            MatteTintMark(matte: session.matteImage)
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        refinePoints.append(.init(x: min(max(value.location.x / size.width, 0), 1), y: min(max(value.location.y / size.height, 0), 1)))
                    }
                    .onEnded { _ in
                        guard !refinePoints.isEmpty else { return }
                        session.addRefinement(.init(mode: backgroundPanel.brush, radius: backgroundPanel.brushRadius, points: refinePoints))
                        refinePoints = []
                    })
                .accessibilityHidden(true)
        case (.ready, .change):
            if case .image(let asset, let x, let y, let scale)? = background.replacement {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let start = replacementDragStart ?? (x, y)
                            replacementDragStart = start
                            let nx = min(max(start.x - value.translation.width / size.width * 100, 0), 100)
                            let ny = min(max(start.y - value.translation.height / size.height * 100, 0), 100)
                            session.previewBackground { $0.replacement = .image(asset, x: nx.rounded(), y: ny.rounded(), scale: scale) }
                        }
                        .onEnded { value in
                            let start = replacementDragStart ?? (x, y)
                            replacementDragStart = nil
                            let nx = min(max(start.x - value.translation.width / size.width * 100, 0), 100)
                            let ny = min(max(start.y - value.translation.height / size.height * 100, 0), 100)
                            session.commitBackground { $0.replacement = .image(asset, x: nx.rounded(), y: ny.rounded(), scale: scale) }
                        })
                    .accessibilityHidden(true)
            }
        case (.ready, .focus), (.noSubject, _):
            let target = background.focus.target.map { CGPoint(x: $0.x, y: $0.y) }
                ?? session.defaultFocusTarget.map { CGPoint(x: $0.x, y: $0.y) }
            if session.subjectState == .ready, let target { FocusTargetMark(point: target) }
            Color.clear.contentShape(Rectangle())
                .onTapGesture { location in
                    session.setFocusTarget(x: location.x / size.width, y: location.y / size.height)
                }
                .accessibilityHidden(true)
        default:
            EmptyView()
        }
    }

    // MARK: - Loading (`loadingHTML`)

    @ViewBuilder
    private func loadingProgress(maximumWidth: CGFloat) -> some View {
        if session.phase == .opening {
            ProgressBox(title: "Opening photo…", barFraction: 0.3, maximumWidth: maximumWidth) { EmptyView() }
                .accessibilityIdentifier("loading.opening")
        } else {
            ProgressBox(title: "Developing…", subtitle: "Applying thoughtful enhancements.", barFraction: 0.7,
                        maximumWidth: maximumWidth) { EmptyView() }
                .accessibilityIdentifier("loading.developing")
        }
    }

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
            // The prototype puts `.progress` among the photo's marks (inside `.imgbox`), so CSS
            // shrink-to-fit caps it at half the fitted photo's width, not the screen's.
            PhotoStage(image: session.displayedImage, overlay: { EmptyView() }, marks: {
                GeometryReader { photo in
                    loadingProgress(maximumWidth: photo.size.width / 2)
                        .position(x: photo.size.width / 2, y: photo.size.height / 2)
                }
            })
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
