import SwiftUI
import UIKit
import XCTest

/// A minimal, dependency-free snapshot harness.
///
/// Renders a SwiftUI view to a bitmap and compares it against a recorded
/// reference PNG. Written in-repo rather than pulled from a package so the test
/// suite has no external dependency and runs offline.
///
/// References live beside the tests in `__Snapshots__/`. A missing reference is
/// recorded and the test fails once, which is the standard contract: a snapshot
/// that silently creates its own baseline can never fail.
enum SnapshotAssertion {

    /// Devices differ in scale and safe-area insets; snapshots pin an explicit
    /// size so a reference recorded on one machine matches on another.
    static let defaultSize = CGSize(width: 402, height: 874)

    /// Per-pixel channel difference tolerated before a comparison fails.
    ///
    /// Non-zero because SwiftUI materials and text antialiasing are not
    /// bit-identical across runs. Kept tight enough that a real layout or
    /// colour change still fails.
    private static let channelTolerance: Int = 12

    /// Proportion of pixels permitted to exceed `channelTolerance`.
    private static let allowedDifferingFraction: Double = 0.02

    @MainActor
    static func assert(
        of view: some View,
        named name: String,
        size: CGSize = defaultSize,
        colorScheme: ColorScheme = .light,
        record: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let rendered = render(view, size: size, colorScheme: colorScheme) else {
            XCTFail("Could not render snapshot '\(name)'", file: file, line: line)
            return
        }

        let referenceURL = referenceDirectory(for: file)
            .appendingPathComponent("\(name).png")

        guard !record, FileManager.default.fileExists(atPath: referenceURL.path) else {
            write(rendered, to: referenceURL, file: file, line: line)
            XCTFail(
                "Recorded new reference for '\(name)'. Re-run to verify.",
                file: file,
                line: line
            )
            return
        }

        guard let referenceData = try? Data(contentsOf: referenceURL),
              let reference = UIImage(data: referenceData)?.cgImage else {
            XCTFail("Could not read reference for '\(name)'", file: file, line: line)
            return
        }

        let result = compare(rendered, reference)
        if !result.matches {
            // Write the failing render next to the reference so the difference
            // can be inspected rather than guessed at.
            let failureURL = referenceDirectory(for: file)
                .appendingPathComponent("\(name).failed.png")
            write(rendered, to: failureURL, file: file, line: line)

            XCTFail(
                """
                Snapshot '\(name)' does not match. \
                \(String(format: "%.2f", result.differingFraction * 100))% of pixels differ. \
                Failing render written to \(failureURL.lastPathComponent).
                """,
                file: file,
                line: line
            )
        }
    }

    // MARK: - Rendering

    /// Renders through a hosted view in a real window.
    ///
    /// `ImageRenderer` is the obvious tool and the wrong one here: it cannot
    /// materialise `ScrollView`, lazy containers such as `LazyVGrid`, or UIKit-
    /// backed controls such as `Slider`. Those render as blank space, so a
    /// snapshot of a scrolling grid would silently record an empty screen and
    /// then "pass" forever.
    ///
    /// Hosting the view in a key window and drawing the hierarchy exercises the
    /// same layout and rendering path the device uses, so what is captured is
    /// what a user would actually see.
    @MainActor
    private static func render(
        _ view: some View,
        size: CGSize,
        colorScheme: ColorScheme
    ) -> CGImage? {
        let controller = UIHostingController(
            rootView: AnyView(view.environment(\.colorScheme, colorScheme))
        )
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.backgroundColor = .clear

        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        // Applied to the window so UIKit-backed controls (Slider, materials)
        // resolve their own colours to the same scheme as the SwiftUI content.
        window.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        window.makeKeyAndVisible()

        // Force a full layout pass before capture; lazy containers only
        // materialise their content once laid out.
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        // Scale 1 keeps references small and comparison fast; layout bugs are
        // just as visible at 1x.
        format.scale = 1
        format.opaque = true

        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            // An opaque backing colour, so antialiasing against transparency
            // does not vary between runs.
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            controller.view.drawHierarchy(
                in: CGRect(origin: .zero, size: size),
                afterScreenUpdates: true
            )
        }

        window.isHidden = true
        return image.cgImage
    }

    // MARK: - Comparison

    private struct ComparisonResult {
        let matches: Bool
        let differingFraction: Double
    }

    private static func compare(_ lhs: CGImage, _ rhs: CGImage) -> ComparisonResult {
        guard lhs.width == rhs.width, lhs.height == rhs.height else {
            return ComparisonResult(matches: false, differingFraction: 1)
        }

        guard let lhsPixels = pixelData(of: lhs),
              let rhsPixels = pixelData(of: rhs),
              lhsPixels.count == rhsPixels.count else {
            return ComparisonResult(matches: false, differingFraction: 1)
        }

        var differingPixels = 0
        let pixelCount = lhsPixels.count / 4

        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            // Alpha is ignored: the renderer is opaque, so it carries no signal.
            for channel in 0..<3 {
                let delta = abs(Int(lhsPixels[offset + channel]) - Int(rhsPixels[offset + channel]))
                if delta > channelTolerance {
                    differingPixels += 1
                    break
                }
            }
        }

        let fraction = pixelCount == 0 ? 1 : Double(differingPixels) / Double(pixelCount)
        return ComparisonResult(
            matches: fraction <= allowedDifferingFraction,
            differingFraction: fraction
        )
    }

    private static func pixelData(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    // MARK: - Storage

    private static func referenceDirectory(for file: StaticString) -> URL {
        let testFile = URL(fileURLWithPath: "\(file)")
        let directory = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__")

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func write(
        _ image: CGImage,
        to url: URL,
        file: StaticString,
        line: UInt
    ) {
        guard let data = UIImage(cgImage: image).pngData() else {
            XCTFail("Could not encode snapshot PNG", file: file, line: line)
            return
        }
        try? data.write(to: url)
    }
}
