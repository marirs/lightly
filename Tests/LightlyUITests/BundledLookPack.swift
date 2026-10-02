import Foundation

/// The Look pack the app under test was built with, read from the same place
/// `scripts/bundle_look_pack.sh` copies it from, so UI tests can check the
/// screen against the manifest instead of hard-coding catalog names.
///
/// Lookup order mirrors the build script: `LIGHTLY_LOOK_PACK_DIR` (pass
/// `TEST_RUNNER_LIGHTLY_LOOK_PACK_DIR` to xcodebuild), this checkout's
/// `experiments/presets/look_pack/out`, then the main checkout when running
/// from a `.claude/worktrees/<name>` worktree.
struct BundledLookPack {

    struct Category {
        let id: String
        let label: String
        /// Preset names, verbatim, in stop order (stop 1…n).
        let names: [String]

        var stopCount: Int { names.count + 1 }

        /// The slider's VoiceOver value at `stop`, e.g. "Warm, Nordic Tone (10), 3 of 5".
        func value(atStop stop: Int) -> String {
            let name = stop == 0 ? BundledLookPack.stopZeroLabel : names[stop - 1]
            return "\(label), \(name), \(stop + 1) of \(stopCount)"
        }
    }

    /// Stop 0's label in a build without an Auto model: no correction is
    /// applied, so it reads "Original", not "Auto".
    static let stopZeroLabel = "Original"

    let categories: [Category]
    let hasApproximateLooks: Bool

    /// The category and stop of the longest preset name (for large-text checks).
    var longestName: (category: Category, stop: Int)? {
        categories.flatMap { category in
            category.names.enumerated().map { (category: category, stop: $0.offset + 1, name: $0.element) }
        }
        .max { $0.name.count < $1.name.count }
        .map { ($0.category, $0.stop) }
    }

    static var searchedPaths: [String] {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["LIGHTLY_LOOK_PACK_DIR"], !override.isEmpty {
            candidates.append(override)
        }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        candidates.append(repositoryRoot + "/experiments/presets/look_pack/out")
        if let range = repositoryRoot.range(of: "/.claude/worktrees/") {
            candidates.append(String(repositoryRoot[..<range.lowerBound]) + "/experiments/presets/look_pack/out")
        }
        return candidates
    }

    static func locate() -> BundledLookPack? {
        for directory in searchedPaths {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
            let categories = manifest.categories.map { category in
                Category(id: category.id, label: category.label, names: category.stops.map(\.name))
            }
            let approximate = manifest.categories.flatMap(\.stops).contains {
                $0.lutSource == "lr-model-approximation" || $0.validation != "validated"
            }
            return BundledLookPack(categories: categories, hasApproximateLooks: approximate)
        }
        return nil
    }

    private struct Manifest: Decodable {
        struct Stop: Decodable {
            let name: String
            let lutSource: String
            let validation: String
        }
        struct Category: Decodable {
            let id: String
            let label: String
            let stops: [Stop]
        }
        let categories: [Category]
    }
}
