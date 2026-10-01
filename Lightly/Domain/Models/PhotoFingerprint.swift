import CoreGraphics
import CryptoKit
import Foundation

/// Content identity of a decoded photograph, for render cache keys.
///
/// Why content and not `SelectedPhoto.id`: the UUID is minted per load, so the
/// same photo picked twice would miss the cache, and — more importantly — any
/// cache that outlives one editor would have nothing tying an entry to pixels.
/// Why not dimensions (v1): two photos from the same camera share them, so a
/// width-keyed cache served the first photo's thumbnails for the second.
///
/// The digest is SHA-256 of the *encoded* bytes when available: a few MB to
/// hash instead of 4 bytes/px of decoded pixels (≈190 MB at 48 MP), and the
/// decode is deterministic for given bytes. Orientation is applied at decode
/// from those same bytes, so it is implied by the digest; the upright pixel
/// size is stored as well so a loader change that decodes the same bytes at a
/// different proxy size cannot alias. When no encoded bytes exist (synthetic
/// or rendered images) the decoded pixel bytes are hashed instead.
struct PhotoFingerprint: Hashable, Sendable {
    let digest: String
    let pixelWidth: Int
    let pixelHeight: Int

    init(encodedData: Data, image: CGImage) {
        if encodedData.isEmpty {
            self = PhotoFingerprint(pixelsOf: image)
        } else {
            self.init(digest: Self.hexDigest(of: encodedData), image: image)
        }
    }

    /// Fingerprint from the decoded pixel buffer, for images with no source bytes.
    init(pixelsOf image: CGImage) {
        let pixels = image.dataProvider?.data as Data? ?? Data()
        // Bitmap layout is folded in so identical bytes under a different
        // interpretation (row padding, channel order) do not collide.
        var layout = Data()
        for value in [image.bytesPerRow, image.bitsPerPixel, Int(image.bitmapInfo.rawValue)] {
            withUnsafeBytes(of: value) { layout.append(contentsOf: $0) }
        }
        self.init(digest: "px-" + Self.hexDigest(of: layout + pixels), image: image)
    }

    private init(digest: String, image: CGImage) {
        self.digest = digest
        self.pixelWidth = image.width
        self.pixelHeight = image.height
    }

    private static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
