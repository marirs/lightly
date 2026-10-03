import Foundation

/// Composition root.
///
/// Concrete services are chosen here and nowhere else, so that swapping the
/// Phase 1 stubs for the real image engine (Phase 2) and StoreKit wiring
/// (Phase 6) is a change to this file rather than a search across the app.
@MainActor
struct DependencyContainer {
    let photoLoader: any PhotoLoading
    let libraryWriter: any PhotoLibraryWriting
    let autoEnhancer: any AutoEnhancing
    let lookBook: LUTLookBook
    /// nil when Metal is unavailable; the editor then reports a failure.
    let lutRenderer: (any LUTRendering)?

    /// The current composition: the M2 LUT editor (`LUTEditSession`).
    ///
    /// v3 differs: the recipe Develop engine (`AnalysingDeveloper`, or
    /// `DebugFixedRecipeDeveloper` behind `--fixed-recipe`) is no longer
    /// composed; the editor screen no longer has a recipe path.
    static func live() -> DependencyContainer {
        DependencyContainer(
            photoLoader: ImageIOPhotoLoader(),
            libraryWriter: PhotoKitLibraryWriter(),
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

    /// The Looks come from the Look pack bundled at build time
    /// (`scripts/bundle_look_pack.sh`), in DEBUG and release alike: there are
    /// no code-defined Looks. Without a pack the book is empty and the editor
    /// says "No Looks are available in this build."
    private static func makeLookBook() -> LUTLookBook {
        LookPackLoader.loadBundled().book
    }

    /// Builds the root state from this container.
    func makeAppState() -> AppState {
        let defaults = UserDefaults.standard
        let catalogue = DevelopPresetCatalogue.loadBundled()
        #if DEBUG
        Self.applyDebugArguments(to: defaults, catalogue: catalogue)
        #endif
        return AppState(
            photoLoader: photoLoader,
            libraryWriter: libraryWriter,
            autoEnhancer: autoEnhancer,
            lookBook: lookBook,
            lutRenderer: lutRenderer,
            preferences: PreferencesStore(defaults: defaults),
            favourites: FavouritePresetsStore(defaults: defaults, catalogue: catalogue),
            presetCatalogue: catalogue,
            releaseContent: ReleaseContent.loadBundled(),
            appVersion: AppVersion(bundle: .main)
        )
    }

    #if DEBUG
    /// Launch arguments for UI tests and the design-comparison captures (DEBUG builds only):
    /// - `--reset-preferences`: start from the approved defaults (no stored preferences or favourites).
    /// - `--seed-favourites`: store the five favourites the approved Preferences screens show
    ///   (prototype `PRIVATE_FAVS`: Portrait 13, Landscape 37, Film 12, Golden Hour 4,
    ///   Black & White 3), so a capture shows the same rows as the reference.
    private static func applyDebugArguments(to defaults: UserDefaults, catalogue: DevelopPresetCatalogue) {
        let arguments = CommandLine.arguments
        if arguments.contains("--reset-preferences") {
            PreferencesStore.removeAll(from: defaults)
            defaults.removeObject(forKey: FavouritePresetsStore.storageKey)
        }
        if arguments.contains("--seed-favourites") {
            let seeded = [("portrait", 13), ("landscape", 37), ("film", 12), ("golden-hour", 4), ("black-white", 3)]
                .compactMap { catalogue.preset(inCategory: $0.0, atStop: $0.1)?.id }
            defaults.set(seeded, forKey: FavouritePresetsStore.storageKey)
        }
    }
    #endif
}
