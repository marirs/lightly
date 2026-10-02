import Foundation

/// Where a Look's LUT came from and how far it has been checked (spec §4.5).
///
/// Values are kept as the manifest's strings rather than closed enums: a newer
/// pack may introduce a source or status this build does not know, and the
/// honest reading of an unknown status is "not validated", which
/// `isApproximate` already gives.
struct LookProvenance: Equatable, Sendable {
    /// The calibrated Lightroom approximation (held-out median ΔE00 4.8).
    static let modelApproximationSource = "lr-model-approximation"
    static let validatedStatus = "validated"

    /// "lightroom-hald" or "lr-model-approximation" in pack format 1.
    let lutSource: String
    /// "unvalidated" until the desktop kit checks the Look against Lightroom.
    let validation: String
    /// Operators the LUT cannot carry (clarity, texture, vignette, grain, …).
    let omittedOperators: [String]
    /// Operators the LUT only approximates globally (adaptive tone sliders).
    let approximatedGlobally: [String]

    /// True when the screen must not present this Look as a faithful
    /// Lightroom rendering.
    var isApproximate: Bool {
        lutSource == Self.modelApproximationSource || validation != Self.validatedStatus
    }
}

/// A Look as the M2 pipeline applies it: a LUT compiled offline from one
/// curated preset (spec §4.5).
struct LUTLook: Identifiable, Equatable, Sendable {
    /// Stable across relabelling and reordering of the catalog: it depends
    /// only on the preset, so a saved edit keeps resolving to the same Look.
    let id: String
    /// Changes whenever the LUT's bytes change (pack: a sha256 prefix).
    let version: String
    /// The preset's own name, shown verbatim on the slider (spec D6).
    let name: String
    let lut: LUT3D
    let provenance: LookProvenance
}

/// One category of the stepped Look slider (spec D5/D6).
///
/// Stop 0 of every category is the implicit Auto stop (no Look); `lookIDs`
/// are stops 1…n in the pack's browse order. Categories are catalog data:
/// their IDs, labels and number come from the Look pack, never from code.
struct LUTLookCategory: Identifiable, Equatable, Sendable {
    /// Opaque, stable identifier (e.g. "cat-warm"); used for accessibility
    /// identifiers, never shown.
    let id: String
    /// Display label, verbatim from the pack. Provisional in pack format 1.
    // DEFERRED: localised category labels. The pack carries one label per
    // category today; localisation needs a per-locale label in the catalog.
    let label: String
    let lookIDs: [String]
}

/// The Looks available to the LUT editor. Lookup is exact (spec §4.5): an
/// unknown ID is unavailable, never substituted.
struct LUTLookBook: Sendable {
    let looks: [LUTLook]
    /// Slider categories, in pack order. Empty when only lookup matters
    /// (e.g. session tests) or when no pack could be loaded.
    let categories: [LUTLookCategory]

    init(looks: [LUTLook], categories: [LUTLookCategory] = []) {
        self.looks = looks
        self.categories = categories
    }

    /// No Looks at all: the editor says "No Looks are available in this build."
    static let empty = LUTLookBook(looks: [])

    func look(id: String) -> LUTLook? {
        looks.first { $0.id == id }
    }

    /// Stops 1…n of a category, in slider order. Unknown IDs are skipped
    /// (exact lookup; never substituted).
    func stops(inCategory categoryID: String) -> [LUTLook] {
        guard let category = categories.first(where: { $0.id == categoryID }) else { return [] }
        return category.lookIDs.compactMap(look(id:))
    }

    /// Slider position of `lookID` in a category: 0 (Auto) when there is
    /// no Look or it belongs to another category (Android `stopIndexOf`).
    func stopIndex(of lookID: String?, inCategory categoryID: String) -> Int {
        guard let lookID, let index = stops(inCategory: categoryID).firstIndex(where: { $0.id == lookID }) else {
            return 0
        }
        return index + 1
    }

    /// True when any Look the slider offers is an approximation or has not
    /// been validated against Lightroom; the editor must then say so.
    var offersApproximateLooks: Bool {
        categories.contains { category in
            stops(inCategory: category.id).contains { $0.provenance.isApproximate }
        }
    }
}
