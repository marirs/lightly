import SwiftUI

/// The pages reachable from ⋮ More (approved `morePage`).
enum MorePage: Hashable, Sendable {
    case menu
    case preferences
    case favourites
    case savedSignature
    case preferredBorder
    case legal
    case privacyPolicy
    case termsOfUse
    case about
    case support
}

/// The More sheet: one page at a time, each with Back to its parent; Close on the first page.
///
/// A sheet on phones and a centred form sheet on tablets (`RootView`), as in the prototype.
/// Pages replace each other inside the sheet rather than stacking modals.
struct MoreSheet: View {
    let entry: MoreEntry
    @State private var path: [MorePage]

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    /// Reduce Motion: pages cross-fade instead of sliding in.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter initialPath: Pages already open, first to current (snapshot tests open a page
    ///   directly). By default the entry's own first page.
    init(entry: MoreEntry, initialPath: [MorePage]? = nil) {
        self.entry = entry
        _path = State(initialValue: initialPath ?? [entry == .privacyPolicyFromWelcome ? .privacyPolicy : .menu])
    }

    private var currentPage: MorePage { path.last ?? .menu }

    var body: some View {
        page(currentPage)
            .id(currentPage)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ApprovedColor.sheet.resolved(colorScheme).ignoresSafeArea())
            // The approved toast, inside the sheet so it shows over More (signature import).
            .overlay { if let toast = appState.toast { StageToast(text: toast) } }
    }

    // MARK: - Navigation

    private func open(_ page: MorePage) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.25)) { path.append(page) }
    }

    /// Back on a page: its parent, or out of the sheet when the page was the entry point (the
    /// Privacy Policy opened from Welcome returns to Welcome).
    private func back() {
        guard path.count > 1 else {
            appState.closeMore()
            return
        }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.25)) { _ = path.popLast() }
    }

    @ViewBuilder
    private func page(_ page: MorePage) -> some View {
        let isRoot = path.count == 1
        let leading: ApprovedPageHeader.Leading = (isRoot && page == .menu) ? .close : .back
        VStack(spacing: 0) {
            ApprovedPageHeader(title: title(of: page), leading: leading, titleIdentifier: "more.page.\(page)", action: back)
            ScrollView(.vertical) {
                content(of: page)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func title(of page: MorePage) -> Text {
        switch page {
        case .menu: Text("more.title", bundle: .main)
        case .preferences: Text("preferences.title", bundle: .main)
        case .favourites: Text("favourites.title", bundle: .main)
        case .savedSignature: Text("signature.title", bundle: .main)
        case .preferredBorder: Text("border.title", bundle: .main)
        case .legal: Text("legal.title", bundle: .main)
        case .privacyPolicy: Text("legal.privacyPolicy", bundle: .main)
        case .termsOfUse: Text("legal.termsOfUse", bundle: .main)
        case .about: Text("about.title", bundle: .main)
        case .support: Text("support.title", bundle: .main)
        }
    }

    @ViewBuilder
    private func content(of page: MorePage) -> some View {
        switch page {
        case .menu:
            VStack(spacing: 0) {
                navigationRow(Text("preferences.title", bundle: .main), to: .preferences)
                navigationRow(Text("legal.title", bundle: .main), to: .legal)
                navigationRow(Text("about.title", bundle: .main), to: .about)
            }
        case .preferences:
            PreferencesPage(preferences: appState.preferences, favourites: appState.favourites, open: open)
        case .favourites:
            FavouritePresetsPage(favourites: appState.favourites, catalogue: appState.presetCatalogue)
        case .savedSignature:
            SavedSignaturePage(signatures: appState.signatures, onChange: appState.signaturesChanged,
                               openSheet: appState.openSignatureSheet, showToast: appState.showToast)
        case .preferredBorder:
            PreferredBorderPage(preferences: appState.preferences)
        case .legal:
            VStack(spacing: 0) {
                navigationRow(Text("legal.privacyPolicy", bundle: .main), to: .privacyPolicy)
                navigationRow(Text("legal.termsOfUse", bundle: .main), to: .termsOfUse)
            }
        case .privacyPolicy:
            ReleaseDocumentPage(document: appState.releaseContent.availablePrivacyPolicy)
        case .termsOfUse:
            ReleaseDocumentPage(document: appState.releaseContent.availableTermsOfUse)
        case .about:
            AboutPage(version: appState.appVersion, openSupport: { open(.support) })
        case .support:
            SupportPage(version: appState.appVersion, supportURL: appState.releaseContent.supportURL)
        }
    }

    private func navigationRow(_ title: Text, to page: MorePage) -> some View {
        Button { open(page) } label: {
            ApprovedListRow(title: title)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("more.row.\(page)")
    }
}
