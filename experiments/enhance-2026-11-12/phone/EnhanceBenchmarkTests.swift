import CoreML
import XCTest

/// Enhance step 1 (2026-11-13): load time, prediction time and memory of the candidate Core ML models on a review
/// iPhone. Not part of the app: copied into the scratch build's LightlyTests only. The compiled models are copied to
/// the host app's Documents/enhance-bench/ with devicectl; the test skips when they are absent.
final class EnhanceBenchmarkTests: XCTestCase {
    private struct Candidate {
        let file: String
        let inputShape: [Int]
    }

    // Step 1d: CodeFormer with the reshape-free GroupNorm (codeformer_gpu.py) against the original.
    private let candidates = [
        Candidate(file: "codeformer-gn-w0.8-512.mlmodelc", inputShape: [1, 3, 512, 512]),
        Candidate(file: "codeformer-w0.8-512.mlmodelc", inputShape: [1, 3, 512, 512]),
    ]

    func testEnhanceCandidates() throws {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("enhance-bench")
        guard FileManager.default.fileExists(atPath: folder.path) else { throw XCTSkip("no models in Documents/enhance-bench") }
        var lines: [String] = []
        // GPU first: the original CodeFormer on .all crashes the 11 Pro Max host, so it runs last.
        for units in [MLComputeUnits.cpuAndGPU, .all] {
            for candidate in candidates {
                let url = folder.appendingPathComponent(candidate.file)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                // Written after every model so a crash still leaves the results measured before it.
                let progress = folder.appendingPathComponent("results.txt")
                try (lines + ["started \(candidate.file) [\(units == .all ? "all" : "cpuAndGPU")]"])
                    .joined(separator: "\n").write(to: progress, atomically: true, encoding: .utf8)
                lines.append(try measure(candidate, at: url, units: units))
                print("ENHANCE-BENCH " + lines.last!)
            }
        }
        let report = lines.joined(separator: "\n")
        print("ENHANCE-BENCH\n" + report)
        try report.write(to: folder.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
    }

    private func measure(_ candidate: Candidate, at url: URL, units: MLComputeUnits) throws -> String {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        let before = footprintMB()
        let loadStart = CFAbsoluteTimeGetCurrent()
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let loadSeconds = CFAbsoluteTimeGetCurrent() - loadStart
        let inputName = model.modelDescription.inputDescriptionsByName.keys.first!
        let array = try MLMultiArray(shape: candidate.inputShape.map(NSNumber.init), dataType: .float32)
        let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
        for index in 0..<array.count { pointer[index] = Float32.random(in: -1...1) }
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
        let firstStart = CFAbsoluteTimeGetCurrent()
        _ = try model.prediction(from: input)
        let firstSeconds = CFAbsoluteTimeGetCurrent() - firstStart
        var times: [Double] = []
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try model.prediction(from: input)
            times.append(CFAbsoluteTimeGetCurrent() - start)
        }
        let peak = footprintMB()
        let unitsName = units == .all ? "all" : "cpuAndGPU"
        return String(format: "%@ [%@] load %.2f s, first %.2f s, median %.3f s, footprint %.0f -> %.0f MB",
                      candidate.file, unitsName, loadSeconds, firstSeconds, times.sorted()[2], before, peak)
    }

    /// Step 1f: photo-or-art classifier (export_art_classifier.py, fp32) on the CPU and on all units. Inputs in
    /// Documents/enhance-bench: art-classifier.mlmodelc and art-views/<name>.u8 (five 224x224 RGB views, uint8 HWC).
    /// Writes art-results.csv (name, cpuOnly score, all-units score, all-units ms) for comparison with reference.csv.
    func testArtClassifier() throws {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("enhance-bench")
        let modelURL = folder.appendingPathComponent("art-classifier.mlmodelc")
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw XCTSkip("no art classifier") }
        let models = try [MLComputeUnits.cpuOnly, .all].map { units -> MLModel in
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: modelURL, configuration: configuration)
        }
        let viewFiles = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("art-views"),
                                                                    includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "u8" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines = ["name,cpu_only,all_units,ms"]
        for file in viewFiles {
            let pixels = try Data(contentsOf: file)
            let array = try MLMultiArray(shape: [5, 3, 224, 224], dataType: .float32)
            let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
            pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for view in 0..<5 { for channel in 0..<3 { for index in 0..<(224 * 224) {
                    pointer[(view * 3 + channel) * 224 * 224 + index] =
                        Float32(raw[(view * 224 * 224 + index) * 3 + channel]) / 255
                } } }
            }
            let input = try MLDictionaryFeatureProvider(dictionary: ["views": MLFeatureValue(multiArray: array)])
            let cpuScore = try models[0].prediction(from: input).featureValue(for: "art_probability")!.multiArrayValue![0]
            let start = CFAbsoluteTimeGetCurrent()
            let allScore = try models[1].prediction(from: input).featureValue(for: "art_probability")!.multiArrayValue![0]
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            lines.append("\(file.deletingPathExtension().lastPathComponent),\(cpuScore),\(allScore),\(String(format: "%.1f", ms))")
        }
        try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("art-results.csv"),
                                                atomically: true, encoding: .utf8)
    }

    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
