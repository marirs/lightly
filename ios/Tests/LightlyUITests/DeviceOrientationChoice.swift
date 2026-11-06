import XCTest

/// LIGHTLY_DEVICE_ORIENTATION=landscape|portrait for the device checks, so the same Ink and Sunglasses/Polaroid runs
/// cover the iPad's approved landscape layout (Lightly 2 mockup, "iPad landscape", 1366 × 1024) as well as the phones.
/// Unset leaves the orientation as it is, which is what the phone runs rely on.
enum DeviceOrientationChoice {
    static func applyFromEnvironment() {
        switch ProcessInfo.processInfo.environment["LIGHTLY_DEVICE_ORIENTATION"] {
        case "landscape": XCUIDevice.shared.orientation = .landscapeLeft
        case "portrait": XCUIDevice.shared.orientation = .portrait
        default: return
        }
        Thread.sleep(forTimeInterval: 2)   // let the layout settle after the rotation
    }
}

/// LIGHTLY_SHOT_DIR (simulator runs only: the test process can write to the Mac's file system): every screenshot and
/// recorded value is also written there as it happens. A simulator check can outlast the 600 s heavy-job bound while the
/// result bundle is still being written, and then the bundle's attachments are lost; these copies survive.
enum SimulatorEvidence {
    private static let directory = ProcessInfo.processInfo.environment["LIGHTLY_SHOT_DIR"].map(URL.init(fileURLWithPath:))

    static func save(_ screenshot: XCUIScreenshot, named name: String) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appending(path: "\(name).png"))
    }

    static func note(_ line: String) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "values.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }
}
