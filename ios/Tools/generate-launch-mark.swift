#!/usr/bin/env swift
// Writes the launch-screen mark (LaunchMark.imageset) for the approved Launch screen: the eight-ray
// mark alone, 64 pt, centred, in --ink on --bg (docs/ui/app/app.js launchHTML, mark(64)).
//
// The system launch screen (UILaunchScreen) can only show a named image on a named colour, so the
// mark is rasterised here with the same geometry as BrandMark.swift / the prototype's mark():
// eight rays from 30% of the radius, diagonals at 86%, round caps, stroke max(1.6, size × 0.035).
//
//   swift ios/Tools/generate-launch-mark.swift ios/Lightly/Resources/Assets.xcassets/LaunchMark.imageset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let pointSize: CGFloat = 64
// The prototype centres the mark in the area below the status bar (launchHTML: status bar, then a
// centred box), i.e. half the top safe area below the screen centre. A launch image is always
// centred on the screen, so the mark is drawn that far below the centre of a taller transparent
// image: 62 pt top safe area on iPhone (31 pt), 24 pt on iPad (12 pt).
let downwardOffsets: [(idiom: String, points: CGFloat)] = [("iphone", 31), ("ipad", 12)]
let inks: [(name: String, rgb: (CGFloat, CGFloat, CGFloat))] = [
    ("light", (0x12 / 255.0, 0x12 / 255.0, 0x14 / 255.0)),  // --ink light #121214
    ("dark", (0xF2 / 255.0, 0xF2 / 255.0, 0xF4 / 255.0))    // --ink dark #F2F2F4
]

func writeMark(scale: Int, offset: CGFloat, ink: (CGFloat, CGFloat, CGFloat), to url: URL) {
    let width = Int(pointSize) * scale
    let height = Int(pointSize + 2 * offset) * scale
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    // Core Graphics' origin is bottom-left: a centre at pointSize / 2 is the bottom of the image.
    let centre = CGPoint(x: pointSize / 2, y: pointSize / 2), radius = pointSize / 2, inner = radius * 0.3
    for index in 0..<8 {
        let angle = CGFloat(index) * .pi / 4
        let outer = index % 2 == 1 ? radius * 0.86 : radius
        context.move(to: CGPoint(x: centre.x + cos(angle) * inner, y: centre.y + sin(angle) * inner))
        context.addLine(to: CGPoint(x: centre.x + cos(angle) * outer, y: centre.y + sin(angle) * outer))
    }
    context.setStrokeColor(CGColor(colorSpace: space, components: [ink.0, ink.1, ink.2, 1])!)
    context.setLineWidth(max(1.6, pointSize * 0.035))
    context.setLineCap(.round)
    context.strokePath()
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
var images: [[String: Any]] = []
for (idiom, offset) in downwardOffsets {
    for (name, rgb) in inks {
        // iPhones are @2x/@3x, iPads @2x.
        for scale in idiom == "ipad" ? [2] : [2, 3] {
            let file = "launch-mark-\(idiom)-\(name)@\(scale)x.png"
            writeMark(scale: scale, offset: offset, ink: rgb, to: outputDirectory.appendingPathComponent(file))
            var entry: [String: Any] = ["filename": file, "idiom": idiom, "scale": "\(scale)x"]
            if name == "dark" { entry["appearances"] = [["appearance": "luminosity", "value": "dark"]] }
            images.append(entry)
        }
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) images to \(outputDirectory.path)")
