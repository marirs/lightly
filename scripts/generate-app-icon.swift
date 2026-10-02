import AppKit

// Reproduce DesignSystem/Components/BrandMark.swift on an opaque background.
// Run from the repository root: swift scripts/generate-app-icon.swift
// Keep the square canvas: the operating system supplies its own icon mask.
let size = 1024
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: srgb,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(colorSpace: srgb, components: [0.045, 0.045, 0.045, 1])!)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.setStrokeColor(CGColor(colorSpace: srgb, components: [0.98, 0.98, 0.97, 1])!)
let markSize = 640.0
let radius = markSize / 2
context.setLineWidth(markSize * 0.035)
context.setLineCap(.round)
for index in 0..<8 {
    let angle = Double(index) * .pi / 4
    let outer = index.isMultiple(of: 2) ? radius : radius * 0.86
    context.move(to: CGPoint(x: 512 + cos(angle) * radius * 0.30,
                            y: 512 + sin(angle) * radius * 0.30))
    context.addLine(to: CGPoint(x: 512 + cos(angle) * outer,
                               y: 512 + sin(angle) * outer))
}
context.strokePath()

let output = URL(fileURLWithPath: "Lightly/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
