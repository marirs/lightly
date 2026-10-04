import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Preferences (approved `preferences`): Appearance; Shortcuts (favourites, saved signature);
/// Saving (preferred border and the two independent metadata switches).
struct PreferencesPage: View {
    @Bindable var preferences: PreferencesStore
    let favourites: FavouritePresetsStore
    let open: (MorePage) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ApprovedGroupLabel(text: Text("preferences.group.appearance", bundle: .main))
            ApprovedSegmentedControl(
                accessibilityLabel: Text("preferences.group.appearance", bundle: .main),
                options: [
                    (AppearancePreference.system, Text("appearance.system", bundle: .main), "appearance.system"),
                    (.light, Text("appearance.light", bundle: .main), "appearance.light"),
                    (.dark, Text("appearance.dark", bundle: .main), "appearance.dark")
                ],
                selection: $preferences.appearance
            )
            .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ApprovedGroupLabel(text: Text("preferences.group.shortcuts", bundle: .main))
            Button { open(.favourites) } label: {
                ApprovedListRow(
                    title: Text("favourites.title", bundle: .main),
                    subtitle: Text("preferences.favourites.detail \(favourites.presetIDs.count) \(FavouritePresetsStore.capacity)", bundle: .main)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("preferences.favourites")
            Button { open(.savedSignature) } label: {
                ApprovedListRow(
                    title: Text("signature.title", bundle: .main),
                    subtitle: Text("preferences.signature.detail", bundle: .main)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("preferences.signature")

            ApprovedGroupLabel(text: Text("preferences.group.saving", bundle: .main))
            Button { open(.preferredBorder) } label: {
                ApprovedListRow(
                    title: Text("border.title", bundle: .main),
                    subtitle: PreferredBorderPage.name(of: preferences.preferredBorder)
                ) {
                    HStack(spacing: 6) {
                        PreferredBorderPage.name(of: preferences.preferredBorder).approvedText(15)
                        ApprovedChevron()
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("preferences.preferredBorder")

            metadataSwitch(
                isOn: $preferences.keepsPhotoMetadata,
                title: Text("preferences.keepMetadata", bundle: .main),
                detail: Text("preferences.keepMetadata.detail", bundle: .main),
                identifier: "preferences.keepMetadata"
            )
            metadataSwitch(
                isOn: $preferences.includesLocation,
                title: Text("preferences.includeLocation", bundle: .main),
                detail: Text("preferences.includeLocation.detail", bundle: .main),
                identifier: "preferences.includeLocation"
            )
        }
    }

    /// `.export-pref`: a list row whose whole width toggles; 12 pt above and below the text.
    private func metadataSwitch(isOn: Binding<Bool>, title: Text, detail: Text, identifier: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 0) {
                title.approvedText(15)
                detail.approvedText(13).foregroundStyle(ApprovedColor.inkTertiary.dynamic)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(ApprovedSwitchToggleStyle())
        .foregroundStyle(ApprovedColor.ink.dynamic)
        .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: ApprovedMetrics.rowMinimumHeight, alignment: .leading)
        .overlay(alignment: .bottom) { ApprovedHairline() }
        .accessibilityIdentifier(identifier)
    }
}

/// Preferred border (approved `pref-border`): None by default; never added to a photo
/// automatically, only the type Border opens on.
struct PreferredBorderPage: View {
    @Bindable var preferences: PreferencesStore
    @Environment(\.colorScheme) private var colorScheme

    static func name(of border: PreferredBorder) -> Text {
        switch border {
        case .none: Text("border.none", bundle: .main)
        case .solid: Text("border.solid", bundle: .main)
        case .photoFrame: Text("border.photoFrame", bundle: .main)
        case .polaroid: Text("border.polaroid", bundle: .main)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(PreferredBorder.allCases) { border in
                let isSelected = preferences.preferredBorder == border
                Button { preferences.preferredBorder = border } label: {
                    ApprovedListRow(title: Self.name(of: border)) {
                        if isSelected {
                            ApprovedIconView(icon: .check, size: 20)
                                .foregroundStyle(ApprovedColor.selection.resolved(colorScheme))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("border.\(border.rawValue)")
            }
            ApprovedNote(text: Text("border.note", bundle: .main))
        }
    }
}

/// Manage favourites (approved `pref-favourites`): up to five, drag to reorder, remove.
struct FavouritePresetsPage: View {
    let favourites: FavouritePresetsStore
    let catalogue: DevelopPresetCatalogue

    /// The favourite being dragged by its handle, and how far it has moved.
    @State private var draggedPresetID: String?
    @State private var dragOffset: CGFloat = 0
    @State private var rowHeight: CGFloat = ApprovedMetrics.rowMinimumHeight
    /// Translation already turned into slot moves.
    @State private var dragBase: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ApprovedNote(text: Text("favourites.note", bundle: .main))
            VStack(spacing: 0) {
                ForEach(Array(favourites.presetIDs.enumerated()), id: \.element) { index, presetID in
                    row(presetID: presetID, index: index)
                }
            }
            .coordinateSpace(name: "favourites")
            if favourites.freeSlots > 0 {
                ApprovedNote(text: Text("favourites.free \(favourites.freeSlots)", bundle: .main))
            }
        }
    }

    private func row(presetID: String, index: Int) -> some View {
        let entry = catalogue.entry(forPresetID: presetID)
        let name = Text(verbatim: entry?.preset.displayName ?? presetID)
        return HStack(spacing: 12) {
            ApprovedIconView(icon: .grip, size: 18)
                .foregroundStyle(ApprovedColor.inkTertiary.resolved(colorScheme))
                .frame(width: ApprovedMetrics.minimumTarget, height: ApprovedMetrics.minimumTarget)
                .contentShape(Rectangle())
                // The handle drags at once (no long press): the row follows the finger and takes
                // the slot it is over. A plain drag gesture, not a system drag session, so the
                // move cannot be lost to the session's lift timing or left half-done when a drag
                // is dropped outside the list.
                // v3 differs: slice 1 used onDrag/onDrop, which needed a long press to lift and
                // reordered only when the system delivered dropEntered over another row.
                .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("favourites"))
                    .onChanged { value in dragChanged(presetID: presetID, translation: value.translation.height) }
                    .onEnded { _ in dragEnded() })
            VStack(alignment: .leading, spacing: 0) {
                name.approvedText(15).foregroundStyle(ApprovedColor.ink.resolved(colorScheme))
                if let entry {
                    Text(verbatim: entry.category.name)
                        .approvedText(13)
                        .foregroundStyle(ApprovedColor.inkTertiary.resolved(colorScheme))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            ApprovedIconButton(
                icon: .trash,
                iconSize: 18,
                accessibilityLabel: Text("favourites.remove \(entry?.preset.displayName ?? presetID)", bundle: .main),
                identifier: "favourites.remove.\(index)",
                action: { favourites.remove(presetID) }
            )
        }
        .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding)
        .frame(maxWidth: .infinity, minHeight: ApprovedMetrics.rowMinimumHeight)
        .overlay(alignment: .bottom) { ApprovedHairline() }
        .background(ApprovedColor.sheet.resolved(colorScheme))
        .background(GeometryReader { proxy in Color.clear.onAppear { rowHeight = max(proxy.size.height, 1) } })
        .offset(y: draggedPresetID == presetID ? dragOffset : 0)
        .zIndex(draggedPresetID == presetID ? 1 : 0)
        // Reordering without dragging (VoiceOver, Switch Control).
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("favourites.row.\(index)")
        .accessibilityAction(named: Text("favourites.moveUp", bundle: .main)) {
            favourites.move(from: index, to: index - 1)
        }
        .accessibilityAction(named: Text("favourites.moveDown", bundle: .main)) {
            favourites.move(from: index, to: index + 1)
        }
        .accessibilityAction(named: Text("favourites.remove \(entry?.preset.displayName ?? presetID)", bundle: .main)) {
            favourites.remove(presetID)
        }
    }
}

extension FavouritePresetsPage {
    /// The dragged row moves with the finger; whenever it passes half a row, it takes the
    /// neighbouring slot and the offset is rebased, so the row stays under the finger.
    func dragChanged(presetID: String, translation: CGFloat) {
        if draggedPresetID != presetID {
            draggedPresetID = presetID
            dragBase = 0
        }
        var offset = translation - dragBase
        guard var index = favourites.presetIDs.firstIndex(of: presetID) else { return }
        while offset > rowHeight / 2, index < favourites.presetIDs.count - 1 {
            favourites.move(from: index, to: index + 1)
            index += 1
            dragBase += rowHeight
            offset -= rowHeight
        }
        while offset < -rowHeight / 2, index > 0 {
            favourites.move(from: index, to: index - 1)
            index -= 1
            dragBase -= rowHeight
            offset += rowHeight
        }
        dragOffset = offset
    }

    func dragEnded() {
        withAnimation(.snappy(duration: 0.2)) { dragOffset = 0 }
        draggedPresetID = nil
        dragBase = 0
    }
}

/// Saved signature (approved `pref-signature`): the saved signature, Draw a new signature,
/// Import from a photo, Delete saved signature, and the note.
///
/// The page shows one signature (the one saved last) while Watermark can hold a drawn and an
/// imported one (owner question W3); Delete removes the one shown. With nothing saved the page
/// says so and has no Delete row (no approved empty state; recorded with W3).
struct SavedSignaturePage: View {
    let signatures: SignatureStore
    let onChange: () -> Void

    private enum Sheet: Identifiable {
        case draw
        case importSignature(Data?)
        var id: String { if case .draw = self { "draw" } else { "import" } }
    }

    @State private var sheet: Sheet?
    @State private var pad = SignaturePadModel()
    @State private var isPickingPhoto = false
    @State private var photo: PhotosPickerItem?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let shown = signatures.shown {
                    // `padding:24px 18px;display:grid;place-items:center`, the signature 54 pt tall in ink.
                    SignatureGlyph(signature: shown, height: 54, ink: shown.kind == .drawn ? ApprovedColor.ink.resolved(colorScheme) : nil)
                        .frame(maxWidth: .infinity)
                        .accessibilityElement()
                        .accessibilityLabel(Text("Saved signature"))
                        .accessibilityIdentifier("signature.preview")
                } else {
                    Text("signature.empty", bundle: .main)
                        .approvedText(15)
                        .foregroundStyle(ApprovedColor.inkTertiary.resolved(colorScheme))
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
            }
            .padding(.vertical, 24)
            .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding)
            .overlay(alignment: .bottom) { ApprovedHairline() }
            Button { pad.clear(); sheet = .draw } label: { ApprovedListRow(title: Text("signature.draw", bundle: .main)) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("signature.draw")
            Button { isPickingPhoto = true } label: { ApprovedListRow(title: Text("signature.import", bundle: .main)) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("signature.import")
            if let shown = signatures.shown {
                Button {
                    signatures.delete(shown.kind)
                    onChange()
                } label: {
                    ApprovedListRow(title: Text("Delete saved signature"), titleColor: ApprovedColor.danger) { EmptyView() }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("signature.delete")
            }
            ApprovedNote(text: Text("signature.note", bundle: .main))
        }
        .photosPicker(isPresented: $isPickingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                let extracted = await Task.detached(priority: .userInitiated) { () -> Data? in
                    guard let data, let image = WatermarkPanelModel.uprightImage(data) else { return nil }
                    return SignatureInkExtractor.extract(from: image)
                }.value
                sheet = .importSignature(extracted)
            }
        }
        // A sheet over the More sheet, at its content's height, in the sheet colour.
        .sheet(item: $sheet) { current in
            Group {
                switch current {
                case .draw:
                    DrawSignatureSheetContent(pad: pad, onCancel: { sheet = nil }) { drawing in
                        signatures.saveDrawn(drawing)
                        onChange()
                        sheet = nil
                    }
                case .importSignature(let extracted):
                    ImportSignatureSheetContent(extracted: extracted, onCancel: { sheet = nil }) { png in
                        signatures.saveImported(png: png)
                        onChange()
                        sheet = nil
                    }
                }
            }
            .padding(.top, 15)
            .padding(.bottom, 30)
            .presentationDetents([.height(current.id == "draw" ? 330 : 345)])
            .presentationDragIndicator(.visible)
            .presentationBackground(ApprovedColor.sheet.dynamic)
        }
    }
}
