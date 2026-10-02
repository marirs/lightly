import XCTest
@testable import Lightly

/// Editors in fixed states for snapshot, layout and contrast tests.
///
/// Uses the real DEBUG placeholder look-book and the shipping
/// "model not bundled" Auto, so these tests see the screen users see.
@MainActor
enum EditorFixtures {

    /// A developed editor (Auto resolved as unavailable), renders settled.
    static func readyEditor(
        lookStop: Int? = nil,
        writer: any PhotoLibraryWriting = SpyLibraryWriter()
    ) async throws -> LUTEditorViewModel {
        let viewModel = LUTEditorViewModel(
            photo: TestFixtures.makePhoto(), autoEnhancer: ModelNotBundledAutoEnhancer(),
            lookBook: PlaceholderLookBook.make(), renderer: try MetalLUTRenderer(), libraryWriter: writer
        )
        await viewModel.developTask?.value
        if let lookStop { viewModel.settleStop(lookStop) }
        await viewModel.settleRendering()
        return viewModel
    }

    /// An editor whose Auto has not resolved yet. Callers close it.
    static func developingEditor() throws -> LUTEditorViewModel {
        LUTEditorViewModel(
            photo: TestFixtures.makePhoto(),
            autoEnhancer: DelayedAutoEnhancer(wrapped: ModelNotBundledAutoEnhancer(), delay: .seconds(60)),
            lookBook: PlaceholderLookBook.make(), renderer: try MetalLUTRenderer(), libraryWriter: SpyLibraryWriter()
        )
    }
}
