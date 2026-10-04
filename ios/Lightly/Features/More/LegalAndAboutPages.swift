import SwiftUI

/// Privacy Policy or Terms of Use, from the bundled release content (`ReleaseContent`).
///
/// Until the release text exists (plan D2) the page says so plainly. It never shows
/// placeholder bars or invented wording.
struct ReleaseDocumentPage: View {
    let document: ReleaseContent.Document?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let document {
            VStack(spacing: 0) {
                ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                    if let heading = section.heading {
                        ApprovedGroupLabel(text: Text(verbatim: heading))
                    }
                    ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(verbatim: paragraph)
                            .approvedText(15)
                            .foregroundStyle(ApprovedColor.inkSecondary.resolved(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding)
                            .padding(.vertical, 6)
                    }
                }
            }
            .padding(.top, 8)
            .accessibilityIdentifier("legal.document")
        } else {
            ApprovedNote("legal.unavailable", topPadding: 14)
                .accessibilityIdentifier("legal.unavailable")
        }
    }
}

/// About (approved `about`): the mark, "Lightly", version and build from the bundle, Support.
struct AboutPage: View {
    let version: AppVersion
    let openSupport: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                BrandMark(size: 44, tint: ApprovedColor.ink.resolved(colorScheme), minimumStrokeWidth: 1.6)
                Text("brand.wordmark", bundle: .main)
                    .approvedText(19, weight: .semibold)
                    .foregroundStyle(ApprovedColor.ink.resolved(colorScheme))
                Text("about.version \(version.version) \(version.build)", bundle: .main)
                    .approvedText(13)
                    .foregroundStyle(ApprovedColor.inkTertiary.resolved(colorScheme))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
            .padding(.bottom, 18)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("about.version")

            Button(action: openSupport) {
                ApprovedListRow(title: Text("support.title", bundle: .main))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("more.row.support")
        }
    }
}

/// Support (approved `support`).
///
/// The Support destination is pending (plan D2): without one the page says contact details are
/// not available in this build, and no address is shown or invented. Once `legal.json` names a
/// mail or web destination, the approved text and Contact support appear.
struct SupportPage: View {
    let version: AppVersion
    let supportURL: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            if let supportURL {
                ApprovedNote("support.note", topPadding: 14)
                HStack {
                    Button { openURL(supportURL) } label: { Text("support.contact", bundle: .main) }
                        .buttonStyle(ApprovedButtonStyle(kind: .primary))
                        .accessibilityIdentifier("support.contact")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding)
                .padding(.vertical, 8)
            } else {
                ApprovedNote("support.unavailable", topPadding: 14)
                    .accessibilityIdentifier("support.unavailable")
            }
            ApprovedListRow(title: Text("support.version", bundle: .main)) {
                Text(verbatim: "\(version.version) (\(version.build))").approvedText(15)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
