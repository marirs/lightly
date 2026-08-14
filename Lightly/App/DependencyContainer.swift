import Foundation

/// Composition root.
///
/// Concrete services are chosen here and nowhere else, so that swapping the
/// Phase 1 stubs for the real image engine (Phase 2) and StoreKit wiring
/// (Phase 6) is a change to this file rather than a search across the app.
@MainActor
struct DependencyContainer {
    let photoLoader: any PhotoLoading
    let entitlements: any EntitlementResolving
    let developer: any PhotoDeveloping
    let presetCatalog: any PresetProviding
    let thumbnailRenderer: any LookThumbnailRendering
    let exporter: any PhotoExporting
    let libraryWriter: any PhotoLibraryWriting

    /// The current composition.
    ///
    /// **Release builds cannot be produced while the Develop engine is a
    /// placeholder.** The `#else` branch below fails compilation deliberately.
    ///
    /// This is stronger than hiding the debug notice in release, which would be
    /// the worst possible outcome: a placeholder engine shipping *without* its
    /// disclosure. Making the build fail means the placeholder cannot reach a
    /// release binary at all, so the notice can never appear there either —
    /// there is nothing for it to disclose.
    ///
    /// To produce a release build, implement a `PhotoDeveloping` that reports
    /// `.production` and select it here.
    static func live() -> DependencyContainer {
        #if DEBUG
        let developer: any PhotoDeveloping = DebugFixedRecipeDeveloper()
        #else
        #error("""
        No production Develop engine exists yet. A release build must not ship \
        DebugFixedRecipeDeveloper: it performs real rendering but no analysis, \
        and presenting it as finished would violate specification §24.8. \
        Implement a PhotoDeveloping returning .production and select it here.
        """)
        #endif

        return DependencyContainer(
            photoLoader: ImageIOPhotoLoader(),
            entitlements: FreeTierEntitlementResolver(),
            developer: developer,
            presetCatalog: BuiltInPresetCatalog(),
            thumbnailRenderer: CoreImageThumbnailRenderer(),
            exporter: ImageIOPhotoExporter(),
            libraryWriter: PhotoKitLibraryWriter()
        )
    }

    /// Builds the root state from this container.
    func makeAppState() -> AppState {
        AppState(
            photoLoader: photoLoader,
            developer: developer,
            entitlements: entitlements,
            presetCatalog: presetCatalog,
            thumbnailRenderer: thumbnailRenderer,
            exporter: exporter,
            libraryWriter: libraryWriter
        )
    }
}
