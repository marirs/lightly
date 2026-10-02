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
            libraryWriter: libraryWriter,
            autoEnhancer: autoEnhancer,
            lookBook: lookBook,
            lutRenderer: lutRenderer
        )
    }
}
