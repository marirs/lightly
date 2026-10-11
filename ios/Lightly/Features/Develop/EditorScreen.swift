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
    @State private var cropPinchStart: EditRecipe.Rect?
    /// Inline crop (owner, 2026-10-11): Edit › Crop puts the crop frame on the photo itself; no separate workspace.
    private var isCropping: Bool { tool == .edit && editPanel.sub == .crop }
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
    @State private var isResetAlertShown = false
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
                    editor(layout, safeArea: geometry.safeAreaInsets)
                } else {
                    loading(layout)
                }
                // Swiped up, the preset gallery overlays the photo without squeezing it (Lightly 2 `expandedSheet`):
                // directly above the dock, min(600, screen − 120) tall, 30 pt top corners, sheet fill, shadow 0 −6 24.
                if tool == .develop && panel.isExpanded && layout.mode == .phone && !isCropping {
                    let c = L2(scheme: colorScheme)
                    VStack(spacing: 6) {
                        Capsule().fill(c(ApprovedColor.track)).frame(width: 36, height: 4).padding(.top, 2).padding(.bottom, 4)
                            .frame(maxWidth: .infinity).frame(minHeight: 24).contentShape(Rectangle())
                            .gesture(DragGesture().onChanged { panel.galleryPull = max(0, $0.translation.height) }.onEnded { _ in
                                withAnimation(.snappy(duration: 0.25)) {
                                    if panel.galleryPull > 40 { panel.isExpanded = false }
                                    panel.galleryPull = 0
                                }
                            })
                            .accessibilityIdentifier("develop.gallery.handle")
                            .accessibilityLabel("Preset browser")
                            .accessibilityAction(named: "Collapse presets") { panel.isExpanded = false }
                        DevelopPanelView(model: panel, style: .tabs, expanded: true)
                    }
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
                    .frame(height: min(600, screen.height - 120), alignment: .top)
                    .background(c(ApprovedColor.sheet), in: UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: -6)
                    .offset(y: panel.galleryPull)
                    .transition(.move(edge: .bottom))
                    .padding(.bottom, 62 + geometry.safeAreaInsets.bottom)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(edges: .bottom)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("develop.expanded")
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
        .onChange(of: tool == .edit && editPanel.sub == .crop, initial: true) { _, cropping in
            cropDraft = nil
            cropGestureStart = nil; cropPinchStart = nil
            session.isCropEditing = cropping
        }
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
        .sheet(item: $shareItem) { item in ActivityView(items: [item.url]).ignoresSafeArea() }
    }

    private func close() {
        if session.hasUnsavedEdits { isLeaveAlertShown = true } else { onClose() }
    }

    /// Auto on the photo (`autoControls`): a 38 pt circle, rgba(14,15,17,.66); applied: a 1.5 pt 75 % white ring, the
    /// wand in lime and a 15 pt lime badge with the check at its bottom-trailing corner; not applied: a 1 pt 18 % white
    /// ring and a #F2F3F0 wand.
    private var autoEnhanceButton: some View {
        let applied = session.autoState == .applied
        return Button { session.toggleAuto() } label: {
            ApprovedIconView(icon: .wand, size: 19)
                .foregroundStyle(applied ? Color(hex: 0xCFF26B) : Color(hex: 0xF2F3F0))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color(hex: 0x0E0F11, opacity: 0.66)))
                .overlay(Circle().strokeBorder(.white.opacity(applied ? 0.75 : 0.18), lineWidth: applied ? 1.5 : 1))
                .overlay(alignment: .bottomTrailing) {
                    if applied {
                        ApprovedIconView(icon: .check, size: 10).foregroundStyle(Color(hex: 0x121408))
                            .frame(width: 15, height: 15).background(Circle().fill(Color(hex: 0xCFF26B)))
                            .offset(x: 3, y: 3)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Auto enhance")
        .accessibilityValue(applied ? "Applied" : "Not applied")
        .accessibilityAddTraits(applied ? .isSelected : [])
        .accessibilityIdentifier("develop.auto")
    }

    // MARK: - Editor layouts

    /// The toast, centred 58 pt above the photo's bottom.
    private var photoToast: some View {
        ZStack {
            if let toast = session.toast {
                StageToast(text: toast).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 58)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Auto and "Reset all" (38 pt capsule, same fill, 1 pt 18 % white ring, 13 pt bold #F2F3F0 with the reset icon),
    /// 6 pt apart.
    /// Owner amendment (2026-10-10): pinned to the photo area's bottom-leading corner for every photo, on or beside the
    /// photo, instead of following the photo's own corner (the mockup's `autoControls` sat inside the photo).
    private var photoActions: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                autoEnhanceButton.padding(-3).fixedSize()
                if session.canReset(section: "all") {
                    Button { isResetAlertShown = true } label: {
                        HStack(spacing: 6) {
                            ApprovedIconView(icon: .reset, size: 15)
                            Text("Reset all").font(.system(size: 13, weight: .bold))
                        }
                        // Never squeezed by a narrow photo: the mockup's button keeps its one-line natural width.
                        .fixedSize()
                        .foregroundStyle(Color(hex: 0xF2F3F0))
                        .padding(.horizontal, 13).frame(height: 38)
                        .background(Capsule().fill(Color(hex: 0x0E0F11, opacity: 0.66)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Reset all edits").accessibilityIdentifier("editor.resetAll")
                }
            }
            .padding(10)
            .opacity(session.isShowingOriginal || isCropping ? 0 : 1)
            .allowsHitTesting(!session.isShowingOriginal && !isCropping)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// The stage with Auto and Reset all over its bottom-leading corner: 10 pt inside the stage's own 12/8 pt inset,
    /// where the photo's corner sits when it fills the width.
    private func photoStage() -> some View {
        stageOnly().overlay(alignment: .bottomLeading) { photoActions.padding(.leading, 12).padding(.bottom, 8) }
    }

    private func stageOnly() -> PhotoStage<EmptyView, AnyView> {
        PhotoStage(image: session.isShowingOriginal ? session.originalImage : session.displayedImage,
                   showsOriginalBadge: session.isShowingOriginal,
                   outlinesCanvas: !session.isShowingOriginal && session.recipe.tools.border.type != .none,
                   marksCoverCanvas: tool == .watermark,
                   cropWorkspace: false,
                   allowsInspection: !isCropping,
                   allowsDoubleTapZoom: tool != .watermark,
                   onInspectionBegan: {
                       let hadPreview = watermarkDragStart != nil || replacementDragStart != nil
                       watermarkDragStart = nil; replacementDragStart = nil
                       cropGestureStart = nil; cropDraft = nil
                       removePoints = []; refinePoints = []
                       if hadPreview || (tool == .effects && effectsPanel.sub == .leak) { session.cancelLookPreview() }
                   },
                   photoChrome: AnyView(photoToast),
                   imageBox: session.isShowingOriginal ? CGRect(x: 0, y: 0, width: 1, height: 1) : session.displayedImageBox,
                   onPhotoSize: session.isShowingOriginal ? nil : { session.setDisplayedPhotoSize($0) },
                   overlay: { EmptyView() },
                   marks: { AnyView(Group { if !session.isShowingOriginal { stageMarks.frame(maxWidth: .infinity, maxHeight: .infinity) } }) })
    }

    @ViewBuilder
    private func editor(_ layout: EditorLayout, safeArea: EdgeInsets) -> some View {
        let tools = EditorTool.available(hasPerson: session.hasPerson ?? false)
        let used = usedTools
        let c = L2(scheme: colorScheme)
        Group {
        switch layout.mode {
        case .phone:
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 52)
                    photoStage()
                    VStack(spacing: 0) {
                        // NO JUMPS: the same height for every tool and state; contents scroll (Lightly 2 PANEL_HEIGHT).
                        ScrollView(.vertical, showsIndicators: false) {
                            toolPanel(style: .tabs)
                                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: EditorLayout.phonePanelHeight)
                        .mask(panelFade(fades: tool != .develop || panel.isFavouritesFullNoticeShown || session.autoState == .failed))
                        ToolNavigation(tools: tools, selected: tool, used: used, onSelect: select)
                            .padding(.bottom, safeArea.bottom)
                    }
                    .background(c(ApprovedColor.sheet), in: UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous))
                    .overlay(alignment: .top) {
                        UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                            .stroke(c(ApprovedColor.hairline), lineWidth: 1)
                            .mask(alignment: .top) { Rectangle().frame(height: 31) }
                    }
                }
                .ignoresSafeArea(.container, edges: .bottom)
                EditorTopBar(session: session, onClose: close, onSave: session.saveCopy, onMore: onMore)
            }
        case .split:
            VStack(spacing: 12) {
                EditorHeaderBar(session: session, tools: tools, selected: tool, used: used, namesEveryTool: false,
                                onSelect: select, onClose: close, onSave: session.saveCopy, onMore: onMore)
                HStack(spacing: 16) {
                    photoStage()
                        .background(c(ApprovedColor.canvas), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tool.title).l2Heading(17).foregroundStyle(c(ApprovedColor.ink)).accessibilityAddTraits(.isHeader)
                        ScrollView(.vertical, showsIndicators: false) { toolPanel(style: .tabs) }
                            .scrollBounceBehavior(.basedOnSize)
                            .mask(panelFade(fades: true))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(c(ApprovedColor.surface), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(c(ApprovedColor.hairline), lineWidth: 1))
                }
            }
            .padding(layout.screen.height < 700 ? 12 : 16)
        case .tablet:
            VStack(spacing: 20) {
                EditorHeaderBar(session: session, tools: tools, selected: tool, used: used, namesEveryTool: true,
                                onSelect: select, onClose: close, onSave: session.saveCopy, onMore: onMore)
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tool.title).l2Heading(19).foregroundStyle(c(ApprovedColor.ink)).accessibilityAddTraits(.isHeader)
                        ScrollView(.vertical, showsIndicators: false) { toolPanel(style: .list) }
                            .scrollBounceBehavior(.basedOnSize)
                            .mask(panelFade(fades: true))
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                    .frame(width: 360, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
                    .background(c(ApprovedColor.surface), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(c(ApprovedColor.hairline), lineWidth: 1))
                    photoStage()
                        .background(c(ApprovedColor.canvas), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    EditSummaryPanel(rows: summaryRows(tools: tools, used: used), selected: tool)
                        .padding(.horizontal, 20).padding(.vertical, 18)
                        .frame(width: 290, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
                        .background(c(ApprovedColor.surface), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(c(ApprovedColor.hairline), lineWidth: 1))
                }
            }
            .padding(20)
        }
        }
    }

    /// `fadeDown`: the panel's lower edge fades (#000 90 % → transparent) where its contents scroll.
    private func panelFade(fades: Bool) -> LinearGradient {
        LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: fades ? .clear : .black, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }


    /// "Your edit" rows: every tool's current state.
    private func summaryRows(tools: [EditorTool], used: Set<EditorTool>) -> [(tool: EditorTool, value: String, edited: Bool)] {
        let r = session.recipe
        return tools.map { tool in
            let value: String
            switch tool {
            case .develop:
                value = panel.appliedPresetName ?? (session.autoState == .applied ? "Auto" : "Original")
            case .background:
                if r.tools.background.replacement != nil { value = "Changed" }
                else if r.tools.background.focus.blur > 0 { value = "Blur \(Int(r.tools.background.focus.blur))" }
                else { value = "Off" }
            case .portrait: value = used.contains(.portrait) ? portraitPanel.changedSummary : "Off"
            case .edit: value = used.contains(.edit) ? "Edited" : "Off"
            case .effects: value = used.contains(.effects) ? effectsPanel.onSummary : "Off"
            case .watermark: value = used.contains(.watermark) ? watermarkPanel.typeTitle : "Off"
            case .border: value = used.contains(.border) ? borderPanel.typeTitle : "Off"
            }
            return (tool, value, used.contains(tool))
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
            // The mockup's drawn dialogs (`dialog`), over everything.
        if isResetAlertShown {
            L2Alert(title: "Reset all edits?", message: "Return to the original photo. This also turns Auto off. You can undo this.",
                    buttons: [("Reset all edits", .destructive, "resetAll.confirm", {
                                  isResetAlertShown = false
                                  cropDraft = nil; cropGestureStart = nil; removePoints = []; refinePoints = []
                                  session.resetEdits()
                              }),
                              ("Keep editing", .normal, "resetAll.keep", { isResetAlertShown = false })])
        }
        if isLeaveAlertShown {
            L2Alert(title: "Leave without saving?", message: "Your original photo is unchanged. Edits that are not saved as a copy will be lost.",
                    buttons: [("Save", .preferred, "leave.save", { isLeaveAlertShown = false; session.saveCopy() }),
                              ("Discard edits", .destructive, "leave.discard", { isLeaveAlertShown = false; onClose() }),
                              ("Keep editing", .normal, "leave.keep", { isLeaveAlertShown = false })])
        }
        switch session.saveState {
        case .permissionDenied:
            L2Alert(title: "Can’t save to Photos", message: "Allow Lightly to add photos in Settings. Your edits are kept.",
                    buttons: [("Open Settings", .preferred, "saveDenied.settings", {
                                  session.dismissSaveState()
                                  if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                              }),
                              ("Not now", .normal, "saveDenied.notNow", { session.dismissSaveState() })])
        case .storageFull:
            L2Alert(title: "Not enough storage", message: "Free up some space and try again. Your edits are kept.",
                    buttons: [("Try again", .preferred, "storage.retry", { session.dismissSaveState(); session.saveCopy() }),
                              ("OK", .normal, "storage.ok", { session.dismissSaveState() })])
        case .failed:
            L2Alert(title: "Couldn’t save the copy", message: "Something went wrong while saving. Your edits are kept and the original is unchanged.",
                    buttons: [("Try again", .preferred, "saveFailed.retry", { session.dismissSaveState(); session.saveCopy() }),
                              ("Keep editing", .normal, "saveFailed.keep", { session.dismissSaveState() })])
        default:
            EmptyView()
        }
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
        panel.isExpanded = false
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
                    if watermarkPanel.isUsed { watermarkDragArea(size: size) }
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
            CropFrameMark(rect: cropDraft ?? session.recipe.tools.edit.geometry.cropRect,
                          isAdjusting: cropGestureStart != nil || cropPinchStart != nil)
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
                    guard cropPinchStart == nil else { return }
                    let rect = cropDraft ?? session.recipe.tools.edit.geometry.cropRect
                    if cropGestureStart == nil {
                        guard let handle = CropGeometry.handle(at: value.startLocation, rect: rect, size: size) else { return }
                        cropGestureStart = (rect, handle)
                    }
                    guard let start = cropGestureStart else { return }
                    cropDraft = draggedCrop(start, by: value.translation, size: size)
                }
                .onEnded { value in
                    guard let start = cropGestureStart else { return }
                    // Applied when the finger lifts: one undo step per drag (owner, 2026-10-11: no Done button).
                    commitCrop(draggedCrop(start, by: value.translation, size: size))
                    cropGestureStart = nil
                })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                if cropPinchStart == nil { cropPinchStart = cropDraft ?? session.recipe.tools.edit.geometry.cropRect; cropGestureStart = nil }
                if let start = cropPinchStart { cropDraft = CropGeometry.scaled(start, magnification: value.magnification) }
            }.onEnded { _ in
                if let rect = cropDraft { commitCrop(rect) }
                cropPinchStart = nil
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

    /// Commits a dragged or pinched rectangle (one undo step) and drops the draft once the recipe holds it.
    private func commitCrop(_ rect: EditRecipe.Rect) {
        if rect != session.recipe.tools.edit.geometry.cropRect {
            session.commitEdit { Self.setCrop(&$0.geometry, rect) }
        }
        cropDraft = nil
    }

    /// Cropping from Original makes the aspect Free; a fixed aspect (1:1, 4:5, …) keeps its shape while dragging.
    private static func setCrop(_ geometry: inout EditRecipe.Geometry, _ rect: EditRecipe.Rect) {
        geometry.cropRect = rect
        if geometry.cropAspect == .original { geometry.cropAspect = .free }
    }

    /// Light Leaks: drag on the photo to move the leak (preview while dragging, one step at the end).
    private func leakDragArea(size: CGSize) -> some View {
        Color.clear.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let x = min(max(value.location.x / size.width * 100, 0), 100).rounded()
                    let y = min(max(value.location.y / size.height * 100, 0), 100).rounded()
                    session.previewEffects { $0.lightLeak.x = x; $0.lightLeak.y = y; $0.lightLeak.enabled = true; if $0.lightLeak.intensity == 0 { $0.lightLeak.intensity = 35 } }
                }
                .onEnded { value in
                    let x = min(max(value.location.x / size.width * 100, 0), 100).rounded()
                    let y = min(max(value.location.y / size.height * 100, 0), 100).rounded()
                    session.commitEffects { $0.lightLeak.x = x; $0.lightLeak.y = y; $0.lightLeak.enabled = true; if $0.lightLeak.intensity == 0 { $0.lightLeak.intensity = 35 } }
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
                    let start = watermarkDragStart ?? watermarkPanel.canvasAnchor(size: size)
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

    /// Loading (`loadingScreen`): the photo between the 52 pt bar area and 120 pt from the bottom (phones), the progress
    /// card centred on it, Close at the top leading corner (12 pt in).
    @ViewBuilder
    private func loading(_ layout: EditorLayout) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                Color.clear.frame(height: 52)
                PhotoStage(image: session.displayedImage, overlay: { EmptyView() }, marks: {
                    GeometryReader { photo in
                        loadingProgress(maximumWidth: photo.size.width / 2)
                            .position(x: photo.size.width / 2, y: photo.size.height / 2)
                    }
                })
                Color.clear.frame(height: layout.mode == .phone ? 120 : 16)
            }
            L2IconButton(icon: .close, label: Text("Cancel"), identifier: "loading.cancel") {
                session.close()
                onClose()
            }
            .padding(.leading, 12)
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private func overlays(_ layout: EditorLayout) -> some View {
        let isTabletSheet = layout.mode != .phone
        if session.saveState == .saving {
            // `.scrim.middle` covers the whole screen, status bar included, and centres the box in it.
            ZStack {
                ApprovedColor.scrim(colorScheme)
                ProgressBox(title: "Saving a copy…", barFraction: 0.55) {
                    ProgressCancelButton(identifier: "saving.cancel") { session.cancelSave() }
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
    /// `--scrim`: rgba(10,10,10,.32) in light, rgba(0,0,0,.55) in dark (Lightly 2).
    static func scrim(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black.opacity(0.55) : Color(hex: 0x0A0A0A, opacity: 0.32)
    }
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

/// `toast`: 9/14 padding, 14 pt corners, rgba(14,15,17,.88), 13 pt semibold #F2F3F0, one line.
struct StageToast: View {
    let text: String
    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(hex: 0xF2F3F0))
            .lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x0E0F11, opacity: 0.88)))
            .accessibilityIdentifier("editor.toast")
    }
}

// MARK: - "Your edit" values (landscape iPad)

extension DevelopPanelModel {
    /// The applied preset's display name, if a preset is applied.
    var appliedPresetName: String? {
        session.recipe.look.flatMap { session.library.pack.preset(id: $0.lookId)?.displayName }
    }
}

extension PortraitPanelModel {
    /// The Portrait tabs holding changes on any face, named as the tabs are ("Skin, Eyes").
    var changedSummary: String {
        let edits = session.recipe.tools.portrait.faces
        var names: [String] = []
        if edits.contains(where: { $0.skin.smoothing != 0 || $0.skin.blemishes != 0 || $0.skin.evenTone != 0 || $0.skin.keepTexture != 85 }) { names.append("Skin") }
        if edits.contains(where: { $0.underEye.brighten != 0 || $0.underEye.softenLines != 0 }) { names.append("Under-eye") }
        if edits.contains(where: { $0.eyes.brighten != 0 || $0.eyes.clarity != 0 }) { names.append("Eyes") }
        if edits.contains(where: { $0.teeth.brighten != 0 }) { names.append("Teeth") }
        if edits.contains(where: { $0.hair.definition != 0 || $0.hair.flyaways != 0 || $0.hair.shine != 0 }) { names.append("Hair & Beard") }
        return names.isEmpty ? "Off" : names.joined(separator: ", ")
    }
}

extension EffectsPanelModel {
    /// The effects switched on, named as the tabs are.
    var onSummary: String {
        var names: [String] = []
        if effects.lightLeak.enabled { names.append("Light Leaks") }
        if effects.grain.enabled { names.append("Grain") }
        if effects.vignette.enabled { names.append("Vignette") }
        if !effects.selectiveColour.colours.isEmpty { names.append("Selective Colour") }
        return names.isEmpty ? "Off" : names.joined(separator: ", ")
    }
}

extension WatermarkPanelModel {
    var typeTitle: String {
        switch watermark.type {
        case .none: "Off"
        case .signature: "Signature"
        case .text: "Text"
        case .logo: "Logo"
        }
    }
}

extension BorderPanelModel {
    var typeTitle: String {
        switch border.type {
        case .none: "Off"
        case .solid: "Solid"
        case .frame: "Photo Frame"
        case .polaroid: "Polaroid"
        case .paper: "Paper"
        }
    }
}
