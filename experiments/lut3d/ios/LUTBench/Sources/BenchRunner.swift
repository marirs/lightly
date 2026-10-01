import CoreGraphics
import CoreML
import Foundation
import UIKit

/// Runs every stage in a fixed order (smallest memory first, 48 MP last) and writes
/// Documents/results/{results.json, <stem>_ios.png, log.txt, done}.
/// Keys of results.json are shared with the Android harness; extra keys are additive only.
final class BenchRunner {
    private let runIdentifier: String
    private let reportStatus: (String) -> Void
    private let fileManager = FileManager.default
    private var results: [String: Any] = ["platform": "ios"]
    private var imageRecords: [[String: Any]] = []
    private var perStageMemory: [String: Any] = [:]
    private var errors: [String] = []
    private var logHandle: FileHandle?

    private lazy var documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private lazy var resultsURL = documentsURL.appendingPathComponent("results", isDirectory: true)
    private lazy var benchDataURL = Bundle.main.url(forResource: "BenchData", withExtension: nil)!

    init(runIdentifier: String, reportStatus: @escaping (String) -> Void) {
        self.runIdentifier = runIdentifier
        self.reportStatus = reportStatus
    }

    // MARK: Entry point

    func run() async {
        prepareResultsDirectory()
        log("run \(runIdentifier) started")
        do {
            try await runAllStages()
        } catch {
            errors.append("fatal: \(error)")
            log("FATAL: \(error)")
        }
        results["errors"] = errors
        writeResultsJSON()
        let status = errors.isEmpty ? "ok" : "completed_with_errors"
        try? "\(runIdentifier)\n\(status)\n".write(to: resultsURL.appendingPathComponent("done"), atomically: true, encoding: .utf8)
        log("done (\(status))")
        reportStatus("done (\(status)) - \(imageRecords.count) images")
    }

    private func runAllStages() async throws {
        let device = await captureDeviceInfo()
        results["device"] = device
        results["run_id"] = runIdentifier
        results["notes"] = Self.methodNotes

        let basisLUTs = try ArrayComparison.readFloat32File(benchDataURL.appendingPathComponent("models/ia3dlut_basis_luts_f32.bin"))
        guard basisLUTs.count == 3 * LUTFusion.floatsPerLUT else { throw BenchError.message("basis LUT size \(basisLUTs.count)") }

        // Stage 1: model init (all 8 configurations).
        let modelInitMemory = MemoryStageRecorder()
        var preparedModels: [PreparedModel] = []
        var modelRecords: [String: Any] = [:]
        for precisionName in ["fp32", "fp16"] {
            let packageURL = benchDataURL.appendingPathComponent("models/ia3dlut_classifier_\(precisionName).mlpackage")
            let models = try await CoreMLBench.prepareModels(precisionName: precisionName, packageURL: packageURL, log: log)
            for prepared in models {
                var record = prepared.initRecord
                record["first_load_in_process"] = preparedModels.isEmpty
                modelRecords[prepared.configuration.key] = record
                preparedModels.append(prepared)
            }
        }
        results["model"] = modelRecords
        perStageMemory["model_init"] = modelInitMemory.finish()

        let applier = try CoreImageLUTApplier()
        let stems = try goldenStems()
        log("golden stems (\(stems.count)): \(stems.joined(separator: ", "))")

        // Stage 2: per-image parity and timing.
        let imagesMemory = MemoryStageRecorder()
        var chosenMethodVotes: [LUTApplicationMethod: Int] = [:]
        for (index, stem) in stems.enumerated() {
            reportStatus("image \(index + 1)/\(stems.count): \(stem)")
            var record: [String: Any] = ["stem": stem]
            do {
                try autoreleasepool {
                    record = try benchmarkImage(stem: stem, models: preparedModels, basisLUTs: basisLUTs, applier: applier)
                }
                if let methodName = (record["apply"] as? [String: Any])?["method"] as? String,
                   let method = LUTApplicationMethod(rawValue: methodName) {
                    chosenMethodVotes[method, default: 0] += 1
                }
            } catch {
                record["error"] = "\(error)"
                errors.append("\(stem): \(error)")
                log("ERROR \(stem): \(error)")
            }
            imageRecords.append(record)
            results["images"] = imageRecords
            writeResultsJSON()  // partial results survive a crash/jetsam later in the run
        }
        perStageMemory["images_all"] = imagesMemory.finish()

        // Stage 3: synthetic 12 MP / 48 MP (48 MP last because it sets the memory peak).
        let synthesisMethod = chosenMethodVotes.max { $0.value < $1.value }?.key ?? .cubeWithColorSpace_linearWorking
        let synthesisStem = stems.contains("a1629") ? "a1629" : stems[0]
        results["synthetic"] = try benchmarkSynthetic(stem: synthesisStem, method: synthesisMethod, applier: applier)

        results["device"] = device.merging(["thermal_end": DeviceProbe.thermalStateName()]) { _, new in new }
        results["memory"] = [
            "peak_phys_footprint_mb": MemoryProbe.megabytes(MemoryProbe.lifetimePeakPhysFootprintBytes()),
            "per_stage_mb": perStageMemory,
        ] as [String: Any]
    }

    // MARK: Per image

    private func benchmarkImage(stem: String, models: [PreparedModel], basisLUTs: [Float], applier: CoreImageLUTApplier) throws -> [String: Any] {
        let directory = goldenRootURL.appendingPathComponent(stem, isDirectory: true)
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("meta.json"))) as! [String: Any]
        let goldenWeights = (meta["weights_deploy"] as! [NSNumber]).map { $0.floatValue }
        let goldenInput256 = try ArrayComparison.readFloat32File(directory.appendingPathComponent("input256.f32"))
        let goldenFusedLUT = try ArrayComparison.readFloat32File(directory.appendingPathComponent("fused_lut.f32"))
        var record: [String: Any] = [
            "stem": stem,
            "width": meta["width"] ?? NSNull(),
            "height": meta["height"] ?? NSNull(),
            "thermal_at_start": DeviceProbe.thermalStateName(),
        ]
        var imageMemory: [String: Any] = [:]

        // Model parity on the golden 256x256 tensor, every configuration.
        var memory = MemoryStageRecorder()
        let goldenInputProvider = try ClassifierIO.makeInputProvider(chwFloats: goldenInput256)
        var inferenceRecords: [String: Any] = [:]
        for prepared in models {
            let result = try CoreMLBench.benchmarkInference(model: prepared.model, input: goldenInputProvider)
            inferenceRecords[prepared.configuration.key] = [
                "first_ms": result.firstMilliseconds,
                "median_ms": result.medianMilliseconds,
                "weights": result.weights,
                "max_abs_diff_vs_golden": ArrayComparison.maxAbsDifference(result.weights, goldenWeights),
            ] as [String: Any]
        }
        record["inference"] = inferenceRecords
        imageMemory["inference"] = memory.finish()

        // On-device preprocessing: ImageIO decode -> vImage resize -> tensor -> fp32 CPU model.
        memory = MemoryStageRecorder()
        let parityModel = models.first { $0.configuration.key == "fp32_cpuOnly" }!.model
        let (sourcePixels, decodeMilliseconds) = try Clock.measureMilliseconds { try ImageDecoding.decodeRGBX8(at: directory.appendingPathComponent("source.png")) }
        let (resizedPixels, resizeMilliseconds) = try Clock.measureMilliseconds { try ClassifierPreprocessing.resizeWithVImage(sourcePixels) }
        let (vImageTensor, tensorMilliseconds) = Clock.measureMilliseconds { ClassifierPreprocessing.chwTensor(from: resizedPixels) }
        let vImageWeights = try ClassifierIO.predictWeights(model: parityModel, input: ClassifierIO.makeInputProvider(chwFloats: vImageTensor))
        let (torchPortTensor, torchPortMilliseconds) = Clock.measureMilliseconds { ClassifierPreprocessing.torchAntialiasedBilinear(sourcePixels) }
        let torchPortWeights = try ClassifierIO.predictWeights(model: parityModel, input: ClassifierIO.makeInputProvider(chwFloats: torchPortTensor))
        record["preprocess"] = [
            "method": ClassifierPreprocessing.vImageMethodDescription,
            "inference_config": "fp32_cpuOnly",
            "decode_ms": decodeMilliseconds,
            "resize_ms": resizeMilliseconds,
            "tensor_ms": tensorMilliseconds,
            "weights": vImageWeights,
            "max_abs_diff_vs_golden": ArrayComparison.maxAbsDifference(vImageWeights, goldenWeights),
            "input_max_abs_diff_vs_golden_input256": ArrayComparison.maxAbsDifference(vImageTensor, goldenInput256),
            "input_mean_abs_diff_vs_golden_input256": ArrayComparison.meanAbsDifference(vImageTensor, goldenInput256),
            "torch_aa_bilinear_port": [
                "ms": torchPortMilliseconds,
                "weights": torchPortWeights,
                "max_abs_diff_vs_golden": ArrayComparison.maxAbsDifference(torchPortWeights, goldenWeights),
                "input_max_abs_diff_vs_golden_input256": ArrayComparison.maxAbsDifference(torchPortTensor, goldenInput256),
            ] as [String: Any],
        ] as [String: Any]
        imageMemory["preprocess"] = memory.finish()

        // Fuse with the golden deployment weights so this stage is isolated from model error.
        memory = MemoryStageRecorder()
        let (fusedLUT, fuseFirstMilliseconds) = Clock.measureMilliseconds { LUTFusion.fuse(basisLUTs: basisLUTs, weights: goldenWeights) }
        var fuseRepeats: [Double] = []
        for _ in 0..<10 {
            fuseRepeats.append(Clock.measureMilliseconds { LUTFusion.fuse(basisLUTs: basisLUTs, weights: goldenWeights) }.milliseconds)
        }
        record["fuse"] = [
            "ms": Statistics.median(fuseRepeats).map { $0 as Any } ?? NSNull(),
            "first_ms": fuseFirstMilliseconds,
            "weights_source": "meta.weights_deploy",
            "max_abs_diff_vs_golden": ArrayComparison.maxAbsDifference(fusedLUT, goldenFusedLUT),
        ] as [String: Any]
        imageMemory["fuse"] = memory.finish()

        // LUT application (uses golden fused_lut.f32 so it is isolated from fuse/model error).
        memory = MemoryStageRecorder()
        record["apply"] = try benchmarkApply(stem: stem, directory: directory, sourcePixels: sourcePixels,
                                             fusedLUT: goldenFusedLUT, applier: applier)
        imageMemory["apply"] = memory.finish()

        record["jpeg_decode"] = benchmarkOriginalJPEGDecode(stem: stem)
        record["memory_mb"] = imageMemory
        record["thermal_at_end"] = DeviceProbe.thermalStateName()
        log("\(stem): ok")
        return record
    }

    private func benchmarkApply(stem: String, directory: URL, sourcePixels: RGBX8Image, fusedLUT: [Float], applier: CoreImageLUTApplier) throws -> [String: Any] {
        let lutData = fusedLUT.withUnsafeBufferPointer { Data(buffer: $0) }
        let sourceImage = ImageEncoding.cgImage(from: sourcePixels)
        let reference = try ImageDecoding.decodeRGBX8(at: directory.appendingPathComponent("reference.png"))
        let output = RGBX8Image.allocate(width: sourceImage.width, height: sourceImage.height)

        var comparisons: [String: Any] = [:]
        var bestMethod: LUTApplicationMethod?
        var bestScore = (mean: Double.infinity, max: Int.max)
        for method in LUTApplicationMethod.allCases {
            applier.applyAndRender(source: sourceImage, fusedLUT: lutData, method: method, into: output)
            let comparison = try PixelComparison.compare(output, reference)
            comparisons[method.rawValue] = comparison
            let score = (mean: comparison["mean_abs_diff"] as! Double, max: comparison["max_abs_diff"] as! Int)
            if !method.isDiagnosticOnly && (score.mean < bestScore.mean || (score.mean == bestScore.mean && score.max < bestScore.max)) {
                bestScore = score
                bestMethod = method
            }
        }
        let method = bestMethod!

        // Re-render with the chosen method and keep it as the output PNG.
        applier.applyAndRender(source: sourceImage, fusedLUT: lutData, method: method, into: output)
        try ImageEncoding.writePNG(ImageEncoding.cgImage(from: output), to: resultsURL.appendingPathComponent("\(stem)_ios.png"))

        let fullTiming = applier.timeApply(source: sourceImage, fusedLUT: lutData, method: method)
        let previewScale = 2048.0 / Double(max(sourceImage.width, sourceImage.height))
        let previewImage = try applier.resampled(sourceImage,
                                                 width: Int((Double(sourceImage.width) * previewScale).rounded()),
                                                 height: Int((Double(sourceImage.height) * previewScale).rounded()))
        let previewTiming = applier.timeApply(source: previewImage, fusedLUT: lutData, method: method)

        // Diagnostic (untimed): is the residual vs reference.png explained by Core Image using a
        // different interpolation? Compare the CI output against CPU trilinear and tetrahedral.
        let cpuTrilinear = CPULUTReference.apply(lut: fusedLUT, source: sourcePixels, interpolation: .trilinear)
        let cpuTetrahedral = CPULUTReference.apply(lut: fusedLUT, source: sourcePixels, interpolation: .tetrahedral)
        let interpolationDiagnostics: [String: Any] = [
            "cpu_trilinear_vs_reference": try PixelComparison.compare(cpuTrilinear, reference),
            "cpu_tetrahedral_vs_reference": try PixelComparison.compare(cpuTetrahedral, reference),
            "coreimage_vs_cpu_trilinear": try PixelComparison.compare(output, cpuTrilinear),
            "coreimage_vs_cpu_tetrahedral": try PixelComparison.compare(output, cpuTetrahedral),
            "coreimage_vs_cpu_trilinear_clamped_nodes": try PixelComparison.compare(
                output, CPULUTReference.apply(lut: fusedLUT, source: sourcePixels, interpolation: .trilinear, nodes: .clampedToUnit)),
            "coreimage_vs_cpu_trilinear_clamped_8bit_nodes": try PixelComparison.compare(
                output, CPULUTReference.apply(lut: fusedLUT, source: sourcePixels, interpolation: .trilinear, nodes: .clampedAndQuantised8Bit)),
        ]

        var chosen = comparisons[method.rawValue] as! [String: Any]
        chosen["interpolation_diagnostics"] = interpolationDiagnostics
        chosen["method"] = method.rawValue
        chosen["preview_ms"] = previewTiming
        chosen["full_ms"] = fullTiming
        chosen["methods_compared"] = comparisons
        return chosen
    }

    /// Decode timing of the original camera JPEG (if photos/<stem>.jpg exists): full decode and a
    /// 2048 px ImageIO thumbnail decode (what a preview path would use). Not used for parity.
    private func benchmarkOriginalJPEGDecode(stem: String) -> Any {
        let jpegURL = inputRootURL.appendingPathComponent("photos/\(stem).jpg")
        guard fileManager.fileExists(atPath: jpegURL.path) else { return NSNull() }
        do {
            let (fullImage, fullMilliseconds) = try Clock.measureMilliseconds { try ImageDecoding.decodeCGImage(at: jpegURL) }
            let (_, thumbnailMilliseconds) = try Clock.measureMilliseconds { try ImageDecoding.decodeThumbnail(at: jpegURL, maxPixelSize: 2048) }
            return ["full_ms": fullMilliseconds, "thumbnail2048_ms": thumbnailMilliseconds,
                    "width": fullImage.width, "height": fullImage.height] as [String: Any]
        } catch {
            return "error: \(error)"
        }
    }

    // MARK: Synthetic large frames

    private func benchmarkSynthetic(stem: String, method: LUTApplicationMethod, applier: CoreImageLUTApplier) throws -> [String: Any] {
        let directory = goldenRootURL.appendingPathComponent(stem, isDirectory: true)
        let lutData = try Data(contentsOf: directory.appendingPathComponent("fused_lut.f32"))
        let source = try ImageDecoding.decodeCGImage(at: directory.appendingPathComponent("source.png"))
        var record: [String: Any] = ["source_stem": stem, "method": method.rawValue]

        reportStatus("synthetic 12 MP")
        try autoreleasepool {
            var memory = MemoryStageRecorder()
            let twelveMegapixel = try applier.resampled(source, width: 4032, height: 3024)
            record["12mp_apply_ms"] = applier.timeApply(source: twelveMegapixel, fusedLUT: lutData, method: method)
            perStageMemory["synthetic_12mp_apply"] = memory.finish()

            memory = MemoryStageRecorder()
            let output = RGBX8Image.allocate(width: 4032, height: 3024)
            applier.applyAndRender(source: twelveMegapixel, fusedLUT: lutData, method: method, into: output)
            let outputImage = ImageEncoding.cgImage(from: output)
            let (jpegBytes, jpegMilliseconds) = try ImageEncoding.timeJPEGEncode(outputImage)
            record["12mp_jpeg_encode_ms"] = jpegMilliseconds
            record["12mp_jpeg_bytes"] = jpegBytes
            perStageMemory["jpeg_encode_12mp"] = memory.finish()
        }
        log("12 MP done")

        reportStatus("synthetic 48 MP")
        try autoreleasepool {
            let memory = MemoryStageRecorder()
            let fortyEightMegapixel = try applier.resampled(source, width: 8064, height: 6048)
            record["48mp_apply_ms"] = applier.timeApply(source: fortyEightMegapixel, fusedLUT: lutData, method: method)
            perStageMemory["synthetic_48mp_apply"] = memory.finish()
        }
        log("48 MP done")
        return record
    }

    // MARK: Inputs

    /// Golden data is copied into the app container by run_ios.sh (Documents/BenchInput); a bundled
    /// BenchData/golden is used only as a fallback for manual runs.
    private var inputRootURL: URL {
        let containerInput = documentsURL.appendingPathComponent("BenchInput", isDirectory: true)
        if fileManager.fileExists(atPath: containerInput.appendingPathComponent("golden").path) { return containerInput }
        return benchDataURL
    }

    private var goldenRootURL: URL { inputRootURL.appendingPathComponent("golden", isDirectory: true) }

    private func goldenStems() throws -> [String] {
        let entries = try fileManager.contentsOfDirectory(atPath: goldenRootURL.path)
        let stems = entries.filter { entry in
            fileManager.fileExists(atPath: goldenRootURL.appendingPathComponent("\(entry)/meta.json").path)
        }.sorted()
        guard !stems.isEmpty else { throw BenchError.message("no golden dirs under \(goldenRootURL.path)") }
        return stems
    }

    // MARK: Device + output

    private func captureDeviceInfo() async -> [String: Any] {
        let operatingSystem = await MainActor.run { DeviceProbe.operatingSystemDescription() }
        let modelIdentifier = DeviceProbe.modelIdentifier()
        return [
            "model_id": modelIdentifier,
            "marketing_name": DeviceProbe.marketingName(for: modelIdentifier),
            "os": operatingSystem,
            "os_version_string": ProcessInfo.processInfo.operatingSystemVersionString,
            "is_simulator": DeviceProbe.isSimulator,
            "thermal_start": DeviceProbe.thermalStateName(),
            "thermal_end": NSNull(),
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "physical_memory_mb": Double(ProcessInfo.processInfo.physicalMemory) / MemoryProbe.bytesPerMegabyte,
            "available_memory_at_start_mb": Double(MemoryProbe.availableBytes()) / MemoryProbe.bytesPerMegabyte,
            "processor_count": ProcessInfo.processInfo.activeProcessorCount,
        ]
    }

    private static let methodNotes: [String: String] = [
        "timing": "first = first run; median = median of the following N runs (N=20 inference, 10 apply/fuse). Apply timing = CIImage+filter construction + CIContext.render(toBitmap:) RGBA8 sRGB, which blocks until GPU completion.",
        "model_load": "compile_s = MLModel.compileModel(at:) of the .mlpackage (once per precision); load_cold_s = first MLModel(contentsOf:configuration:) for that compute-unit setting in this process; load_warm_s = median of 3 further loads. ANE compile cache persists across launches, so cold is per-process only.",
        "preprocess": "decode_ms = ImageIO decode of source.png into RGBX8 sRGB vImage buffer; resize_ms = vImageScale_ARGB8888 to 256x256 (Lanczos3, default flags). torch_aa_bilinear_port = exact CPU port of the golden torch antialias bilinear resize, for attribution.",
        "fuse": "vDSP weighted sum of the 3 basis LUTs with meta.weights_deploy, alpha reset to 1.",
        "apply": "Uses golden fused_lut.f32. Chosen method = lowest mean abs diff vs reference.png among non-diagnostic variants; all variants in methods_compared.",
        "memory": "phys_footprint via task_info(TASK_VM_INFO); lifetime peak via proc_pid_rusage(RUSAGE_INFO_V4).ri_lifetime_max_phys_footprint. peak_in_stage_mb is only set when that stage raised the process lifetime peak.",
    ]

    private func prepareResultsDirectory() {
        try? fileManager.removeItem(at: resultsURL)
        try? fileManager.createDirectory(at: resultsURL, withIntermediateDirectories: true)
        let logURL = resultsURL.appendingPathComponent("log.txt")
        fileManager.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)
    }

    private func log(_ message: String) {
        let line = String(format: "[%9.3f] ", Clock.nowSeconds()) + message
        print(line)
        logHandle?.write((line + "\n").data(using: .utf8)!)
        reportStatus(message)
    }

    private func writeResultsJSON() {
        var snapshot = results
        snapshot["images"] = imageRecords
        snapshot["errors"] = errors
        do {
            let data = try JSONSerialization.data(withJSONObject: JSONSanitizer.sanitize(snapshot), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: resultsURL.appendingPathComponent("results.json"), options: .atomic)
        } catch {
            log("could not write results.json: \(error)")
        }
    }
}

/// JSONSerialization rejects NaN/Inf and non-property-list values; normalise everything first.
enum JSONSanitizer {
    static func sanitize(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues { sanitize($0) }
        case let array as [Any]:
            return array.map { sanitize($0) }
        case let floatValue as Float:
            return floatValue.isFinite ? Double(floatValue) : NSNull()
        case let doubleValue as Double:
            return doubleValue.isFinite ? doubleValue : NSNull()
        case is String, is Int, is Bool, is NSNull, is NSNumber:
            return value
        case Optional<Any>.none:
            return NSNull()
        default:
            return "\(value)"
        }
    }
}
