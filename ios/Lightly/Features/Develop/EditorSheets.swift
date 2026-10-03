import SwiftUI

/// The prototype's own sheet (`overlayHTML` → `sheet`): on phones a bottom sheet with a grabber
/// over a 32 % scrim; on screens wider than 700 pt a centred form sheet (540 pt, radius 14).
struct ApprovedSheetOverlay<Content: View>: View {
    let isTablet: Bool
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let screen = CGSize(width: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing,
                                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
            ZStack(alignment: isTablet ? .center : .bottom) {
                ApprovedColor.scrim(colorScheme)
                    .onTapGesture(perform: onDismiss)
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    if !isTablet {
                        Capsule().fill(ApprovedColor.hairline.resolved(colorScheme))
                            .frame(width: 36, height: 5).padding(.top, 2).padding(.bottom, 8)
                            .accessibilityHidden(true)
                    }
                    content()
                }
                .padding(.top, 8)
                .padding(.bottom, isTablet ? 16 : 30)
                .frame(width: isTablet ? min(540, screen.width * 0.92) : screen.width)
                .frame(maxHeight: screen.height * (isTablet ? 0.86 : 0.88), alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .background(ApprovedColor.sheet.resolved(colorScheme))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: isTablet ? 14 : 0,
                                                  bottomTrailingRadius: isTablet ? 14 : 0, topTrailingRadius: 14))
                .accessibilityAddTraits(.isModal)
            }
            .frame(width: screen.width, height: screen.height)
            .offset(x: -geometry.safeAreaInsets.leading, y: -geometry.safeAreaInsets.top)
        }
        .ignoresSafeArea()
        .accessibilityAction(.escape, onDismiss)
    }
}

/// `saved`: the check, "Saved as a new photo", "The original is unchanged.", then Share, Keep
/// editing and Choose another photo.
struct SavedSheetContent: View {
    let onShare: () -> Void
    let onKeepEditing: () -> Void
    let onChooseAnother: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ApprovedIconView(icon: .check, size: 30)
                    .foregroundStyle(ApprovedColor.selection.resolved(colorScheme))
                    .padding(.bottom, 8)
                Text("Saved as a new photo")
                    .approvedText(18, weight: .semibold)
                    .foregroundStyle(ApprovedColor.ink.resolved(colorScheme))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("saved.title")
                Text("The original is unchanged.")
                    .approvedText(15)
                    .foregroundStyle(ApprovedColor.inkSecondary.resolved(colorScheme))
                    .padding(.top, 4).padding(.bottom, 14)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18).padding(.top, 8)
            VStack(spacing: 8) {
                Button(action: onShare) {
                    HStack(spacing: 8) { ApprovedIconView(icon: .share, size: 20); Text("Share") }
                }
                .buttonStyle(ApprovedButtonStyle(kind: .primary, fillsWidth: true))
                .accessibilityIdentifier("saved.share")
                Button("Keep editing", action: onKeepEditing)
                    .buttonStyle(ApprovedButtonStyle(kind: .line, fillsWidth: true))
                    .accessibilityIdentifier("saved.keepEditing")
                Button("Choose another photo", action: onChooseAnother)
                    .buttonStyle(ApprovedButtonStyle(kind: .quiet, fillsWidth: true))
                    .accessibilityIdentifier("saved.chooseAnother")
            }
            .padding(.horizontal, 18)
        }
    }
}

/// `favReplace`: Cancel, "Replace a favourite", one row per favourite with "Replace".
struct ReplaceFavouriteSheetContent: View {
    let model: DevelopPanelModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // `.sheethead` sets 17 pt semibold and `.btn` inherits it.
                Button("Cancel") { model.isReplaceSheetShown = false }
                    .buttonStyle(SheetHeadQuietButtonStyle())
                    .accessibilityIdentifier("replace.cancel")
                Text("Replace a favourite")
                    .approvedText(17, weight: .semibold)
                    .foregroundStyle(ApprovedColor.ink.resolved(colorScheme))
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                Color.clear.frame(width: 70, height: 1)
            }
            .padding(.leading, 18).padding(.trailing, 8)
            .frame(minHeight: 44)
            ForEach(model.favourites.presetIDs, id: \.self) { id in
                if let preset = model.session.library.pack.preset(id: id) {
                    Button { model.replaceFavourite(id) } label: {
                        ApprovedListRow(title: Text(preset.displayName),
                                        subtitle: Text(model.session.library.pack.category(id: preset.categoryID)?.name ?? "")) {
                            Text("Replace").approvedText(15).foregroundStyle(ApprovedColor.selection.resolved(colorScheme))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("replace.row.\(id)")
                }
            }
        }
    }
}

/// `.btn.quiet` inside `.sheethead`: the head's 17 pt semibold, selection colour, 12 pt padding.
struct SheetHeadQuietButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .approvedText(17, weight: .semibold)
            .foregroundStyle(ApprovedColor.selection.resolved(colorScheme))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
