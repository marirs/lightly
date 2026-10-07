import SwiftUI

/// The approved editor (`editorHTML`) in every iOS layout: the top bar, the photo stage, the tool
/// panel and the tool navigation; before it, the loading screen (`loadingHTML`) while the photo
/// opens and Develop runs.
struct EditorScreen: View {
    let session: EditorSession
    @State private var panel: DevelopPanelModel
    @State private var backgroundPanel: BackgroundPanelModel
    @State private var portraitPanel: PortraitPanelModel
    @State private var editPanel: EditPanelModel
    @State private var effectsPanel: EffectsPanelModel
    @State private var borderPanel: BorderPanelModel
    @State private var watermarkPanel: WatermarkPanelModel
    /// Watermark: the anchor when a drag on the photo began.
    @State private var watermarkDragStart: (x: Double, y: Double)?
    /// Edit › Remove: the stroke being brushed (source coordinates).
    @State private var removePoints: [EditRecipe.Point] = []
    /// Edit › Crop: the rect when a corner drag or pinch began.
    /// The crop rectangle and the handle when a crop drag began.
    @State private var cropGestureStart: (rect: EditRecipe.Rect, handle: CropGeometry.Handle)?
    /// The rectangle shown while a crop drag moves (committed when it ends).
    @State private var cropDraft: EditRecipe.Rect?
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

    init(session: EditorSession, favourites: FavouritePresetsStore,
         preferredBorder: @escaping @MainActor () -> PreferredBorder = { .none }, onClose: @escaping () -> Void,
         onMore: @escaping () -> Void, onChooseAnotherPhoto: @escaping () -> Void) {
        self.session = session
        _panel = State(initialValue: DevelopPanelModel(session: session, favourites: favourites))
        _backgroundPanel = State(initialValue: BackgroundPanelModel(session: session))
        _portraitPanel = State(initialValue: PortraitPanelModel(session: session))
        _editPanel = State(initialValue: EditPanelModel(session: session))
        _effectsPanel = State(initialValue: EffectsPanelModel(session: session))
        let watermarkPanel = WatermarkPanelModel(session: session, signatures: session.signatures)
        _watermarkPanel = State(initialValue: watermarkPanel)
        _borderPanel = State(initialValue: BorderPanelModel(session: session, watermarkPanel: watermarkPanel, preferredBorder: preferredBorder))
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
                    .task(id: captureReadySequence) { await captureMarkerAppeared(captureReadySequence) }
            }
        }
        .transaction { transaction in
            if DebugCaptureDriver.isActive {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
        #endif
        // Free crop shows the uncropped frame while Edit › Crop is open (owner amendment 2026-10-05).
        .onChange(of: tool == .edit && editPanel.sub == .crop, initial: true) { _, cropping in session.isCropEditing = cropping }
        .task {
            session.start()
            #if DEBUG
            if DebugScenario.current?.screenID == "bg-then-develop" {
                await debugBackgroundThenDevelop()
                return
            }
            if let scenario = DebugScenario.current {
                let ui = scenario.editorUI
                if ui.tool != .develop {
                    DiagnosticTrace.note("scenario \(scenario.screenID): started, waiting until ready")
                    await session.waitUntilReady()
                    DiagnosticTrace.note("scenario \(scenario.screenID): ready")
                    select(ui.tool)
                    backgroundPanel.mode = ui.backgroundMode
                    backgroundPanel.kind = ui.backgroundKind
                    portraitPanel.tab = ui.portraitTab
                    editPanel.sub = ui.editSub
                    editPanel.group = ui.editGroup
                    effectsPanel.sub = ui.effectsSub
                    watermarkPanel.shownType = ui.watermarkType
                    if ui.tool == .background, !["bg-separating", "bg-failed", "bg-cancel-flow"].contains(scenario.screenID) {
                        session.analyseSubjectIfNeeded(needsDepth: ui.backgroundMode == .focus)
                        DiagnosticTrace.note("scenario \(scenario.screenID): waiting for the subject")
                        await session.debugWaitForSubject()
                        DiagnosticTrace.note("scenario \(scenario.screenID): subject \(String(describing: session.subjectState))")
                    }
                    await scenario.applyBackgroundAndPortrait(session: session)
                    await scenario.applyEditAndEffects(session: session, brushRadius: editPanel.brushRadius)
                    await scenario.applyWatermark(session: session, panel: watermarkPanel)
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
                               outlinesCanvas: !session.isShowingOriginal && session.recipe.tools.border.type != .none,
                               imageBox: session.isShowingOriginal ? CGRect(x: 0, y: 0, width: 1, height: 1) : session.displayedImageBox,
                               onPhotoSize: session.isShowingOriginal ? nil : { session.setDisplayedPhotoSize($0) },
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
        case "share":
            // Saved › Share: the system share sheet with the saved copy (approved `share`).
            await session.debugWait { if case .saved = session.saveState { true } else { false } }
            if case .saved(let data) = session.saveState { shareItem = ShareItem(data: data) }
            // The system share sheet loads its share services the first time it opens (seconds in the Simulator).
            try? await Task.sleep(for: .seconds(5))
        case "saving": await session.debugWait { session.saveState == .saving }
        default: break
        }
        await session.debugAwaitPendingAnalysis()
        await session.settleRendering()
        DebugCaptureTiming.mark("rendered")
        guard DebugCaptureDriver.isActive, let sequence = DebugCaptureDriver.sequence else {
            await DebugCaptureDriver.awaitScreenCommit()
            DebugCaptureTiming.mark("committed")
            return
        }
        // The marker view appears in the same render pass as every state change made before it
        // (tool, panel, marks, photo); its onAppear then waits for display refreshes and only then
        // reports ready (captureMarkerAppeared).
        captureReadySequence = sequence
    }

    private func captureMarkerAppeared(_ sequence: String) async {
        await DebugCaptureDriver.awaitScreenCommit()
        DebugCaptureTiming.mark("committed")
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
        if editPanel.isUsed { used.insert(.edit) }
        if effectsPanel.isUsed { used.insert(.effects) }
        if watermarkPanel.isUsed { used.insert(.watermark) }
        if borderPanel.isUsed { used.insert(.border) }
        return used
    }

    #if DEBUG
    /// Device check (2026-10-07, not a prototype screen): Background's analysis started, then Develop with a ruler drag
    /// across 12 stops while it runs; traces how many preview frames were shown during the drag and the analysis state.
    private func debugBackgroundThenDevelop() async {
        await session.debugWait { session.phase == .ready }
        select(.background)
        backgroundPanel.mode = .focus
        session.analyseSubjectIfNeeded(needsDepth: true)
        try? await Task.sleep(for: .milliseconds(300))
        select(.develop)
        DiagnosticTrace.note("scenario bg-then-develop: Develop selected; subject \(session.subjectState), depth \(session.depthState)")
        let before = session.publishedRenderCount
        let started = ContinuousClock.now
        var longestWait = Duration.zero
        var lastCount = before, lastChange = started
        for stop in 1...12 {
            panel.dragChanged(to: stop)
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(10))
                if session.publishedRenderCount != lastCount {
                    longestWait = max(longestWait, ContinuousClock.now - lastChange)
                    lastCount = session.publishedRenderCount; lastChange = ContinuousClock.now
                }
            }
        }
        panel.dragEnded(at: 12)
        let elapsed = ContinuousClock.now - started
        DiagnosticTrace.note("scenario bg-then-develop: drag of 12 stops in \(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) ms, \(session.publishedRenderCount - before) frames shown, longest gap between frames \(longestWait.components.seconds * 1000 + longestWait.components.attoseconds / 1_000_000_000_000_000) ms; subject \(session.subjectState), depth \(session.depthState)")
    }
    #endif

    private func select(_ next: EditorTool) {
        if next != tool {
            // Prototype `tool:` resets the sub-tool.
            backgroundPanel.mode = .focus
            backgroundPanel.kind = nil
            portraitPanel.tab = .skin
            editPanel.sub = .crop
            editPanel.group = .light
            effectsPanel.sub = .leak
            borderPanel.shownType = nil
            watermarkPanel.shownType = nil
            if next == .border { borderPanel.openOnPreferredType() }
        }
        tool = next
    }

    @ViewBuilder
    private func toolPanel(style: DevelopPanelStyle) -> some View {
        switch tool {
        case .develop: DevelopPanelView(model: panel, style: style)
        case .background: BackgroundPanelView(model: backgroundPanel, roomy: style == .list, wraps: style == .wrappedTabs)
        case .portrait: PortraitPanelView(model: portraitPanel, roomy: style == .list, wraps: style == .wrappedTabs)
        case .edit: EditPanelView(model: editPanel, roomy: style == .list, wraps: style == .wrappedTabs)
        case .effects: EffectsPanelView(model: effectsPanel, roomy: style == .list, wraps: style == .wrappedTabs)
        case .watermark: WatermarkPanelView(model: watermarkPanel, roomy: style == .list, wraps: style == .wrappedTabs)
        case .border: BorderPanelView(model: borderPanel, roomy: style == .list, wraps: style == .wrappedTabs)
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
                        FaceRingsMark(faces: people.usableFaces.map { toFrame($0.ring) }, selected: portraitPanel.selectedFace,
                                      people: people.unusableMarks.map(toFrame),
                                      onSelect: { portraitPanel.selectedFace = $0 })
                    }
                case .edit:
                    editMarks(size: size)
                case .effects:
                    if effectsPanel.sub == .leak { leakDragArea(size: size) }
                    if effectsPanel.picksOnTap { selectiveColourTapArea(size: size) }
                case .watermark:
                    if watermarkPanel.isUsed, !watermarkPanel.isOnBorder { watermarkDragArea(size: size) }
                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func backgroundMarks(size: CGSize) -> some View {
        let background = session.recipe.tools.background
        switch (session.backgroundContent(needsDepth: backgroundPanel.mode == .focus), backgroundPanel.mode) {
        case (.finding, _) where session.subjectState == .separating:
            // `.progress` sits at the centre of the photo (left/top 50 %, translate −50 %).
            StageOperationProgress(title: "Finding the subject…", identifier: "background.separating",
                                   onCancel: session.cancelSubjectSeparation)
                .position(x: size.width / 2, y: size.height / 2)
        case (_, _) where session.depthProgressVisible(needsDepth: backgroundPanel.mode == .focus):
            // PROPOSED copy (owner approval pending, 2026-10-07): depth's own progress, distinct from the subject's.
            StageOperationProgress(title: "Estimating depth…", identifier: "background.depth",
                                   onCancel: session.cancelSubjectSeparation)
                .position(x: size.width / 2, y: size.height / 2)
        case (.controls, .refine):
            MatteTintMark(matte: session.displayMatteImage)
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = toSource(CGPoint(x: value.location.x / size.width, y: value.location.y / size.height))
                        refinePoints.append(.init(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)))
                    }
                    .onEnded { _ in
                        guard !refinePoints.isEmpty else { return }
                        session.addRefinement(.init(mode: backgroundPanel.brush, radius: backgroundPanel.brushRadius, points: refinePoints))
                        refinePoints = []
                    })
                .accessibilityHidden(true)
        case (.controls, .change):
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
        case (.controls, .focus), (.noSubject, _):
            let target = background.focus.target.map { CGPoint(x: $0.x, y: $0.y) }
                ?? session.defaultFocusTarget.map { CGPoint(x: $0.x, y: $0.y) }
            if session.subjectState == .ready, let target { FocusTargetMark(point: toFrame(target)) }
            Color.clear.contentShape(Rectangle())
                .onTapGesture { location in
                    let p = toSource(CGPoint(x: location.x / size.width, y: location.y / size.height))
                    session.setFocusTarget(x: p.x, y: p.y)
                }
                .accessibilityHidden(true)
        default:
            EmptyView()
        }
    }

    // MARK: - Geometry mapping for marks and touches

    /// A normalised source point on the displayed frame (through Edit's geometry).
    private func toFrame(_ point: CGPoint) -> CGPoint {
        let transform = session.geometryTransform
        return transform.isIdentity ? point : transform.frame(fromSource: point)
    }

    /// A normalised touch on the displayed frame in source coordinates.
    private func toSource(_ point: CGPoint) -> CGPoint {
        let transform = session.geometryTransform
        return transform.isIdentity ? point : transform.source(fromFrame: point)
    }

    /// A source rect (face box) on the frame: its centre mapped, its size scaled.
    // Rotation by straighten or perspective is not applied to the ring's shape (a few degrees at
    // most); its centre follows the face exactly.
    private func toFrame(_ rect: EditRecipe.Rect) -> EditRecipe.Rect {
        let transform = session.geometryTransform
        guard !transform.isIdentity else { return rect }
        let centre = transform.frame(fromSource: CGPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2))
        let turned = transform.frameWidth > 0 && session.recipe.tools.edit.geometry.quarterTurns % 2 == 1
        let sw = Double(transform.sourceWidth), sh = Double(transform.sourceHeight)
        let width = (turned ? rect.height * sh : rect.width * sw) / Double(transform.frameWidth)
        let height = (turned ? rect.width * sw : rect.height * sh) / Double(transform.frameHeight)
        return .init(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
    }

    // MARK: - Edit and Effects marks (prototype `marksFor`)

    @ViewBuilder
    private func editMarks(size: CGSize) -> some View {
        switch editPanel.sub {
        case .crop:
            CropFrameMark(rect: cropDraft ?? session.recipe.tools.edit.geometry.cropRect)
            cropGestureArea(size: size)
            #if DEBUG
            // UI tests only (--expose-crop): the committed aspect and rectangle, to check each handle's effect.
            if DebugArguments.current.contains("--expose-crop") {
                let g = session.recipe.tools.edit.geometry
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("edit.cropRect")
                    .accessibilityValue(String(format: "%@ %.4f %.4f %.4f %.4f", g.cropAspect.rawValue, g.cropRect.x, g.cropRect.y,
                                               g.cropRect.width, g.cropRect.height))
                    .allowsHitTesting(false)
            }
            #endif
        case .straighten, .perspective:
            ThirdsGridMark()
        case .remove:
            RemoveStrokesMark(strokes: removeStrokesOnFrame(size: size))
            if session.removeState == .removing {
                StageOperationProgress(title: "Removing…", identifier: "edit.removing", onCancel: session.cancelRemove)
                    .position(x: size.width / 2, y: size.height / 2)
            } else {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let p = toSource(CGPoint(x: value.location.x / size.width, y: value.location.y / size.height))
                            removePoints.append(.init(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)))
                        }
                        .onEnded { _ in
                            guard !removePoints.isEmpty else { return }
                            session.removeStroke(points: removePoints, radius: editPanel.brushRadius)
                            removePoints = []
                        })
                    .accessibilityHidden(true)
            }
        default:
            EmptyView()
        }
    }

    /// The applied strokes, the stroke being removed (or failed) and the one being brushed, on
    /// the frame, with the brush radius in frame points.
    private func removeStrokesOnFrame(size: CGSize) -> [(points: [CGPoint], radius: CGFloat)] {
        let transform = session.geometryTransform
        let sourceLongEdge = Double(max(transform.sourceWidth, transform.sourceHeight))
        // Frame points per source pixel (the frame is displayed at `size`).
        let pointsPerPixel = Double(size.width) / Double(transform.frameWidth)
        var strokes = session.recipe.tools.edit.remove.strokes.map { ($0.points, $0.radius) }
        if let pending = session.pendingRemoveStroke { strokes.append((pending.points, pending.radius)) }
        if !removePoints.isEmpty { strokes.append((removePoints, editPanel.brushRadius)) }
        return strokes.map { points, radius in
            (points.map { toFrame(CGPoint(x: $0.x, y: $0.y)) }, CGFloat(radius * sourceLongEdge * pointsPerPixel))
        }
    }

    /// Free crop (owner amendment 2026-10-05): the stage shows the straightened frame uncropped
    /// (`EditorSession.isCropEditing`); drag a corner or an edge to resize, inside to move. An aspect preset locks the
    /// ratio on every handle; Free leaves it unconstrained. The drag shows the rectangle; its end is one undo step.
    private func cropGestureArea(size: CGSize) -> some View {
        Color.clear.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let geometry = session.recipe.tools.edit.geometry
                    if cropGestureStart == nil {
                        guard let handle = CropGeometry.handle(at: value.startLocation, rect: geometry.cropRect, size: size) else { return }
                        cropGestureStart = (geometry.cropRect, handle)
                    }
                    guard let start = cropGestureStart else { return }
                    cropDraft = draggedCrop(start, by: value.translation, size: size)
                }
                .onEnded { value in
                    guard let start = cropGestureStart else { return }
                    let rect = draggedCrop(start, by: value.translation, size: size)
                    cropGestureStart = nil
                    cropDraft = nil
                    session.commitEdit { Self.setCrop(&$0.geometry, rect) }
                })
            .accessibilityHidden(true)
    }

    private func draggedCrop(_ start: (rect: EditRecipe.Rect, handle: CropGeometry.Handle), by translation: CGSize, size: CGSize) -> EditRecipe.Rect {
        let geometry = session.recipe.tools.edit.geometry
        let frame = GeometryTransform.turnedSize(geometry, sourceWidth: session.photo.image.width, sourceHeight: session.photo.image.height)
        return CropGeometry.dragged(start.rect, handle: start.handle,
                                    dx: Double(translation.width / max(size.width, 1)), dy: Double(translation.height / max(size.height, 1)),
                                    ratio: GeometryTransform.ratio(geometry.cropAspect),
                                    frameAspect: Double(frame.width) / Double(max(frame.height, 1)))
    }

    /// Cropping an uncropped photo makes the aspect Free; a fixed aspect is kept.
    private static func setCrop(_ geometry: inout EditRecipe.Geometry, _ rect: EditRecipe.Rect) {
        geometry.cropRect = rect
        if geometry.cropAspect == .original, rect != .init(x: 0, y: 0, width: 1, height: 1) { geometry.cropAspect = .free }
    }

    /// Light Leaks: drag on the photo to move the leak (preview while dragging, one step at the end).
    private func leakDragArea(size: CGSize) -> some View {
        Color.clear.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let x = min(max(value.location.x / size.width * 100, 0), 100).rounded()
                    let y = min(max(value.location.y / size.height * 100, 0), 100).rounded()
                    session.previewEffects { $0.lightLeak.x = x; $0.lightLeak.y = y }
                }
                .onEnded { value in
                    let x = min(max(value.location.x / size.width * 100, 0), 100).rounded()
                    let y = min(max(value.location.y / size.height * 100, 0), 100).rounded()
                    session.commitEffects { $0.lightLeak.x = x; $0.lightLeak.y = y }
                })
            .accessibilityHidden(true)
    }

    /// Selective Colour: a tap keeps the colour under it (the first one, or after (+)).
    private func selectiveColourTapArea(size: CGSize) -> some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture { location in
                let x = min(max(location.x / size.width, 0), 1), y = min(max(location.y / size.height, 0), 1)
                effectsPanel.isAddingColour = false
                session.pickSelectiveColour(frameX: x, frameY: y)
            }
            .accessibilityHidden(true)
    }

    /// Watermark: "Or drag the watermark on the photo." The anchor follows the finger (preview
    /// while dragging, one undo step at the end); the box keeps the prototype's 30/70 % alignment.
    private func watermarkDragArea(size: CGSize) -> some View {
        Color.clear.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let start = watermarkDragStart ?? WatermarkStage.anchor(session.recipe.tools.watermark)
                    watermarkDragStart = start
                    watermarkPanel.dragAnchor(from: start, by: value.translation, imageSize: size, final: false)
                }
                .onEnded { value in
                    guard let start = watermarkDragStart else { return }
                    watermarkDragStart = nil
                    watermarkPanel.dragAnchor(from: start, by: value.translation, imageSize: size, final: true)
                })
            .accessibilityHidden(true)
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
        switch watermarkPanel.sheet {
        case .draw?:
            ApprovedSheetOverlay(isTablet: isTabletSheet, onDismiss: { watermarkPanel.sheet = nil }) {
                DrawSignatureSheetContent(pad: watermarkPanel.pad, onCancel: { watermarkPanel.sheet = nil },
                                          onSave: watermarkPanel.saveDrawn)
            }
        case .importSignature(let extracted)?:
            ApprovedSheetOverlay(isTablet: isTabletSheet, onDismiss: { watermarkPanel.sheet = nil }) {
                ImportSignatureSheetContent(extracted: extracted, onCancel: { watermarkPanel.sheet = nil },
                                            onUse: watermarkPanel.useImported)
            }
        case nil:
            EmptyView()
        }
        if panel.isReplaceSheetShown {
            ApprovedSheetOverlay(isTablet: isTabletSheet, onDismiss: { panel.isReplaceSheetShown = false }) {
                ReplaceFavouriteSheetContent(model: panel)
            }
        }
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
