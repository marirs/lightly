import CoreGraphics
import Foundation
import ImageIO
import OSLog
import simd

/// The light-leak pack (owner, 2026-10-11: real light leaks from the owner's film-burn clips), built by
/// shared/leaks/build_leaks.py and copied into the app as `LeakPack/` by scripts/bundle_leak_pack.sh. The pack is
/// git-ignored, so a build can lack it: then it is empty and Effects › Light Leaks offers only None.
struct LeakPack: Sendable, Equatable {
    struct Leak: Sendable, Equatable, Identifiable {
        /// `leak-<12 hex>`: what `effects.lightLeak.style` stores.
        let id: String
        let name: String
        /// Paths relative to the pack folder.
        let imagePath: String
        let thumbnailPath: String
        let imageSha256: String
        let width: Int
        let height: Int
    }

    /// In the manifest's order, which is the gallery's.
    let leaks: [Leak]
    /// Where the images are; nil for the empty pack.
    let directory: URL?

    static let empty = LeakPack(leaks: [], directory: nil)

    func leak(id: String) -> Leak? { leaks.first { $0.id == id } }

    func imageURL(_ leak: Leak) -> URL? { directory?.appendingPathComponent(leak.imagePath) }
    func thumbnailURL(_ leak: Leak) -> URL? { directory?.appendingPathComponent(leak.thumbnailPath) }

    /// The app's pack, read once on first use. The manifest is ~20 KB; DevelopLibrary touches this at launch, off the
    /// main actor, so the panel never waits for it.
    static let bundled: LeakPack = LeakPackLoader.loadBundled().pack
}

/// Reads `leaks.json` (format "lightly-leak-pack" 1). The pack is untrusted input: a manifest of another format, or
/// one with a malformed entry, loads nothing rather than half a gallery.
enum LeakPackLoader {
    static let bundleDirectoryName = "LeakPack"
    static let manifestFileName = "leaks.json"
    static let supportedFormat = "lightly-leak-pack"
    static let supportedFormatVersion = 1

    enum Problem: Error, Equatable {
        case missing
        case unreadableManifest(String)
        case unsupportedFormat(String, Int)
        case malformedLeak(index: Int)
    }

    private static let logger = Logger(subsystem: "com.lightlylabs.lightly", category: "LeakPack")

    static func loadBundled(from bundle: Bundle = .main) -> (pack: LeakPack, problem: Problem?) {
        let directory = (bundle.resourceURL ?? bundle.bundleURL).appendingPathComponent(bundleDirectoryName, isDirectory: true)
        let result = load(from: directory)
        if let problem = result.problem {
            logger.error("Light-leak pack not loaded: \(String(describing: problem), privacy: .public)")
        } else {
            logger.info("Light-leak pack: \(result.pack.leaks.count) leaks")
        }
        return result
    }

    static func load(from directory: URL) -> (pack: LeakPack, problem: Problem?) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestFileName)) else { return (.empty, .missing) }
        do {
            return (LeakPack(leaks: try read(data), directory: directory), nil)
        } catch let problem as Problem {
            return (.empty, problem)
        } catch {
            return (.empty, .unreadableManifest(error.localizedDescription))
        }
    }

    static func read(_ data: Data) throws -> [LeakPack.Leak] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Problem.unreadableManifest("not an object") }
        let format = root["format"] as? String ?? "", version = root["formatVersion"] as? Int ?? -1
        guard format == supportedFormat, version == supportedFormatVersion else { throw Problem.unsupportedFormat(format, version) }
        guard let items = root["leaks"] as? [[String: Any]] else { throw Problem.unreadableManifest("no leaks") }
        return try items.enumerated().map { index, item in
            guard let id = item["id"] as? String, EditRecipe.Effects.LightLeak.Style.isLeakImageID(id),
                  let name = item["name"] as? String, !name.isEmpty,
                  let image = item["image"] as? String, let thumbnail = item["thumbnail"] as? String,
                  // Paths stay inside the pack folder.
                  !image.contains(".."), !thumbnail.contains(".."), !image.hasPrefix("/"), !thumbnail.hasPrefix("/"),
                  let sha = item["imageSha256"] as? String, sha.count == 64,
                  let width = item["width"] as? Int, let height = item["height"] as? Int, width > 0, height > 0 else {
                throw Problem.malformedLeak(index: index)
            }
            return LeakPack.Leak(id: id, name: name, imagePath: image, thumbnailPath: thumbnail, imageSha256: sha, width: width, height: height)
        }
    }

    /// Decodes a pack JPEG upright, as it is stored (build_leaks.py writes no orientation).
    static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// A decoded leak image: RGBA8, sRGB-encoded (the values the contract screens with), alpha unused.
struct LeakImage: Sendable {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4)
        self.width = width; self.height = height; self.rgba = rgba
    }

    /// Converts any decoded image to sRGB RGBA8 (the pack's JPEGs are sRGB already; this also pins the layout).
    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, rgba: bytes)
    }
}

/// Decoded leak images by id, shared by preview and Save copy so a leak is decoded once, not per render. Holds the
/// few most recently used (a full image is 1280 × 720 × 4 ≈ 3.7 MB; the person rarely flips between more than a
/// few), so browsing the whole gallery cannot pile up all of them.
final class LeakImageCache: @unchecked Sendable {
    static let bundled = LeakImageCache(pack: { LeakPack.bundled })

    private let pack: @Sendable () -> LeakPack
    private let capacity: Int
    private let lock = NSLock()
    /// Most recently used last. Guarded by `lock`.
    private var entries: [(id: String, image: LeakImage)] = []

    init(capacity: Int = 3, pack: @escaping @Sendable () -> LeakPack) {
        self.capacity = capacity
        self.pack = pack
    }

    /// The decoded image, or nil when this build's pack has no such leak or it cannot be read (no light is added).
    func image(for id: String) -> LeakImage? {
        lock.lock(); defer { lock.unlock() }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.image
        }
        // Decoded under the lock: two renders asking for the same new leak decode it once.
        let pack = pack()
        guard let leak = pack.leak(id: id), let url = pack.imageURL(leak),
              let decoded = LeakPackLoader.decode(url), let image = LeakImage(decoded) else { return nil }
        entries.append((id, image))
        if entries.count > capacity { entries.removeFirst() }
        return image
    }
}

/// A leak-pack image screened over the frame (rendering-v2 revision 8, §Light leak "Leak images"): aspect-filled,
/// centred at (x·W/100, y·H/100), turned clockwise by `rotation` about that centre; L = bilinear sample × f × intensity/100
/// with f the soft edge (the last 8 % of each side fades out)
/// and out = 1 − (1 − in)(1 − L), all on sRGB-encoded values. Outside the turned image no light is added. Preview and
/// Save copy evaluate the same code at their own frame sizes.
struct LeakImageEvaluator: Sendable {
    let image: LeakImage
    /// o: the image's centre on the frame, in frame pixels.
    let centre: SIMD2<Double>
    /// s: frame pixels per image pixel (aspect fill: the image covers the frame when centred and unturned).
    let scale: Double
    let cosine: Double, sine: Double
    /// intensity / 100.
    let gain: Double

    init?(_ leak: EditRecipe.Effects.LightLeak, image: LeakImage, frameWidth: Int, frameHeight: Int) {
        guard leak.intensity > 0, image.width > 0, image.height > 0, frameWidth > 0, frameHeight > 0 else { return nil }
        self.image = image
        centre = SIMD2(leak.x / 100 * Double(frameWidth), leak.y / 100 * Double(frameHeight))
        scale = max(Double(frameWidth) / Double(image.width), Double(frameHeight) / Double(image.height))
        let theta = leak.rotation * .pi / 180
        cosine = cos(theta); sine = sin(theta)
        gain = leak.intensity / 100
    }

    /// The image position (in image pixels, origin at its top-left corner) under the frame pixel centre (x, y).
    func imagePoint(x: Int, y: Int) -> SIMD2<Double> {
        let d = SIMD2(Double(x) + 0.5, Double(y) + 0.5) - centre
        // R(−θ)·d undoes the clockwise turn (y points down, so R(θ) with these signs turns clockwise on screen).
        let unturned = SIMD2(cosine * d.x + sine * d.y, -sine * d.x + cosine * d.y)
        return unturned / scale + SIMD2(Double(image.width) / 2, Double(image.height) / 2)
    }

    /// Width of the soft edge, as a fraction of each side (rendering-v2 revision 8, 080003a).
    static let edgeFade = 0.08

    /// L at a frame pixel (0…1 per channel), or nil outside the image.
    func light(x: Int, y: Int) -> SIMD3<Double>? {
        let u = imagePoint(x: x, y: y)
        let w = Double(image.width), h = Double(image.height)
        guard u.x >= 0, u.y >= 0, u.x <= w, u.y <= h else { return nil }
        let fade = Self.edgeFactor(u, width: w, height: h)
        guard fade > 0 else { return nil }
        return bilinear(u) / 255 * (fade * gain)
    }

    /// f = smoothstep(0, 0.08, min(u.x/iw, 1 − u.x/iw)) · smoothstep(0, 0.08, min(u.y/ih, 1 − u.y/ih)): the image's light
    /// fades out over the last 8 % of each side, so a moved or turned leak never shows its edge as a line.
    static func edgeFactor(_ u: SIMD2<Double>, width: Double, height: Double) -> Double {
        smoothstep(min(u.x / width, 1 - u.x / width)) * smoothstep(min(u.y / height, 1 - u.y / height))
    }

    /// smoothstep(0, edgeFade, t).
    static func smoothstep(_ t: Double) -> Double {
        let k = min(max(t / edgeFade, 0), 1)
        return k * k * (3 - 2 * k)
    }

    /// Bilinear between pixel centres (pixel i covers [i, i + 1)); the outermost half pixel repeats the edge.
    func bilinear(_ u: SIMD2<Double>) -> SIMD3<Double> {
        let px = min(max(u.x - 0.5, 0), Double(image.width - 1)), py = min(max(u.y - 0.5, 0), Double(image.height - 1))
        let x0 = Int(px), y0 = Int(py)
        let x1 = min(x0 + 1, image.width - 1), y1 = min(y0 + 1, image.height - 1)
        let fx = px - Double(x0), fy = py - Double(y0)
        func texel(_ x: Int, _ y: Int) -> SIMD3<Double> {
            let o = (y * image.width + x) * 4
            return SIMD3(Double(image.rgba[o]), Double(image.rgba[o + 1]), Double(image.rgba[o + 2]))
        }
        let top = texel(x0, y0) * (1 - fx) + texel(x1, y0) * fx
        let bottom = texel(x0, y1) * (1 - fx) + texel(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }

    func apply(_ rgb: SIMD3<Float>, x: Int, y: Int) -> SIMD3<Float> {
        guard let light = light(x: x, y: y) else { return rgb }
        let base = SIMD3<Double>(rgb)
        let one = SIMD3<Double>(repeating: 1)
        return SIMD3<Float>(one - (one - base) * (one - light))
    }
}
