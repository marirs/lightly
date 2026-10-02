import Foundation

#if DEBUG
/// Procedural placeholder Looks for internal (DEBUG) builds.
///
/// PROVISIONAL / UNVALIDATED. These are NOT vendor presets and NOT derived
/// from any preset collection: each LUT is a simple closed-form colour
/// transform evaluated on the 33³ grid. They exist only so the stepped
/// slider, two-pass rendering, Undo/Reset and Save copy can be exercised end
/// to end before the curated look-book ships (M3/M4). The editor labels them
/// as provisional on screen (`LUTLookBook.isProvisional`).
///
/// Parity: same IDs, categories, stop order, names and transforms as
/// Android `PlaceholderLookBook` (app/editor/LookBook.kt), so both
/// platforms show the same placeholder results.
///
/// Release builds use `LUTLookBook.bundled` (empty) instead; see
/// `DependencyContainer.live()`.
enum PlaceholderLookBook {

    static func make() -> LUTLookBook {
        let definitions: [(id: String, category: String, name: String, transform: (SIMD3<Float>) -> SIMD3<Float>)] = [
            ("natural.soft", "Natural", "Soft", { SIMD3(lift($0.x, 0.04), lift($0.y, 0.04), lift($0.z, 0.04)) }),
            ("natural.crisp", "Natural", "Crisp", { SIMD3(contrast($0.x, 1.15), contrast($0.y, 1.15), contrast($0.z, 1.15)) }),
            ("warm.golden", "Warm", "Golden", { SIMD3($0.x * 1.06 + 0.02, $0.y * 1.02, $0.z * 0.9) }),
            ("warm.amber", "Warm", "Amber", { SIMD3($0.x * 1.1 + 0.03, $0.y * 1.03, $0.z * 0.82) }),
            ("cool.nordic", "Cool", "Nordic", { SIMD3($0.x * 0.92, $0.y * 1.0, $0.z * 1.08 + 0.02) }),
            ("film.fade", "Film", "Fade", { SIMD3(0.06 + 0.9 * $0.x, 0.06 + 0.9 * $0.y, 0.08 + 0.88 * $0.z) }),
            ("film.punch", "Film", "Punch", { SIMD3(contrast($0.x, 1.25), contrast($0.y, 1.2), contrast($0.z, 1.1)) }),
            ("film.teal", "Film", "Teal", { SIMD3($0.x * 1.04, $0.y, $0.z * 0.95 + 0.05 * (1 - $0.x)) }),
            ("mono.silver", "Mono", "Silver", { colour in
                let luma = 0.2126 * colour.x + 0.7152 * colour.y + 0.0722 * colour.z
                return SIMD3(repeating: luma)
            }),
        ]
        let looks = definitions.map { definition in
            LUTLook(
                id: definition.id, version: 1, name: definition.name,
                lut: .lut(dimension: LUT3D.contractDimension, definition.transform)
            )
        }
        // Category order is first appearance, as on Android.
        var categoryOrder: [String] = []
        for definition in definitions where !categoryOrder.contains(definition.category) {
            categoryOrder.append(definition.category)
        }
        let categories = categoryOrder.map { category in
            LUTLookCategory(id: category, lookIDs: definitions.filter { $0.category == category }.map(\.id))
        }
        return LUTLookBook(looks: looks, categories: categories, isProvisional: true)
    }

    private static func lift(_ value: Float, _ amount: Float) -> Float { amount + (1 - amount) * value }
    private static func contrast(_ value: Float, _ factor: Float) -> Float { 0.5 + (value - 0.5) * factor }
}
#endif
