import PhotosUI
import SwiftUI

/// The pages reachable from ⋮ More (Lightly 2 `morePage`). Preferences live on the More page itself; About carries
/// the details and the support email (no separate Preferences or Support pages, owner 2026-10-10).
enum MorePage: Hashable, Sendable {
    case menu
    case favourites
    case savedSignature
    case preferredBorder
    case legal
    case privacyPolicy
    case termsOfUse
    case about
}

/// More: one page at a time, each with Back to its parent; Close on the first page. Phones show it full screen on
/// --bg; wider screens as the centred sheet card (`RootView`).
struct MoreSheet: View {
    let entry: MoreEntry
    var inSheet = false
    @State private var path: [MorePage]

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(entry: MoreEntry, inSheet: Bool = false, initialPath: [MorePage]? = nil) {
        self.entry = entry
        self.inSheet = inSheet
        _path = State(initialValue: initialPath ?? [entry == .privacyPolicyFromWelcome ? .privacyPolicy : .menu])
    }

    private var currentPage: MorePage { path.last ?? .menu }

    var body: some View {
        page(currentPage)
            .id(currentPage)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { if !inSheet { ApprovedColor.background.resolved(colorScheme).ignoresSafeArea() } }
            .overlay(alignment: .bottom) { if let toast = appState.toast { StageToast(text: toast).padding(.bottom, 40) } }
    }

    private func open(_ page: MorePage) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.25)) { path.append(page) }
    }

    /// Back on a page: its parent, or out of More when the page was the entry point.
    private func back() {
        guard path.count > 1 else { appState.closeMore(); return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.25)) { _ = path.popLast() }
    }

    /// `morePage`: 16 pt sides; the header (root: "More", 30 pt heading, −0.6 tracking, 6 pt in, and a 44 pt chip-filled
    /// Close; other pages: Back and the title, 22 pt heading), 12 pt above the page body.
    @ViewBuilder
    private func page(_ page: MorePage) -> some View {
        let c = L2(scheme: colorScheme)
        let isRoot = path.count == 1 && page == .menu
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                if isRoot {
                    Text("more.title", bundle: .main).l2Heading(30, tracking: -0.6).foregroundStyle(c(ApprovedColor.ink))
                        .padding(.leading, 6)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("more.page.menu")
                    Spacer(minLength: 8)
                    Button(action: back) {
                        ApprovedIconView(icon: .close, size: 20).foregroundStyle(c(ApprovedColor.ink))
                            .frame(width: 44, height: 44).background(Circle().fill(c(ApprovedColor.chip)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("common.close", bundle: .main)).accessibilityIdentifier("page.close")
                } else {
                    L2IconButton(icon: .back, label: Text("common.back", bundle: .main), identifier: "page.back", action: back)
                    title(of: page).l2Heading(22).foregroundStyle(c(ApprovedColor.ink))
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("more.page.\(page)")
                    Spacer(minLength: 0)
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                content(of: page).frame(maxWidth: .infinity, alignment: .top).padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 16)
        .padding(.top, inSheet ? 18 : 0)
    }

    private func title(of page: MorePage) -> Text {
        switch page {
        case .menu: Text("more.title", bundle: .main)
        case .favourites: Text("favourites.title", bundle: .main)
        case .savedSignature: Text("signature.title", bundle: .main)
        case .preferredBorder: Text("border.title", bundle: .main)
        case .legal: Text("legal.title", bundle: .main)
        case .privacyPolicy: Text("legal.privacyPolicy", bundle: .main)
        case .termsOfUse: Text("legal.termsOfUse", bundle: .main)
        case .about: Text("about.title", bundle: .main)
        }
    }

    @ViewBuilder
    private func content(of page: MorePage) -> some View {
        switch page {
        case .menu:
            MoreMenuPage(open: open)
        case .favourites:
            FavouritePresetsPage(favourites: appState.favourites, catalogue: appState.presetCatalogue, session: appState.currentEditorSession)
        case .savedSignature:
            SavedSignaturePage(signatures: appState.signatures, onChange: appState.signaturesChanged,
                               openSheet: appState.openSignatureSheet, showToast: appState.showToast)
        case .preferredBorder:
            PreferredBorderPage(preferences: appState.preferences)
        case .legal:
            L2Card {
                navigationRow(Text("legal.privacyPolicy", bundle: .main), to: .privacyPolicy, isFirst: true)
                navigationRow(Text("legal.termsOfUse", bundle: .main), to: .termsOfUse)
            }
        case .privacyPolicy:
            ReleaseDocumentPage(document: appState.releaseContent.availablePrivacyPolicy, onlineURL: URL(string: "https://lightly.pro/privacy")!)
        case .termsOfUse:
            ReleaseDocumentPage(document: appState.releaseContent.availableTermsOfUse, onlineURL: URL(string: "https://lightly.pro/terms")!)
        case .about:
            AboutPage(version: appState.appVersion, library: appState.developLibrary)
        }
    }

    private func navigationRow(_ title: Text, subtitle: Text? = nil, to page: MorePage, isFirst: Bool = false) -> some View {
        Button { open(page) } label: {
            L2ListRow(title: title, subtitle: subtitle, isFirst: isFirst) { ApprovedIconView(icon: .chevron, size: 18) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("more.row.\(page)")
    }
}

// MARK: - More (root)

/// The More page (`morePage('more')`), a 12 pt column: the app card; Appearance (the three preview tiles); Shortcuts
/// (Favourite presets with three thumbnails, Saved signature with the signature); Saving (Preferred border, Keep photo
/// metadata, Include location); Help (About, Legal).
private struct MoreMenuPage: View {
    let open: (MorePage) -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var preferences = appState.preferences
        let c = L2(scheme: colorScheme)
        VStack(spacing: 12) {
            L2Card(padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)) {
                HStack(spacing: 12) {
                    BrandMark(size: 44, style: .tile)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("brand.wordmark", bundle: .main).l2Heading(16).foregroundStyle(c(ApprovedColor.ink))
                        Text("about.version \(appState.appVersion.version) \(appState.appVersion.build)", bundle: .main)
                            .l2Text(12).foregroundStyle(c(ApprovedColor.inkSecondary))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("about.version")
            VStack(spacing: 0) {
                L2GroupLabel(text: "Appearance")
                AppearanceTiles(selection: $preferences.appearance)
            }
            VStack(spacing: 0) {
                L2GroupLabel(text: "Shortcuts")
                L2Card {
                    Button { open(.favourites) } label: {
                        L2ListRow(title: Text("favourites.title", bundle: .main),
                                  subtitle: Text("preferences.favourites.detail \(appState.favourites.presetIDs.count) \(FavouritePresetsStore.capacity)", bundle: .main),
                                  isFirst: true) {
                            FavouriteThumbnails(ids: Array(appState.favourites.presetIDs.prefix(3)), session: appState.currentEditorSession)
                            ApprovedIconView(icon: .chevron, size: 18)
                        }
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("preferences.favourites")
                    Button { open(.savedSignature) } label: {
                        L2ListRow(title: Text("signature.title", bundle: .main), subtitle: Text("preferences.signature.detail", bundle: .main)) {
                            if let shown = appState.signatures.shown {
                                SignatureGlyph(signature: shown, height: 20, ink: shown.kind == .drawn ? c(ApprovedColor.ink) : nil)
                                    .frame(maxWidth: 54)
                            }
                            ApprovedIconView(icon: .chevron, size: 18)
                        }
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("preferences.signature")
                }
            }
            VStack(spacing: 0) {
                L2GroupLabel(text: "Saving")
                L2Card {
                    Button { open(.preferredBorder) } label: {
                        L2ListRow(title: Text("border.title", bundle: .main), isFirst: true) {
                            PreferredBorderPage.name(of: preferences.preferredBorder)
                            ApprovedIconView(icon: .chevron, size: 18)
                        }
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("preferences.preferredBorder")
                    switchRow($preferences.keepsPhotoMetadata, "preferences.keepMetadata", "preferences.keepMetadata.detail", "preferences.keepMetadata")
                    switchRow($preferences.includesLocation, "preferences.includeLocation", "preferences.includeLocation.detail", "preferences.includeLocation")
                }
            }
            VStack(spacing: 0) {
                L2GroupLabel(text: "Help")
                L2Card {
                    Button { open(.about) } label: {
                        L2ListRow(title: Text("about.title", bundle: .main), subtitle: Text("Details and support email"), isFirst: true) {
                            ApprovedIconView(icon: .chevron, size: 18)
                        }
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("more.row.about")
                    Button { open(.legal) } label: {
                        L2ListRow(title: Text("legal.title", bundle: .main), subtitle: Text("Privacy Policy, Terms of Use")) {
                            ApprovedIconView(icon: .chevron, size: 18)
                        }
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("more.row.legal")
                }
            }
        }
    }

    /// `toggleRow` inside the card: 16 pt sides, hairline above.
    private func switchRow(_ isOn: Binding<Bool>, _ title: String.LocalizationValue, _ detail: String.LocalizationValue, _ identifier: String) -> some View {
        Toggle(isOn: isOn) { L2ToggleLabel(title: String(localized: title), subtitle: String(localized: detail)) }
            .toggleStyle(L2SwitchStyle())
            .padding(.horizontal, 16).padding(.vertical, 4)
            .overlay(alignment: .top) { Rectangle().fill(ApprovedColor.hairline.resolved(colorScheme)).frame(height: 1) }
            .accessibilityIdentifier(identifier)
    }
}

/// `appearanceTiles`: a card (16/12/14 padding) with System, Light and Dark: 64×76 previews (14 pt corners; the chosen
/// one with a 2 pt accent border and a 22 pt lime check badge), 13 pt labels (bold when chosen), 8 pt between.
private struct AppearanceTiles: View {
    @Binding var selection: AppearancePreference
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        L2Card(padding: EdgeInsets(top: 16, leading: 12, bottom: 14, trailing: 12)) {
            HStack(spacing: 0) {
                tile(.system, Text("appearance.system", bundle: .main))
                tile(.light, Text("appearance.light", bundle: .main))
                tile(.dark, Text("appearance.dark", bundle: .main))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("preferences.group.appearance", bundle: .main))
    }

    private func tile(_ value: AppearancePreference, _ label: Text) -> some View {
        let c = L2(scheme: colorScheme)
        let isOn = selection == value
        return Button { selection = value } label: {
            VStack(spacing: 8) {
                preview(value)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(3)
                    .frame(width: 64, height: 76)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isOn ? c(ApprovedColor.selection) : c(ApprovedColor.hairline), lineWidth: isOn ? 2 : 1))
                    .overlay(alignment: .topTrailing) {
                        if isOn {
                            ApprovedIconView(icon: .check, size: 13).foregroundStyle(c(ApprovedColor.onAccent))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(c(ApprovedColor.accent)))
                                .background(Circle().stroke(c(ApprovedColor.surface), lineWidth: 2))
                                .offset(x: 6, y: -6)
                        }
                    }
                label.l2Text(13, weight: isOn ? .bold : .semibold).foregroundStyle(c(ApprovedColor.ink))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("appearance.\(value.rawValue)")
    }

    /// The preview: the theme's background (System split diagonally), two text lines and a lime pill.
    private func preview(_ value: AppearancePreference) -> some View {
        let ink: Color = value == .light ? Color(hex: 0x141513) : value == .dark ? Color(hex: 0xF2F3F0) : Color(hex: 0x8A8E86)
        return ZStack(alignment: .topLeading) {
            switch value {
            case .light: Color(hex: 0xF3F3F0)
            case .dark: Color(hex: 0x0D0E10)
            default:
                GeometryReader { g in
                    Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: g.size.width, y: 0)); p.addLine(to: CGPoint(x: 0, y: g.size.height)); p.closeSubpath() }
                        .fill(Color(hex: 0xF3F3F0))
                        .background(Color(hex: 0x0D0E10))
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(ink.opacity(0.9)).frame(height: 5)
                Capsule().fill(ink.opacity(0.45)).frame(height: 4).padding(.trailing, 10)
                Spacer(minLength: 0)
                Capsule().fill(Color(hex: 0xCFF26B)).frame(width: 22, height: 10)
            }
            .padding(.horizontal, 5).padding(.top, 6).padding(.bottom, 5)
        }
    }
}

/// Up to three favourites as 26 pt circles of this photo with each look, overlapping by 8 pt with a 2 pt surface ring.
/// Without an open photo the circles are chip-filled.
private struct FavouriteThumbnails: View {
    let ids: [String]
    let session: EditorSession?
    var body: some View {
        HStack(spacing: -8) {
            ForEach(ids, id: \.self) { id in FavouriteThumbnail(id: id, session: session, size: 26, ringed: true) }
        }
    }
}

struct FavouriteThumbnail: View {
    let id: String
    let session: EditorSession?
    let size: CGFloat
    var ringed = false
    @State private var image: CGImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = L2(scheme: colorScheme)
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() } else { c(ApprovedColor.chip) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .background { if ringed { Circle().fill(c(ApprovedColor.surface)).padding(-2) } }
        .task(id: session?.thumbnailKey) {
            guard let session, let preset = session.library.pack.preset(id: id) else { return }
            image = await session.presetThumbnail(preset)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Favourite presets

/// Favourite presets (`favourites` page): the note; a card of rows (grip, 36 pt thumbnail, name 15 pt semibold with the
/// category 12 pt ink2, remove), 58 pt tall, 14/8 pt sides; "N free. Star a preset in Develop to add it."
struct FavouritePresetsPage: View {
    let favourites: FavouritePresetsStore
    let catalogue: DevelopPresetCatalogue
    let session: EditorSession?

    @State private var draggedPresetID: String?
    @State private var dragOffset: CGFloat = 0
    @State private var rowHeight: CGFloat = 58
    @State private var dragBase: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            L2Note(text: Text("favourites.note", bundle: .main))
            if !favourites.presetIDs.isEmpty {
                L2Card {
                    ForEach(Array(favourites.presetIDs.enumerated()), id: \.element) { index, presetID in
                        row(presetID: presetID, index: index)
                    }
                }
                .coordinateSpace(name: "favourites")
            }
            if favourites.freeSlots > 0 { L2Note(text: Text("favourites.free \(favourites.freeSlots)", bundle: .main)) }
        }
    }

    private func row(presetID: String, index: Int) -> some View {
        let c = L2(scheme: colorScheme)
        let entry = catalogue.entry(forPresetID: presetID)
        return HStack(spacing: 12) {
            ApprovedIconView(icon: .grip, size: 18)
                .foregroundStyle(c(ApprovedColor.inkTertiary))
                .frame(width: 24, height: 44)
                .contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("favourites"))
                    .onChanged { value in dragChanged(presetID: presetID, translation: value.translation.height) }
                    .onEnded { _ in dragEnded() })
            FavouriteThumbnail(id: presetID, session: session, size: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: entry?.preset.displayName ?? presetID).l2Text(15, weight: .semibold).foregroundStyle(c(ApprovedColor.ink))
                if let entry { Text(verbatim: entry.category.name).l2Text(12).foregroundStyle(c(ApprovedColor.inkSecondary)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            L2IconButton(icon: .trash, label: Text("favourites.remove \(entry?.preset.displayName ?? presetID)", bundle: .main),
                         identifier: "favourites.remove.\(index)") { favourites.remove(presetID) }
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: 58)
        .overlay(alignment: .top) { if index > 0 { Rectangle().fill(c(ApprovedColor.hairline)).frame(height: 1) } }
        .background(c(ApprovedColor.surface))
        .background(GeometryReader { proxy in Color.clear.onAppear { rowHeight = max(proxy.size.height, 1) } })
        .offset(y: draggedPresetID == presetID ? dragOffset : 0)
        .zIndex(draggedPresetID == presetID ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("favourites.row.\(index)")
        .accessibilityAction(named: Text("favourites.moveUp", bundle: .main)) { favourites.move(from: index, to: index - 1) }
        .accessibilityAction(named: Text("favourites.moveDown", bundle: .main)) { favourites.move(from: index, to: index + 1) }
        .accessibilityAction(named: Text("favourites.remove \(entry?.preset.displayName ?? presetID)", bundle: .main)) { favourites.remove(presetID) }
    }

    /// The dragged row follows the finger; passing half a row it takes the neighbouring slot.
    func dragChanged(presetID: String, translation: CGFloat) {
        if draggedPresetID != presetID { draggedPresetID = presetID; dragBase = 0 }
        var offset = translation - dragBase
        guard var index = favourites.presetIDs.firstIndex(of: presetID) else { return }
        while offset > rowHeight / 2, index < favourites.presetIDs.count - 1 {
            favourites.move(from: index, to: index + 1); index += 1; dragBase += rowHeight; offset -= rowHeight
        }
        while offset < -rowHeight / 2, index > 0 {
            favourites.move(from: index, to: index - 1); index -= 1; dragBase -= rowHeight; offset += rowHeight
        }
        dragOffset = offset
    }

    func dragEnded() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { dragOffset = 0 }
        draggedPresetID = nil
        dragBase = 0
    }
}

// MARK: - Saved signature

/// Saved signature (`signature` page): the signature in a card (26 pt padding, ink), then a card with Draw a new
/// signature, Import from a photo and Delete saved signature (danger); the note.
struct SavedSignaturePage: View {
    let signatures: SignatureStore
    let onChange: () -> Void
    let openSheet: (AppState.SignatureSheet) -> Void
    let showToast: (String) -> Void

    @State private var isPickingPhoto = false
    @State private var photo: PhotosPickerItem?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = L2(scheme: colorScheme)
        VStack(alignment: .leading, spacing: 12) {
            L2Card {
                Group {
                    if let shown = signatures.shown {
                        SignatureGlyph(signature: shown, height: 64, ink: shown.kind == .drawn ? c(ApprovedColor.ink) : nil)
                            .accessibilityElement().accessibilityLabel(Text("Saved signature")).accessibilityIdentifier("signature.preview")
                    } else {
                        Text("signature.empty", bundle: .main).l2Text(15).foregroundStyle(c(ApprovedColor.inkTertiary))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .padding(.vertical, 26)
            }
            L2Card {
                Button { openSheet(.draw) } label: {
                    L2ListRow(title: Text("signature.draw", bundle: .main), isFirst: true) { ApprovedIconView(icon: .chevron, size: 18) }
                }
                .buttonStyle(.plain).accessibilityIdentifier("signature.draw")
                Button { isPickingPhoto = true } label: {
                    L2ListRow(title: Text("signature.import", bundle: .main)) { ApprovedIconView(icon: .chevron, size: 18) }
                }
                .buttonStyle(.plain).accessibilityIdentifier("signature.import")
                if let shown = signatures.shown {
                    Button { signatures.delete(shown.kind); onChange() } label: {
                        L2ListRow(title: Text("Delete saved signature"), titleColour: ApprovedColor.danger) { EmptyView() }
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("signature.delete")
                }
            }
            L2Note(text: Text("signature.note", bundle: .main))
        }
        .photosPicker(isPresented: $isPickingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                let result = await Task.detached(priority: .userInitiated) { () -> SignatureInkExtractor.ImportResult in
                    SignatureInkExtractor.importSignature(from: data.flatMap(WatermarkPanelModel.uprightImage))
                }.value
                switch result {
                case .inkFound(let png), .asIs(let png): openSheet(.importSignature(png))
                case .blank: showToast(WatermarkPanelModel.blankImportMessage)
                case .unreadable: showToast(WatermarkPanelModel.unreadableImportMessage)
                }
            }
        }
    }
}

// MARK: - Preferred border

/// Preferred border (`prefborder`): a card of None, Solid, Photo Frame, Polaroid and Paper, an accent check on the
/// chosen one; the note.
struct PreferredBorderPage: View {
    @Bindable var preferences: PreferencesStore
    @Environment(\.colorScheme) private var colorScheme

    static func name(of border: PreferredBorder) -> Text {
        switch border {
        case .none: Text("border.none", bundle: .main)
        case .solid: Text("border.solid", bundle: .main)
        case .photoFrame: Text("border.photoFrame", bundle: .main)
        case .polaroid: Text("border.polaroid", bundle: .main)
        case .paper: Text("Paper")
        }
    }

    var body: some View {
        let c = L2(scheme: colorScheme)
        VStack(alignment: .leading, spacing: 10) {
            L2Card {
                ForEach(Array(PreferredBorder.allCases.enumerated()), id: \.element) { index, border in
                    let isSelected = preferences.preferredBorder == border
                    Button { preferences.preferredBorder = border } label: {
                        L2ListRow(title: Self.name(of: border), isFirst: index == 0) {
                            if isSelected { ApprovedIconView(icon: .check, size: 20).foregroundStyle(c(ApprovedColor.selection)) }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("border.\(border.rawValue)")
                }
            }
            L2Note(text: Text("border.note", bundle: .main))
        }
    }
}

// MARK: - Legal

/// Privacy Policy or Terms of Use (`doc`): the web address (14 pt accent), then each section's heading (15 pt bold) and
/// paragraphs (14 pt ink2, line height 1.5), 16 pt apart, 4 pt in.
struct ReleaseDocumentPage: View {
    let document: ReleaseContent.Document?
    let onlineURL: URL
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = L2(scheme: colorScheme)
        if let document {
            VStack(alignment: .leading, spacing: 0) {
                Link(destination: onlineURL) {
                    Text(verbatim: onlineURL.host().map { $0 + onlineURL.path() } ?? onlineURL.absoluteString)
                        .l2Text(14, weight: .semibold).foregroundStyle(c(ApprovedColor.selection))
                }
                .padding(.top, 2).padding(.bottom, 14)
                .accessibilityIdentifier("legal.online")
                ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                    if let heading = section.heading {
                        Text(verbatim: heading).l2Text(15, weight: .bold).foregroundStyle(c(ApprovedColor.ink)).padding(.bottom, 6)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(verbatim: paragraph).l2Text(14, lineHeight: 1.5).foregroundStyle(c(ApprovedColor.inkSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 16)
                    }
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("legal.document")
        } else {
            L2Note(text: Text("legal.unavailable", bundle: .main)).accessibilityIdentifier("legal.unavailable")
        }
    }
}

// MARK: - About

/// About (`about`, owner 2026-10-10: details, then the support email, no Support page): the app-icon tile (72 pt),
/// "Lightly" (22 pt heading), the version (13 pt ink2); the description (14 pt ink2, centred, line height 1.5); the
/// details card (46 pt rows: label ink2, value semibold); "Support" and the email row (opens Mail).
struct AboutPage: View {
    let version: AppVersion
    /// The preset pack the editor ships: the count follows it, so adding or removing presets updates About by itself.
    let library: DevelopLibrary
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    static let supportEmail = "hello@lightly.pro"

    var body: some View {
        let c = L2(scheme: colorScheme)
        let pack = library.pack
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                BrandMark(size: 72, style: .tile)
                Text("brand.wordmark", bundle: .main).l2Heading(22).foregroundStyle(c(ApprovedColor.ink))
                Text("about.version \(version.version) \(version.build)", bundle: .main).l2Text(13).foregroundStyle(c(ApprovedColor.inkSecondary))
            }
            .padding(.top, 14).padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("about.version")
            Text("A photo editor that develops your photo in one tap, then lets you fine-tune it with presets, background, portrait, effects, watermark and border.")
                .l2Text(14, lineHeight: 1.5).foregroundStyle(c(ApprovedColor.inkSecondary))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
            L2Card {
                detail("Editing", "On your device", isFirst: true)
                detail("Account", "Not needed")
                detail("Advertising and analytics", "None")
                detail("Presets", pack.isEmpty ? "…" : "\(pack.presetCount.formatted()) in \(pack.categories.count) categories")
                detail("Website", "lightly.pro")
            }
            VStack(spacing: 0) {
                L2GroupLabel(text: "Support")
                L2Card {
                    Button { if let url = URL(string: "mailto:\(Self.supportEmail)") { openURL(url) } } label: {
                        L2ListRow(title: Text(verbatim: Self.supportEmail),
                                  subtitle: Text("Questions or a problem with a photo? Include your version number."), isFirst: true) {
                            ApprovedIconView(icon: .mail, size: 20).foregroundStyle(c(ApprovedColor.selection))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Writes an email to support"))
                    .accessibilityIdentifier("support.contact")
                }
            }
        }
    }

    private func detail(_ label: String, _ value: String, isFirst: Bool = false) -> some View {
        let c = L2(scheme: colorScheme)
        return HStack(spacing: 12) {
            Text(LocalizedStringKey(label)).foregroundStyle(c(ApprovedColor.inkSecondary))
            Spacer(minLength: 8)
            Text(LocalizedStringKey(value)).fontWeight(.semibold).foregroundStyle(c(ApprovedColor.ink)).multilineTextAlignment(.trailing)
        }
        .l2Text(14)
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
        .overlay(alignment: .top) { if !isFirst { Rectangle().fill(c(ApprovedColor.hairline)).frame(height: 1) } }
        .accessibilityElement(children: .combine)
    }
}
