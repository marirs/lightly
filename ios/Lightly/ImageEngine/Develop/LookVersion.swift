import CryptoKit
import Foundation

/// `lookVersion` (rendering-v2 §4.3): the first 12 hex digits of the sha256 of the canonical JSON
/// (sorted keys, compact separators) of
/// `{recipeVersion, recipe, developModel: {id, version, constantsSha256}, globalOverrideSha256}`.
///
/// The app uses the pack's published value as the bake cache key and in saved recipes; this
/// recomputation exists so the parity tests can prove the two platforms hash identically.
enum LookVersion {
    static func compute(recipe: CanonicalJSON, recipeVersion: Int, model: DevelopModel, globalOverrideSha256: String?) -> String {
        let body = CanonicalJSON.object([
            ("recipeVersion", .number(String(recipeVersion))),
            ("recipe", recipe),
            ("developModel", .object([
                ("id", .string(model.id)),
                ("version", .number(String(model.version))),
                ("constantsSha256", .string(model.constantsSha256))
            ])),
            ("globalOverrideSha256", globalOverrideSha256.map(CanonicalJSON.string) ?? .null)
        ])
        let digest = SHA256.hash(data: body.serialized(keys: .sorted))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }
}
