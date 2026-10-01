import CoreML
import Foundation

/// One Core ML configuration under test: weight precision x compute units, e.g. "fp16_cpuAndNeuralEngine".
struct ModelConfiguration {
    let precisionName: String          // "fp32" | "fp16"
    let computeUnitsName: String       // "cpuOnly" | "cpuAndGPU" | "cpuAndNeuralEngine" | "all"
    let computeUnits: MLComputeUnits

    var key: String { "\(precisionName)_\(computeUnitsName)" }

    static let allComputeUnits: [(name: String, units: MLComputeUnits)] = [
        ("cpuOnly", .cpuOnly),
        ("cpuAndGPU", .cpuAndGPU),
        ("cpuAndNeuralEngine", .cpuAndNeuralEngine),
        ("all", .all),
    ]
}

/// A loaded model plus everything measured while getting it ready.
struct PreparedModel {
    let configuration: ModelConfiguration
    let model: MLModel
    let initRecord: [String: Any]
}

enum ClassifierIO {
    static let inputName = "image"
    static let outputName = "weights"
    static let inputSide = 256
    static let inputElementCount = 3 * 256 * 256

    /// NCHW float32 [1,3,256,256]; values are sRGB-encoded in [0,1] (no mean/std).
    static func makeInputProvider(chwFloats: [Float]) throws -> MLFeatureProvider {
        precondition(chwFloats.count == inputElementCount, "classifier input must be 3x256x256")
        let array = try MLMultiArray(shape: [1, 3, 256, 256], dataType: .float32)
        // A freshly allocated MLMultiArray is contiguous, so a flat copy matches NCHW order.
        chwFloats.withUnsafeBytes { source in
            array.dataPointer.copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        return try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
    }

    static func predictWeights(model: MLModel, input: MLFeatureProvider) throws -> [Float] {
        let output = try model.prediction(from: input)
        guard let weights = output.featureValue(for: outputName)?.multiArrayValue else {
            throw BenchError.message("model output '\(outputName)' missing; outputs: \(output.featureNames)")
        }
        // Read through NSNumber so fp16 and fp32 outputs are handled identically.
        return (0..<weights.count).map { weights[$0].floatValue }
    }
}

enum CoreMLBench {
    static func directorySizeBytes(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            total += (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Compiles the .mlpackage (timed), then for every compute-unit setting loads it once "cold"
    /// (first load of that configuration in this process) and three more times "warm".
    /// Note: the ANE compiler cache (aned) persists across launches and app reinstalls of the same model
    /// hash, so "cold" here means cold for this process, not necessarily a first-ever ANE compile.
    static func prepareModels(precisionName: String, packageURL: URL, log: (String) -> Void) async throws -> [PreparedModel] {
        let compileStart = Clock.nowSeconds()
        let compiledURL = try await MLModel.compileModel(at: packageURL)
        let compileSeconds = Clock.nowSeconds() - compileStart
        log("compiled \(precisionName) in \(String(format: "%.3f", compileSeconds)) s")

        let packageBytes = directorySizeBytes(packageURL)
        let compiledBytes = directorySizeBytes(compiledURL)
        var preparedModels: [PreparedModel] = []

        for (computeUnitsName, computeUnits) in ModelConfiguration.allComputeUnits {
            let configuration = ModelConfiguration(precisionName: precisionName, computeUnitsName: computeUnitsName, computeUnits: computeUnits)
            let mlConfiguration = MLModelConfiguration()
            mlConfiguration.computeUnits = computeUnits

            let (coldModel, coldMilliseconds) = try Clock.measureMilliseconds { try MLModel(contentsOf: compiledURL, configuration: mlConfiguration) }
            var warmLoadMilliseconds: [Double] = []
            var lastModel = coldModel
            for _ in 0..<3 {
                let (model, milliseconds) = try Clock.measureMilliseconds { try MLModel(contentsOf: compiledURL, configuration: mlConfiguration) }
                warmLoadMilliseconds.append(milliseconds)
                lastModel = model
            }

            var record: [String: Any] = [
                "compile_s": compileSeconds,
                "load_cold_s": coldMilliseconds / 1000,
                "load_warm_s": (Statistics.median(warmLoadMilliseconds) ?? .nan) / 1000,
                "bytes": packageBytes,
                "compiled_bytes": compiledBytes,
            ]
            record["compute_plan"] = await computePlanSummary(compiledURL: compiledURL, configuration: mlConfiguration)
            log("loaded \(configuration.key): cold \(String(format: "%.1f", coldMilliseconds)) ms")
            preparedModels.append(PreparedModel(configuration: configuration, model: lastModel, initRecord: record))
        }
        return preparedModels
    }

    /// Per-op preferred device from MLComputePlan (iOS 17.4+). This is what tells us whether the ANE is
    /// actually used for a given compute-unit setting, rather than inferring it from timings.
    static func computePlanSummary(compiledURL: URL, configuration: MLModelConfiguration) async -> Any {
        guard #available(iOS 17.4, *) else { return "unavailable (needs iOS 17.4)" }
        do {
            let plan = try await MLComputePlan.load(contentsOf: compiledURL, configuration: configuration)
            guard case let .program(program) = plan.modelStructure, let mainFunction = program.functions["main"] else {
                return "unsupported model structure"
            }
            var countsByDevice: [String: Int] = [:]
            var operationTypesByDevice: [String: Set<String>] = [:]
            for operation in mainFunction.block.operations {
                guard let usage = plan.deviceUsage(for: operation) else {
                    // const / no-compute ops have no device usage.
                    continue
                }
                let deviceName = describe(usage.preferred)
                countsByDevice[deviceName, default: 0] += 1
                operationTypesByDevice[deviceName, default: []].insert(operation.operatorName)
            }
            return [
                "ops_by_preferred_device": countsByDevice,
                "op_types_by_preferred_device": operationTypesByDevice.mapValues { Array($0).sorted() },
            ]
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    @available(iOS 17.4, *)
    private static func describe(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu: return "cpu"
        case .gpu: return "gpu"
        case .neuralEngine: return "neuralEngine"
        @unknown default: return "unknown"
        }
    }

    /// First inference (includes any lazy per-model setup) and the median of `warmRunCount` subsequent runs.
    static func benchmarkInference(model: MLModel, input: MLFeatureProvider, warmRunCount: Int = 20) throws -> (weights: [Float], firstMilliseconds: Double, medianMilliseconds: Double) {
        let (firstWeights, firstMilliseconds) = try Clock.measureMilliseconds { try ClassifierIO.predictWeights(model: model, input: input) }
        var warmMilliseconds: [Double] = []
        var lastWeights = firstWeights
        for _ in 0..<warmRunCount {
            let (weights, milliseconds) = try Clock.measureMilliseconds { try ClassifierIO.predictWeights(model: model, input: input) }
            warmMilliseconds.append(milliseconds)
            lastWeights = weights
        }
        return (lastWeights, firstMilliseconds, Statistics.median(warmMilliseconds) ?? .nan)
    }
}

enum BenchError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}
