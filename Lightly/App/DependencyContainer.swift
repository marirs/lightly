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
    let favouritesManager: any FavouritesManaging
    let autoEnhancer: any AutoEnhancing
    let lookBook: LUTLookBook
    /// nil when Metal is unavailable; the editor then reports a failure.
    let lutRenderer: (any LUTRendering)?

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
            presetCatalog: BuiltInPresetCatalog.bundled(),
            thumbnailRenderer: CoreImageThumbnailRenderer(),
            exporter: ImageIOPhotoExporter(),
            libraryWriter: PhotoKitLibraryWriter(),
            favouritesManager: UserDefaultsFavouritesManager(),
            autoEnhancer: makeAutoEnhancer(),
            lookBook: makeLookBook(),
            lutRenderer: try? MetalLUTRenderer()
        )
    }

    /// No production Auto model exists, so Auto is explicitly unavailable.
    /// The research (FiveK-derived) weights must never be bundled.
    private static func makeAutoEnhancer() -> any AutoEnhancing {
        let enhancer = ModelNotBundledAutoEnhancer()
        #if DEBUG
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--auto-delay-seconds"),
           arguments.indices.contains(flag + 1), let seconds = Double(arguments[flag + 1]) {
            return DelayedAutoEnhancer(wrapped: enhancer, delay: .seconds(seconds))
        }
        #endif
        return enhancer
    }

    /// Internal builds get provisional placeholder Looks (labelled as such
    /// on screen); release builds get the shipped book, which stays empty
    /// until curated, validated Look LUTs exist (M3/M4).
    private static func makeLookBook() -> LUTLookBook {
        #if DEBUG
        return PlaceholderLookBook.make()
        #else
        return .bundled
        #endif
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
            libraryWriter: libraryWriter,
            favouritesManager: favouritesManager,
            autoEnhancer: autoEnhancer,
            lookBook: lookBook,
            lutRenderer: lutRenderer
        )
    }
}
