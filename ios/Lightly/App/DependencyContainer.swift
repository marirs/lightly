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
    /// Develop's model, preset pack and renderer; starts loading in the background at launch.
    let developLibrary: DevelopLibrary

    /// The current composition: the slice-2 editor (`EditorSession`) over the format-3 preset pack.
    ///
    /// v3 differs: the M2 LUT editor and its format-2 Look pack (one LUT file per Look) are gone;
    /// presets are recipes baked on the device.
    static func live() -> DependencyContainer {
        let library = DevelopLibrary()
        let renderer = try? MetalLUTRenderer()
        Task { await library.loadBundled(lutApplier: renderer) }
        return DependencyContainer(
            photoLoader: ImageIOPhotoLoader(),
            libraryWriter: makeLibraryWriter(),
            autoEnhancer: makeAutoEnhancer(),
            developLibrary: library
        )
    }

    private static func makeLibraryWriter() -> any PhotoLibraryWriting {
        #if DEBUG
        // UI tests and design captures exercise Save copy without touching the simulator's library
        // or the system permission prompt (`--fake-library-writer`), or hold "Saving a copy…" on
        // screen (`--slow-library-writer`). Read at each save: a capture session changes them
        // between screens (DebugCaptureDriver).
        return DebugArgumentsLibraryWriter(fallback: PhotoKitLibraryWriter())
        #else
        return PhotoKitLibraryWriter()
        #endif
    }

    /// No production Auto model exists, so Auto is explicitly unavailable.
    /// The research (FiveK-derived) weights must never be bundled.
    private static func makeAutoEnhancer() -> any AutoEnhancing {
        let enhancer = ModelNotBundledAutoEnhancer()
        #if DEBUG
        // Design captures and UI tests reach the approved "didn't finish" state (`--auto-fails`)
        // or a slow Auto (`--auto-delay-seconds`); read at each run (DebugCaptureDriver).
        return DebugArgumentsAutoEnhancer(fallback: enhancer)
        #else
        return enhancer
        #endif
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
            sceneAnalyser: OnDeviceSceneAnalyser(depthEstimators: DepthEstimatorProvider()),
            developLibrary: developLibrary,
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
        let arguments = DebugArguments.current
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

#if DEBUG
/// Accepts every save and writes nothing (DEBUG `--fake-library-writer`).
struct DebugInertLibraryWriter: PhotoLibraryWriting {
    let delay: Duration
    func save(_ data: Data, fileExtension: String) async throws {
        try await Task.sleep(for: delay)
    }
}
#endif
