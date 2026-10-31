import CoreGraphics
import Foundation
import ImageIO
import OSLog
import simd

/// The ink pack (Effects › Ink, owner-approved 2026-10-31: docs/ui/proposals/ink-2026-10-31), built by
/// shared/ink/build_inks.py and copied into the app as `InkPack/` by scripts/bundle_ink_pack.sh. The pack is git-ignored
/// like the leak pack, so a build can lack it: then it is empty and Effects › Ink offers only None.
struct InkPack: Sendable, Equatable {
    struct Ink: Sendable, Equatable, Identifiable {
        /// A stroke ink shows the photo through its mask on paper; an overlay ink is multiplied over the whole photo.
        enum Kind: String, Sendable { case stroke, overlay }

        /// `ink-<12 hex>`: what `effects.ink.id` stores.
        let id: String
        let name: String
        let kind: Kind
        /// Paths relative to the pack folder.
        let imagePath: String
        let thumbnailPath: String
        let imageSha256: String
        let width: Int
        let height: Int
    }

    /// In the manifest's order, which is the gallery's.
    let inks: [Ink]
    /// Where the images are; nil for the empty pack.
    let directory: URL?

    static let empty = InkPack(inks: [], directory: nil)

    func ink(id: String) -> Ink? { inks.first { $0.id == id } }

    func imageURL(_ ink: Ink) -> URL? { directory?.appendingPathComponent(ink.imagePath) }
    func thumbnailURL(_ ink: Ink) -> URL? { directory?.appendingPathComponent(ink.thumbnailPath) }

    /// The app's pack, read once on first use (the manifest is a few KB).
    static let bundled: InkPack = InkPackLoader.loadBundled().pack
}

/// Reads `inks.json` (format "lightly-ink-pack" 1). The pack is untrusted input, as the leak pack: a manifest of another
/// format, or one with a malformed entry, loads nothing rather than half a gallery.
enum InkPackLoader {
    static let bundleDirectoryName = "InkPack"
    static let manifestFileName = "inks.json"
    static let supportedFormat = "lightly-ink-pack"
    static let supportedFormatVersion = 1

    enum Problem: Error, Equatable {
        case missing
        case unreadableManifest(String)
        case unsupportedFormat(String, Int)
        case malformedInk(index: Int)
    }

    private static let logger = Logger(subsystem: "com.lightlylabs.lightly", category: "InkPack")

    static func loadBundled(from bundle: Bundle = .main) -> (pack: InkPack, problem: Problem?) {
        let directory = (bundle.resourceURL ?? bundle.bundleURL).appendingPathComponent(bundleDirectoryName, isDirectory: true)
        let result = load(from: directory)
        if let problem = result.problem {
            logger.error("Ink pack not loaded: \(String(describing: problem), privacy: .public)")
        } else {
            logger.info("Ink pack: \(result.pack.inks.count) inks")
        }
        return result
    }

    static func load(from directory: URL) -> (pack: InkPack, problem: Problem?) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestFileName)) else { return (.empty, .missing) }
        do {
            return (InkPack(inks: try read(data), directory: directory), nil)
        } catch let problem as Problem {
            return (.empty, problem)
        } catch {
            return (.empty, .unreadableManifest(error.localizedDescription))
        }
    }

    static func read(_ data: Data) throws -> [InkPack.Ink] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Problem.unreadableManifest("not an object") }
        let format = root["format"] as? String ?? "", version = root["formatVersion"] as? Int ?? -1
        guard format == supportedFormat, version == supportedFormatVersion else { throw Problem.unsupportedFormat(format, version) }
        guard let items = root["inks"] as? [[String: Any]] else { throw Problem.unreadableManifest("no inks") }
        return try items.enumerated().map { index, item in
            guard let id = item["id"] as? String, EditRecipe.Effects.Ink.isInkID(id),
                  let name = item["name"] as? String, !name.isEmpty,
                  let kind = (item["kind"] as? String).flatMap(InkPack.Ink.Kind.init(rawValue:)),
                  let image = item["image"] as? String, let thumbnail = item["thumbnail"] as? String,
                  // Paths stay inside the pack folder.
                  !image.contains(".."), !thumbnail.contains(".."), !image.hasPrefix("/"), !thumbnail.hasPrefix("/"),
                  let sha = item["imageSha256"] as? String, sha.count == 64,
                  let width = item["width"] as? Int, let height = item["height"] as? Int, width > 0, height > 0 else {
                throw Problem.malformedInk(index: index)
            }
            return InkPack.Ink(id: id, name: name, kind: kind, imagePath: image, thumbnailPath: thumbnail, imageSha256: sha,
                               width: width, height: height)
        }
    }

    /// Decodes a pack image upright, as it is stored (build_inks.py writes no orientation).
    static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// A decoded ink image: one 8-bit grey channel (a stroke ink's mask, 255 where the photo shows; an overlay ink's grey).
struct InkImage: Sendable {
    let width: Int
    let height: Int
    let grey: [UInt8]

    init(width: Int, height: Int, grey: [UInt8]) {
        precondition(grey.count == width * height)
        self.width = width; self.height = height; self.grey = grey
    }

    /// Converts any decoded image to 8-bit grey (the pack's files are grey already; this also pins the layout).
    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, grey: bytes)
    }
}

/// Decoded ink images by id, shared by preview and Save copy, holding the few most recently used (1600 × 745 × 1 ≈
/// 1.2 MB each), as LeakImageCache does.
final class InkImageCache: @unchecked Sendable {
    static let bundled = InkImageCache(pack: { InkPack.bundled })

    private let pack: @Sendable () -> InkPack
    private let capacity: Int
    private let lock = NSLock()
    /// Most recently used last. Guarded by `lock`.
    private var entries: [(id: String, kind: InkPack.Ink.Kind, image: InkImage)] = []

    init(capacity: Int = 3, pack: @escaping @Sendable () -> InkPack) {
        self.capacity = capacity
        self.pack = pack
    }

    /// The decoded image and its kind, or nil when this build's pack has no such ink or it cannot be read (nothing drawn).
    func image(for id: String) -> (kind: InkPack.Ink.Kind, image: InkImage)? {
        lock.lock(); defer { lock.unlock() }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return (entry.kind, entry.image)
        }
        // Decoded under the lock: two renders asking for the same new ink decode it once.
        let pack = pack()
        guard let ink = pack.ink(id: id), let url = pack.imageURL(ink),
              let decoded = InkPackLoader.decode(url), let image = InkImage(decoded) else { return nil }
        entries.append((id, ink.kind, image))
        if entries.count > capacity { entries.removeFirst() }
        return (ink.kind, image)
    }
}

/// `effects.ink` (rendering-v2 revision 10 §Ink), first in the effects stage. A stroke ink: the photo through the mask,
/// paper elsewhere, `out = a·in + (1 − a)·paper`; the whole stroke fitted inside the frame with a 6 % margin at size 100,
/// turned 90° on a portrait frame, centred at (x, y) % and turned by rotation. An overlay ink: the grey image aspect-filled
/// and centred, `out = in·(1 − k·(1 − g))`. All on sRGB-encoded values; preview and Save copy evaluate the same code at
/// their own frame sizes.
struct InkEvaluator: Sendable {
    let kind: InkPack.Ink.Kind
    let image: InkImage
    /// o: the image's centre on the frame, in frame pixels.
    let centre: SIMD2<Double>
    /// s: frame pixels per image pixel.
    let scale: Double
    let cosine: Double, sine: Double
    /// The paper colour (0…1, sRGB-encoded), for a stroke ink.
    let paper: SIMD3<Float>
    /// k = intensity / 100, for an overlay ink.
    let strength: Float

    /// The fit inside the frame at size 100: 6 % of paper on each side.
    static let strokeFit = 0.88

    init?(_ ink: EditRecipe.Effects.Ink, kind: InkPack.Ink.Kind, image: InkImage, frameWidth: Int, frameHeight: Int) {
        guard image.width > 0, image.height > 0, frameWidth > 0, frameHeight > 0 else { return nil }
        if kind == .overlay && ink.intensity <= 0 { return nil }
        self.kind = kind
        self.image = image
        let w = Double(frameWidth), h = Double(frameHeight)
        // φ: the stroke turns with a portrait photo (the masks are stored landscape).
        let quarterTurn = h > w
        let turnedWidth = Double(quarterTurn ? image.height : image.width), turnedHeight = Double(quarterTurn ? image.width : image.height)
        switch kind {
        case .stroke:
            centre = SIMD2(ink.x / 100 * w, ink.y / 100 * h)
            scale = ink.size / 100 * Self.strokeFit * min(w / turnedWidth, h / turnedHeight)
        case .overlay:
            centre = SIMD2(w / 2, h / 2)
            scale = max(w / turnedWidth, h / turnedHeight)
        }
        let theta = ink.rotation * .pi / 180 + (quarterTurn ? .pi / 2 : 0)
        cosine = cos(theta); sine = sin(theta)
        paper = Self.colour(ink.paper)
        strength = Float(min(max(ink.intensity, 0), 100) / 100)
    }

    /// `#RRGGBB` → 0…1; an unreadable colour (the codec refuses one) falls back to Warm white.
    static func colour(_ hex: String) -> SIMD3<Float> {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return colour(EditRecipe.Effects.Ink.defaultPaper) }
        return SIMD3(Float((value >> 16) & 0xFF), Float((value >> 8) & 0xFF), Float(value & 0xFF)) / 255
    }

    /// The image position (in image pixels, origin at its top-left corner) under the frame pixel centre (x, y).
    func imagePoint(x: Int, y: Int) -> SIMD2<Double> {
        let d = SIMD2(Double(x) + 0.5, Double(y) + 0.5) - centre
        // R(−θ)·d undoes the clockwise turn (y points down).
        let unturned = SIMD2(cosine * d.x + sine * d.y, -sine * d.x + cosine * d.y)
        return unturned / scale + SIMD2(Double(image.width) / 2, Double(image.height) / 2)
    }

    /// Bilinear between pixel centres (pixel i covers [i, i + 1)); texels outside the image read `outside`
    /// (0 for a stroke mask: paper; 255 for an overlay: no ink), so the cropped mask never smears its edge.
    func sample(_ u: SIMD2<Double>) -> Double {
        let outside: Double = kind == .stroke ? 0 : 255
        let px = u.x - 0.5, py = u.y - 0.5
        let x0 = Int(floor(px)), y0 = Int(floor(py))
        let fx = px - Double(x0), fy = py - Double(y0)
        func texel(_ x: Int, _ y: Int) -> Double {
            guard x >= 0, y >= 0, x < image.width, y < image.height else { return outside }
            return Double(image.grey[y * image.width + x])
        }
        let top = texel(x0, y0) * (1 - fx) + texel(x0 + 1, y0) * fx
        let bottom = texel(x0, y0 + 1) * (1 - fx) + texel(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }

    func apply(_ rgb: SIMD3<Float>, x: Int, y: Int) -> SIMD3<Float> {
        let g = Float(sample(imagePoint(x: x, y: y)) / 255)
        switch kind {
        case .stroke: return rgb * g + paper * (1 - g)
        case .overlay: return rgb * (1 - strength * (1 - g))
        }
    }
}
