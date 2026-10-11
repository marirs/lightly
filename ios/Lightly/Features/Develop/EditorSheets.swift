import SwiftUI

/// `sheetOverlay` (Lightly 2): on phones a bottom sheet (30 pt top corners, hairline top edge, 40×5 grabber unless
/// `bare`) over the scrim; on wider screens a centred card, min(560, 60 % of the width), 28 pt corners, hairline,
/// shadow 0 24 60 at 40 %. `heightFraction` gives the sheet a fixed height (`h: '90%'`); otherwise it fits its content
/// (at most 86 % on tablets).
struct ApprovedSheetOverlay<Content: View>: View {
    let isTablet: Bool
    var heightFraction: CGFloat?
    var bare = false
    /// A sheet whose text field takes focus as it opens (the Text and Watermark text sheets): presented without the
    /// full-screen cover's own slide (`presentWithoutCoverSlide`), it rises from the bottom edge with the keyboard's
    /// curve while the keyboard comes up, and the scrim fades in, so sheet and keyboard arrive together instead of the
    /// sheet sliding up first and then jumping above the keyboard (owner report 2026-10-11).
    var risesWithKeyboard = false
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var hasRisen = false

    /// The iOS keyboard's own presentation curve (a critically damped spring of about this length), which SwiftUI
    /// also uses for the keyboard's safe-area inset that lifts the sheet.
    static var keyboardCurve: Animation { .spring(response: 0.38, dampingFraction: 1) }

    private var isLowered: Bool { risesWithKeyboard && !hasRisen }

    var body: some View {
        GeometryReader { geometry in
            let screen = CGSize(width: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing,
                                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
            let c = L2(scheme: colorScheme)
            let shape = UnevenRoundedRectangle(topLeadingRadius: isTablet ? 28 : 30, bottomLeadingRadius: isTablet ? 28 : 0,
                                               bottomTrailingRadius: isTablet ? 28 : 0, topTrailingRadius: isTablet ? 28 : 30, style: .continuous)
            ZStack(alignment: isTablet ? .center : .bottom) {
                ApprovedColor.scrim(colorScheme)
                    .opacity(isLowered ? 0 : 1)
                    .onTapGesture(perform: onDismiss)
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    if !isTablet && !bare {
                        Capsule().fill(c(ApprovedColor.track))
                            .frame(width: 40, height: 5).padding(.top, 8).padding(.bottom, 4)
                            .accessibilityHidden(true)
                    }
                    content()
                    if heightFraction != nil { Spacer(minLength: 0) }
                }
                .padding(.bottom, isTablet ? 14 : geometry.safeAreaInsets.bottom + 6)
                .frame(width: isTablet ? min(560, screen.width * 0.6) : screen.width)
                .frame(height: heightFraction.map { screen.height * $0 })
                .frame(maxHeight: heightFraction == nil ? screen.height * (isTablet ? 0.86 : 0.92) : nil, alignment: .top)
                .fixedSize(horizontal: false, vertical: heightFraction == nil)
                .background(c(ApprovedColor.sheet), in: shape)
                .overlay {
                    if isTablet { shape.strokeBorder(c(ApprovedColor.hairline), lineWidth: 1) }
                    else { shape.stroke(c(ApprovedColor.hairline), lineWidth: 1).mask(alignment: .top) { Rectangle().frame(height: 31) } }
                }
                .clipShape(shape)
                .shadow(color: isTablet ? .black.opacity(0.4) : .clear, radius: 30, y: 24)
                // Below the screen's bottom edge until it rises (a tablet card, centred, fades in instead).
                .offset(y: isLowered && !isTablet ? screen.height : 0)
                .opacity(isLowered && isTablet ? 0 : 1)
                .accessibilityAddTraits(.isModal)
            }
            .frame(width: screen.width, height: screen.height)
            .offset(x: -geometry.safeAreaInsets.leading, y: -geometry.safeAreaInsets.top)
        }
        // The container safe area only: the keyboard stays a safe-area inset, so its height arrives in
        // `safeAreaInsets.bottom` and the sheet's bottom padding lifts the content (a text field) above it.
        .ignoresSafeArea(.container)
        .accessibilityAction(.escape, onDismiss)
        .onAppear {
            guard risesWithKeyboard, !hasRisen else { return }
            withAnimation(Self.keyboardCurve) { hasRisen = true }
        }
    }
}

/// Runs `change` (the state that presents a full-screen cover) without the cover's slide-up: for sheets that rise with
/// the keyboard themselves (`ApprovedSheetOverlay.risesWithKeyboard`). Dismissal keeps the cover's own animation.
@MainActor
func presentWithoutCoverSlide(_ change: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, change)
}

/// `sheetHead`: a 90 pt leading slot, the centred 16 pt bold title, a 90 pt trailing slot; 6/12/10 padding.
struct L2SheetHeader<Leading: View, Trailing: View>: View {
    let title: Text
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        HStack(spacing: 0) {
            leading().frame(width: 90, alignment: .leading)
            title.l2Text(16, weight: .bold).foregroundStyle(L2(scheme: colorScheme)(ApprovedColor.ink))
                .frame(maxWidth: .infinity).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
            trailing().frame(width: 90, alignment: .trailing)
        }
        .padding(.top, 6).padding(.horizontal, 12).padding(.bottom, 10)
    }
}

/// `textBtn`: accent text, 15 pt (bold when `isBold`), 8/4 padding.
struct L2TextButton: View {
    let title: String
    var isBold = false
    var isEnabled = true
    var identifier: String?
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(title)).l2Text(15, weight: isBold ? .bold : .semibold)
                .foregroundStyle(L2(scheme: colorScheme)(ApprovedColor.selection))
                .padding(.vertical, 8).padding(.horizontal, 4).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!isEnabled).opacity(isEnabled ? 1 : 0.4)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// `saved`: the check, "Saved as a new photo", "The original is unchanged.", then Share, Keep
/// editing and Choose another photo.
struct SavedSheetContent: View {
    let onShare: () -> Void
    let onKeepEditing: () -> Void
    let onChooseAnother: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// `saved`: a 52 pt lime circle with the 28 pt check, "Saved as a new photo" (20 pt heading, 6 pt above), "The
    /// original is unchanged." (14 pt ink2); then Share (primary), Keep editing (line), Choose another photo (plain,
    /// 44 pt, 15 pt semibold), 10 pt apart, padding 18/20/4.
    var body: some View {
        let c = L2(scheme: colorScheme)
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                ApprovedIconView(icon: .check, size: 28)
                    .foregroundStyle(c(ApprovedColor.onAccent))
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(c(ApprovedColor.accent)))
                    .accessibilityHidden(true)
                Text("Saved as a new photo").l2Heading(20).foregroundStyle(c(ApprovedColor.ink))
                    .padding(.top, 6)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("saved.title")
                Text("The original is unchanged.").l2Text(14).foregroundStyle(c(ApprovedColor.inkSecondary))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20).padding(.top, 10)
            VStack(spacing: 10) {
                Button(action: onShare) { L2Label(title: Text("Share"), icon: .share, iconSize: 20) }
                    .buttonStyle(L2WideButtonStyle(kind: .primary))
                    .accessibilityIdentifier("saved.share")
                Button("Keep editing", action: onKeepEditing)
                    .buttonStyle(L2WideButtonStyle(kind: .line))
                    .accessibilityIdentifier("saved.keepEditing")
                Button(action: onChooseAnother) {
                    Text("Choose another photo").l2Text(15, weight: .semibold).foregroundStyle(c(ApprovedColor.ink))
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("saved.chooseAnother")
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
        }
    }
}

/// `favReplace`: sheetHead (Cancel · "Replace a favourite"), then one listRow per favourite: name, category, and
/// "Replace" in bold accent.
struct ReplaceFavouriteSheetContent: View {
    let model: DevelopPanelModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = L2(scheme: colorScheme)
        VStack(spacing: 0) {
            L2SheetHeader(title: Text("Replace a favourite"),
                          leading: { L2TextButton(title: "Cancel", identifier: "replace.cancel") { model.isReplaceSheetShown = false } },
                          trailing: { EmptyView() })
            // Ten favourites (owner, 2026-10-11) outgrow a small phone: the rows scroll inside the fitted sheet.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    let ids = model.favourites.presetIDs
                    ForEach(ids.indices, id: \.self) { index in
                        let id = ids[index]
                        if let preset = model.session.library.pack.preset(id: id) {
                            Button { model.replaceFavourite(id) } label: {
                                L2ListRow(title: Text(preset.displayName),
                                          subtitle: Text(model.session.library.pack.category(id: preset.categoryID)?.name ?? ""),
                                          isFirst: index == 0) {
                                    Text("Replace").l2Text(14, weight: .bold).foregroundStyle(c(ApprovedColor.selection))
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("replace.row.\(id)")
                        }
                    }
                }
            }
        }
    }
}

