import Foundation
import Observation
import SwiftUI

/// Preferences › Appearance.
enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// nil follows the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// The window override that applies the choice app-wide, sheets included.
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Preferences › Saving › Preferred border: which border type Border opens on first.
///
/// It is a starting point in the Border tool only. It is never applied to a photo
/// automatically, so nothing in the save path reads it.
enum PreferredBorder: String, CaseIterable, Identifiable, Sendable {
    case none
    case solid
    case photoFrame
    case polaroid

    var id: String { rawValue }
}

/// Typed, persisted preferences (approved Preferences page).
///
/// Every value is written to `UserDefaults` as soon as it changes, so a preference survives the
/// app being killed at any point. Unknown or missing stored values read as the approved defaults:
/// System appearance, Keep photo metadata on, Include location off, preferred border None.
@MainActor
@Observable
final class PreferencesStore {

    /// Storage keys. Versioned names so a future incompatible change can migrate explicitly.
    enum Key {
        static let appearance = "lightly.preferences.v1.appearance"
        static let keepsPhotoMetadata = "lightly.preferences.v1.keepPhotoMetadata"
        static let includesLocation = "lightly.preferences.v1.includeLocation"
        static let preferredBorder = "lightly.preferences.v1.preferredBorder"
        static let all = [appearance, keepsPhotoMetadata, includesLocation, preferredBorder]
    }

    @ObservationIgnored private let defaults: UserDefaults

    var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    /// "Keep photo metadata": camera, lens, aperture, shutter speed, ISO and date taken.
    var keepsPhotoMetadata: Bool {
        didSet { defaults.set(keepsPhotoMetadata, forKey: Key.keepsPhotoMetadata) }
    }

    /// "Include location": GPS coordinates in saved copies. Independent of `keepsPhotoMetadata`.
    var includesLocation: Bool {
        didSet { defaults.set(includesLocation, forKey: Key.includesLocation) }
    }

    var preferredBorder: PreferredBorder {
        didSet { defaults.set(preferredBorder.rawValue, forKey: Key.preferredBorder) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Key.appearance).flatMap(AppearancePreference.init(rawValue:)) ?? .system
        keepsPhotoMetadata = defaults.object(forKey: Key.keepsPhotoMetadata) as? Bool ?? ExportMetadataPolicy.default.keepsCaptureMetadata
        includesLocation = defaults.object(forKey: Key.includesLocation) as? Bool ?? ExportMetadataPolicy.default.includesLocation
        preferredBorder = defaults.string(forKey: Key.preferredBorder).flatMap(PreferredBorder.init(rawValue:)) ?? .none
    }

    /// The metadata switches as the encoder's policy. Save and Share use the same one.
    var exportMetadataPolicy: ExportMetadataPolicy {
        ExportMetadataPolicy(keepsCaptureMetadata: keepsPhotoMetadata, includesLocation: includesLocation)
    }

    /// Settings for Save copy with the current metadata switches.
    var saveCopySettings: ExportSettings {
        .saveCopy(metadata: exportMetadataPolicy)
    }

    /// Removes every stored preference (DEBUG launch argument for UI tests).
    static func removeAll(from defaults: UserDefaults) {
        Key.all.forEach(defaults.removeObject(forKey:))
    }
}
