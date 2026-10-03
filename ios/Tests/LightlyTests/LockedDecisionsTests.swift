import SwiftUI
import XCTest
@testable import Lightly

/// Guards the binding decisions in specification v1.1 section 0.
///
/// These are not behavioural tests so much as executable policy. They exist
/// because the spec's own warning is that a locked decision erodes quietly —
/// someone adds an enum case, or softens a string, and nothing fails. Here,
/// something fails.
final class LockedDecisionsTests: XCTestCase {

    // MARK: - Section 0.1 — native picker only

    /// A custom in-app gallery is explicitly out of V1. If a `customGallery`
    /// source ever appears, that decision is being reversed and should be a
    /// deliberate spec change rather than an incidental commit.
    func testPhotoSourceOffersOnlySystemProvidedPaths() {
        XCTAssertEqual(Set(PhotoSource.allCases), [.camera, .photoLibrary])
    }

    /// The native picker requires no Photos authorisation, so the app must not
    /// declare a photo-library usage description. Its presence would indicate
    /// someone reintroduced a permission-requiring path.
    func testAppDoesNotRequestPhotoLibraryPermission() {
        let usageDescription = Bundle.main.object(
            forInfoDictionaryKey: "NSPhotoLibraryUsageDescription"
        )
        XCTAssertNil(
            usageDescription,
            "Spec 0.1: core selection uses PhotosPicker and must not request Photos access."
        )
    }

    // MARK: - Section 0.5 — qualified privacy language

    /// No absolute on-device claim may ship. Opt-in cloud features make the
    /// unqualified form false, which is the exact risk the spec calls out.
    func testPrivacyCopyIsQualifiedAndNotAbsolute() {
        let copy = String(localized: "welcome.privacyLine")

        XCTAssertEqual(copy, "Your photos stay on your device by default.")
        XCTAssertTrue(
            copy.lowercased().contains("by default"),
            "Spec 0.5 forbids absolute on-device claims."
        )

        let forbiddenPhrases = [
            "everything stays on your device",
            "never leaves your device",
            "photos never leave"
        ]
        for phrase in forbiddenPhrases {
            XCTAssertFalse(
                copy.lowercased().contains(phrase),
                "Spec 0.5 forbids the absolute claim: \(phrase)"
            )
        }
    }

    // MARK: - Section 0.4 — product voice

    /// "AI" is an implementation detail, never the emotional headline. The
    /// user-facing strings shipped in Phase 1 must not lead with it.
    func testUserFacingWelcomeCopyDoesNotLeadWithAI() {
        let keys = [
            "welcome.tagline",
            "welcome.choosePhoto",
            "welcome.camera",
            "welcome.privacyLine"
        ]

        for key in keys {
            let value = String(localized: String.LocalizationValue(key)).lowercased()
            XCTAssertFalse(
                value.contains(" ai ") || value.hasPrefix("ai ") || value.contains("a.i."),
                "Spec 0.4: '\(key)' must not surface AI as product voice."
            )
        }
    }

    // MARK: - Section 28 — every error state has copy

    /// An error case without copy is a silent failure waiting to happen. This
    /// asserts the catalogue and the strings stay in step.
    func testEveryErrorStateHasNonPlaceholderCopy() {
        for error in LightlyError.allCases {
            let key = error.localizedMessageKey.stringKey
            XCTAssertNotNil(key, "Every error must map to a string key.")

            guard let key else { continue }
            let resolved = String(localized: String.LocalizationValue(key))

            XCTAssertFalse(
                resolved.isEmpty,
                "Spec 28: \(error) resolved to empty copy."
            )
            XCTAssertNotEqual(
                resolved,
                key,
                "Spec 28: \(error) has no entry in the String Catalogue (key echoed back)."
            )
        }
    }

    // MARK: - Section 26 — free tier gating

    /// Phase 1 ships the free tier. Every paid capability must be gated at the
    /// apply/export boundary; none may be incidentally free.
    func testFreeTierGatesEveryPaidCapability() {
        let resolver = FreeTierEntitlementResolver()

        XCTAssertEqual(resolver.level, .free)
        for capability in PaidCapability.allCases {
            XCTAssertFalse(
                resolver.canApply(capability),
                "Spec 26: \(capability) must be gated on the free tier."
            )
        }
    }
}

private extension LocalizedStringKey {
    /// Extracts the underlying key string.
    ///
    /// `LocalizedStringKey` does not expose its key, so this reads the private
    /// stored property via `Mirror`. Acceptable in a test: it is how the
    /// catalogue-coverage check above stays honest, and a failure to reflect
    /// simply fails the assertion rather than corrupting behaviour.
    var stringKey: String? {
        Mirror(reflecting: self).children
            .first { $0.label == "key" }?
            .value as? String
    }
}
