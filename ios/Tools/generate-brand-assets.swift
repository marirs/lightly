#!/usr/bin/env swift
// Writes the Lightly 2 brand rasters from the approved mockup's geometry (docs/ui/directions/lightly-2-concept/index.html,
// `rayEnds`, `SPECTRUM`, `SPARK`, `appIcon('rays')`), the same geometry BrandMark.swift draws:
// - AppIcon.png: 1024 × 1024, the eight spectrum rays on #050506. Full-bleed square; iOS applies its own corner mask
//   (the mockup's 228-unit corner radius is that mask's stand-in).
// - LaunchMark: `launch()` = SPARK(112) centred on --bg, so the mark alone, 112 pt, no tile, transparent background.
//
//   swift ios/Tools/generate-brand-assets.swift ios/Lightly/Resources/Assets.xcassets
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let assets = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let spectrum: [UInt32] = [0x6E5BFF, 0x2F86FF, 0x18C8F0, 0x14C99B, 0xCFF26B, 0xFFC23D, 0xFF5A5F, 0xE447C8]
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func colour(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, alpha])!
}

/// Strokes the eight rays in 1024-unit space, mapped so `viewOrigin…viewOrigin+viewSize` fills `pixels`.
/// Core Graphics' y axis points up, so the rays are mirrored vertically to keep the mockup's clockwise-from-top order.
func drawRays(in context: CGContext, pixels: Int, viewOrigin: CGFloat, viewSize: CGFloat, width: CGFloat, alpha: CGFloat) {
    let scale = CGFloat(pixels) / viewSize
    for index in 0..<8 {
        let angle = (CGFloat(index) * 45 - 90) * .pi / 180
        let outer: CGFloat = index % 2 == 0 ? 352 : 352 * 0.86
        func p(_ r: CGFloat) -> CGPoint {
            let x = 512 + cos(angle) * r, y = 512 + sin(angle) * r
            return CGPoint(x: (x - viewOrigin) * scale, y: CGFloat(pixels) - (y - viewOrigin) * scale)
        }
        context.setStrokeColor(colour(spectrum[index], alpha: alpha))
        context.setLineWidth(width * scale)
        context.setLineCap(.round)
        context.move(to: p(118)); context.addLine(to: p(outer)); context.strokePath()
    }
}

/// The mark: a 64-unit stroke at 75 % blurred by 22 units (the glow), under the 38-unit rays.
func renderMark(pixels: Int, viewOrigin: CGFloat, viewSize: CGFloat, background: UInt32?) -> CGImage {
    func blank() -> CGContext {
        CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    let glowContext = blank()
    drawRays(in: glowContext, pixels: pixels, viewOrigin: viewOrigin, viewSize: viewSize, width: 64, alpha: 0.75)
    let blurRadius = 22 * CGFloat(pixels) / viewSize
    let ci = CIContext(options: [.workingColorSpace: space])
    let glowInput = CIImage(cgImage: glowContext.makeImage()!)
    let blurred = glowInput.clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: glowInput.extent)
    let glow = ci.createCGImage(blurred, from: glowInput.extent)!

    let context = blank()
    if let background {
        context.setFillColor(colour(background))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    }
    context.draw(glow, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    drawRays(in: context, pixels: pixels, viewOrigin: viewOrigin, viewSize: viewSize, width: 38, alpha: 1)
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}

// App icon: the whole 1024 tile, opaque.
write(renderMark(pixels: 1024, viewOrigin: 0, viewSize: 1024, background: 0x050506),
      to: assets.appendingPathComponent("AppIcon.appiconset/AppIcon.png"))

// Launch mark: SPARK(112), view box 120…904, transparent (the launch background colour shows through).
let launch = assets.appendingPathComponent("LaunchMark.imageset")
var images: [[String: Any]] = []
for (idiom, scales) in [("iphone", [2, 3]), ("ipad", [2])] {
    for scale in scales {
        let file = "launch-mark-\(idiom)@\(scale)x.png"
        write(renderMark(pixels: 112 * scale, viewOrigin: 120, viewSize: 784, background: nil), to: launch.appendingPathComponent(file))
        images.append(["filename": file, "idiom": idiom, "scale": "\(scale)x"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: launch.appendingPathComponent("Contents.json"))
print("Wrote the app icon and \(images.count) launch marks")
