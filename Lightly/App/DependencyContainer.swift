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
    /// Phase 2 introduces the production Develop engine backed by histogram
    /// analysis. The `#error` that blocked release builds in Phase 1 has been
    /// removed — `AnalysingDeveloper` reports `.production`, so the debug
    /// disclosure banner no longer appears.
    ///
    /// In DEBUG builds, the `DebugFixedRecipeDeveloper` can be activated via
    /// the launch argument `--fixed-recipe` for deterministic snapshot testing.
    static func live() -> DependencyContainer {
        let developer: any PhotoDeveloping = {
            #if DEBUG
            if CommandLine.arguments.contains("--fixed-recipe") {
                return DebugFixedRecipeDeveloper()
            }
            #endif
            return AnalysingDeveloper(analyser: HistogramAnalyser())
        }()

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
