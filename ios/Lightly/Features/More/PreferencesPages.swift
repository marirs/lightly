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

    @State private var draggedPresetID: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ApprovedNote(text: Text("favourites.note", bundle: .main))
            ForEach(Array(favourites.presetIDs.enumerated()), id: \.element) { index, presetID in
                row(presetID: presetID, index: index)
            }
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
                .onDrag {
                    draggedPresetID = presetID
                    return NSItemProvider(object: presetID as NSString)
                }
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
        .onDrop(of: [UTType.text], delegate: FavouriteReorderDropDelegate(
            targetPresetID: presetID, favourites: favourites, draggedPresetID: $draggedPresetID
        ))
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

/// Moves the dragged favourite into the slot of the row it is dragged over.
private struct FavouriteReorderDropDelegate: DropDelegate {
    let targetPresetID: String
    let favourites: FavouritePresetsStore
    @Binding var draggedPresetID: String?

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragged = draggedPresetID, dragged != targetPresetID,
                  let from = favourites.presetIDs.firstIndex(of: dragged),
                  let to = favourites.presetIDs.firstIndex(of: targetPresetID) else { return }
            withAnimation(.snappy(duration: 0.2)) { favourites.move(from: from, to: to) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggedPresetID = nil
        return true
    }
}

/// Saved signature (approved `pref-signature`).
///
/// No signature can exist yet: drawing and importing arrive with Watermark in slice 5, so the
/// page shows its structure with the empty state.
// DEFERRED(slice 5): show the saved signature, enable Draw / Import, and add "Delete saved
// signature" once a signature store exists.
struct SavedSignaturePage: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Text("signature.empty", bundle: .main)
                .approvedText(15)
                .foregroundStyle(ApprovedColor.inkTertiary.resolved(colorScheme))
                .frame(maxWidth: .infinity, minHeight: 54)
                .padding(.vertical, 24)
                .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding)
                .overlay(alignment: .bottom) { ApprovedHairline() }
            ApprovedListRow(title: Text("signature.draw", bundle: .main))
                .opacity(0.4)
            ApprovedListRow(title: Text("signature.import", bundle: .main))
                .opacity(0.4)
            ApprovedNote(text: Text("signature.note", bundle: .main))
        }
    }
}
