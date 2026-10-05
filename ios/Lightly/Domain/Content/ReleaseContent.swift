import Foundation

/// Release text shown under More › Legal and About › Support, loaded from the bundled
/// `Content/legal.json`.
///
/// The real Privacy Policy, Terms of Use and Support destination are a product-owner dependency
/// (plan D2). Until they arrive the file holds `null` for each, and the screens show a neutral
/// "not available in this build" state. Nothing here, and nothing in the views, supplies
/// placeholder or invented text.
///
/// File format (schema 1):
/// ```json
/// {
///   "schemaVersion": 1,
///   "privacyPolicy": { "sections": [ { "heading": "…", "paragraphs": ["…"] } ] },
///   "termsOfUse":    { "sections": [ … ] },
///   "support":       { "url": "mailto:… or https://…" }
/// }
/// ```
struct ReleaseContent: Sendable, Equatable, Decodable {

    struct Document: Sendable, Equatable, Decodable {
        struct Section: Sendable, Equatable, Decodable {
            let heading: String?
            let paragraphs: [String]
        }
        let sections: [Section]

        /// A document with no readable text counts as missing.
        var hasText: Bool {
            sections.contains { section in section.paragraphs.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        }
    }

    struct Support: Sendable, Equatable, Decodable {
        let url: URL
    }

    let schemaVersion: Int
    let privacyPolicy: Document?
    let termsOfUse: Document?
    let support: Support?

    static let supportedSchemaVersion = 1

    /// No release text at all: every screen shows its unavailable state.
    static let none = ReleaseContent(schemaVersion: supportedSchemaVersion, privacyPolicy: nil, termsOfUse: nil, support: nil)

    /// The documents that only count when they have text.
    var availablePrivacyPolicy: Document? { privacyPolicy.flatMap { $0.hasText ? $0 : nil } }
    var availableTermsOfUse: Document? { termsOfUse.flatMap { $0.hasText ? $0 : nil } }

    /// A Support destination Lightly can open: mail or the web only.
    var supportURL: URL? {
        guard let url = support?.url, let scheme = url.scheme?.lowercased(), ["mailto", "https"].contains(scheme) else { return nil }
        return url
    }

    static func decode(_ data: Data) throws -> ReleaseContent {
        let content = try JSONDecoder().decode(ReleaseContent.self, from: data)
        guard content.schemaVersion == supportedSchemaVersion else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported content schema \(content.schemaVersion)"))
        }
        return content
    }

    /// The bundled content, or `.none` when the file is missing or unreadable: an unreadable
    /// file must never show partial or stale text.
    static func loadBundled(from bundle: Bundle = .main) -> ReleaseContent {
        guard let url = bundle.url(forResource: "legal", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let content = try? decode(data) else { return .none }
        return content
    }
}

/// Version and build, read from the bundle (never hard-coded).
struct AppVersion: Sendable, Equatable {
    let version: String
    let build: String

    init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    /// `BuildInfo.json` (written from git on every build by ios/Tools/write_build_info.sh) when present, so builds made
    /// from the Xcode IDE show their real version and build; otherwise the Info.plist values.
    init(bundle: Bundle = .main) {
        struct BuildInfo: Decodable { let version: String; let build: String }
        if let url = bundle.url(forResource: "BuildInfo", withExtension: "json"), let data = try? Data(contentsOf: url),
           let info = try? JSONDecoder().decode(BuildInfo.self, from: data) {
            version = info.version
            build = info.build
            return
        }
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}
