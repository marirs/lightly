// Embedded depth on iOS: read (and, for fixtures, write) disparity/depth + Portrait Effects Matte
// with ImageIO + AVFoundation — exactly the calls the iOS app will make.
//
//   swiftc -O read_depth.swift -o ../cache/read_depth
//   ../cache/read_depth read  photo.heic out_prefix        # -> out_prefix_disparity.f32 (+ .json), _matte.png
//   ../cache/read_depth write src.png disparity.f32 W H out.heic   # build a fixture with a disparity map
//
// Notes for the app (see docs/v1/depth-evaluation.md §E1):
//  * Prefer kCGImageAuxiliaryDataTypeDisparity, fall back to kCGImageAuxiliaryDataTypeDepth; convert
//    either to DisparityFloat32 with AVDepthData.converting(toDepthDataType:) so the renderer always
//    receives disparity (larger = nearer), which is what its circle of confusion is linear in.
//  * Aux images are stored in sensor orientation: apply the primary image's EXIF orientation with
//    applyingExifOrientation(_:) before using them.
//  * depthDataQuality / depthDataAccuracy are reported; relative-accuracy disparity is fine for the
//    renderer because it normalises by percentiles anyway.
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never { FileHandle.standardError.write((message + "\n").data(using: .utf8)!); exit(1) }

func exifOrientation(of source: CGImageSource) -> CGImagePropertyOrientation {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let raw = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
    return CGImagePropertyOrientation(rawValue: raw) ?? .up
}

func readEmbedded(path: String, outputPrefix: String) throws {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { fail("cannot open \(path)") }
    let orientation = exifOrientation(of: source)
    var report: [String: Any] = ["file": path, "exifOrientation": orientation.rawValue]

    var auxiliaryType: CFString? = nil
    var auxiliaryInfo: [AnyHashable: Any]? = nil
    for type in [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth] {
        if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any] {
            auxiliaryType = type; auxiliaryInfo = info; break
        }
    }
    if let info = auxiliaryInfo, let type = auxiliaryType {
        var depthData = try AVDepthData(fromDictionaryRepresentation: info)
        report["storedAs"] = type as String
        report["quality"] = depthData.depthDataQuality == .high ? "high" : "low"
        report["accuracy"] = depthData.depthDataAccuracy == .absolute ? "absolute" : "relative"
        report["filtered"] = depthData.isDepthDataFiltered
        depthData = depthData.applyingExifOrientation(orientation)
        if depthData.depthDataType != kCVPixelFormatType_DisparityFloat32 {
            depthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        }
        let map = depthData.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var values = [Float](repeating: 0, count: width * height)
        let base = CVPixelBufferGetBaseAddress(map)!
        for row in 0..<height {
            let pointer = base.advanced(by: row * rowBytes).assumingMemoryBound(to: Float.self)
            for column in 0..<width { values[row * width + column] = pointer[column] }
        }
        CVPixelBufferUnlockBaseAddress(map, .readOnly)
        let finite = values.filter { $0.isFinite }
        report["width"] = width; report["height"] = height
        report["disparityMin"] = finite.min() ?? 0; report["disparityMax"] = finite.max() ?? 0
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: URL(fileURLWithPath: outputPrefix + "_disparity.f32"))
    } else {
        report["storedAs"] = "none"
    }

    if let matteInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypePortraitEffectsMatte) as? [AnyHashable: Any] {
        let matte = try AVPortraitEffectsMatte(fromDictionaryRepresentation: matteInfo).applyingExifOrientation(orientation)
        let image = CIImage(cvPixelBuffer: matte.mattingImage)
        try CIContext().writePNGRepresentation(of: image, to: URL(fileURLWithPath: outputPrefix + "_matte.png"),
                                               format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)!)
        report["portraitEffectsMatte"] = [CVPixelBufferGetWidth(matte.mattingImage), CVPixelBufferGetHeight(matte.mattingImage)]
    }
    let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: URL(fileURLWithPath: outputPrefix + ".json"))
    print(String(data: json, encoding: .utf8)!)
}

/// Writes a HEIC whose disparity auxiliary image is `disparity` (Float32, row-major, larger = nearer).
/// Used only to build test fixtures; the app never writes depth.
func writeFixture(imagePath: String, disparityPath: String, width: Int, height: Int, outputPath: String) throws {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot open \(imagePath)") }
    let raw = try Data(contentsOf: URL(fileURLWithPath: disparityPath))
    // Store as DisparityFloat16, as iPhone Portrait mode does.
    var halfValues = [UInt16](repeating: 0, count: width * height)
    raw.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        let floats = buffer.bindMemory(to: Float.self)
        for i in 0..<(width * height) { halfValues[i] = Float16(floats[i]).bitPattern }
    }
    let payload = halfValues.withUnsafeBufferPointer { Data(buffer: $0) }
    let description: [CFString: Any] = [
        kCGImagePropertyWidth: width, kCGImagePropertyHeight: height,
        kCGImagePropertyBytesPerRow: width * 2,
        kCGImagePropertyPixelFormat: kCVPixelFormatType_DisparityFloat16,
    ]
    let metadata = CGImageMetadataCreateMutable()
    let info: [CFString: Any] = [
        kCGImageAuxiliaryDataInfoData: payload,
        kCGImageAuxiliaryDataInfoDataDescription: description,
        kCGImageAuxiliaryDataInfoMetadata: metadata,
    ]
    // Round-trip through AVDepthData so the stored dictionary is exactly what AVFoundation expects.
    let depthData = try AVDepthData(fromDictionaryRepresentation: info)
    var auxiliaryType: NSString?
    guard let representation = depthData.dictionaryRepresentation(forAuxiliaryDataType: &auxiliaryType),
          let type = auxiliaryType else { fail("no dictionary representation") }
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL,
                                                            UTType.heic.identifier as CFString, 1, nil) else { fail("no HEIC encoder") }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationAddAuxiliaryDataInfo(destination, type as CFString, representation as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fail("finalize failed") }
    print("wrote \(outputPath) with \(type) \(width)x\(height)")
}

let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "" {
case "read": try readEmbedded(path: arguments[2], outputPrefix: arguments[3])
case "write": try writeFixture(imagePath: arguments[2], disparityPath: arguments[3], width: Int(arguments[4])!,
                               height: Int(arguments[5])!, outputPath: arguments[6])
default: fail("usage: read <photo> <out_prefix> | write <image> <disparity.f32> <w> <h> <out.heic>")
}
