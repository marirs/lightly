import XCTest
@testable import Lightly

/// Editors in fixed states for snapshot, layout and contrast tests.
///
/// Uses the deterministic fixture Look pack (`LookPackFixture.editorPack`),
/// loaded through the real `LookPackLoader`, and the shipping "model not
/// bundled" Auto. Never the real pack: it is private, git-ignored and changes
/// whenever the catalog does, which would make every snapshot unstable.
@MainActor
enum EditorFixtures {

    /// A developed editor (Auto resolved as unavailable), renders settled.
    static func readyEditor(
        lookStop: Int? = nil,
        lookBook: LUTLookBook = LookPackFixture.editorBook,
        writer: any PhotoLibraryWriting = SpyLibraryWriter(),
        auto: any AutoEnhancing = ModelNotBundledAutoEnhancer()
    ) async throws -> LUTEditorViewModel {
        let viewModel = LUTEditorViewModel(
            photo: TestFixtures.makePhoto(), autoEnhancer: auto,
            lookBook: lookBook, renderer: try MetalLUTRenderer(), libraryWriter: writer
        )
        await viewModel.developTask?.value
        if let lookStop { viewModel.settleStop(lookStop) }
        await viewModel.settleRendering()
        return viewModel
    }

    /// An editor restored from a one-entry saved session whose Look is `look`.
    static func restoredEditor(look: SavedLookRef) async throws -> LUTEditorViewModel {
        let source = try SavedEditCodec.decodeState(try SavedEditFormatTests.fixture("v2-no-look.json")).source
        let entry = SavedEditState(source: source, auto: .noModelInBuild, look: look, revision: 0)
        let viewModel = LUTEditorViewModel(
            photo: TestFixtures.makePhoto(), autoEnhancer: ModelNotBundledAutoEnhancer(),
            lookBook: LookPackFixture.editorBook, renderer: try MetalLUTRenderer(), libraryWriter: SpyLibraryWriter(),
            restoringSession: SavedEditSession(entries: [entry], cursor: 0, capacity: 50, lastIssuedRevision: 0)
        )
        await viewModel.developTask?.value
        await viewModel.settleRendering()
        return viewModel
    }

    /// An editor whose Auto has not resolved yet. Callers close it.
    static func developingEditor() throws -> LUTEditorViewModel {
        LUTEditorViewModel(
            photo: TestFixtures.makePhoto(),
            autoEnhancer: DelayedAutoEnhancer(wrapped: ModelNotBundledAutoEnhancer(), delay: .seconds(60)),
            lookBook: LookPackFixture.editorBook, renderer: try MetalLUTRenderer(), libraryWriter: SpyLibraryWriter()
        )
    }
}
