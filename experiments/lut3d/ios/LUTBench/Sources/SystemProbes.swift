import Darwin
import Foundation
import UIKit

// MARK: - Timing

enum Clock {
    /// Monotonic seconds (CLOCK_UPTIME_RAW: not affected by wall-clock changes).
    static func nowSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    @discardableResult
    static func measureMilliseconds<T>(_ body: () throws -> T) rethrows -> (value: T, milliseconds: Double) {
        let start = nowSeconds()
        let value = try body()
        return (value, (nowSeconds() - start) * 1000)
    }
}

enum Statistics {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// "first" = the very first run; "median" = median of the following `repeatCount` runs.
    static func firstAndMedian(firstRunMilliseconds: Double, repeatedMilliseconds: [Double]) -> [String: Any] {
        [
            "first": firstRunMilliseconds,
            "median": median(repeatedMilliseconds).map { $0 as Any } ?? NSNull(),
            "runs": repeatedMilliseconds.count,
        ]
    }
}

// MARK: - Memory

enum MemoryProbe {
    static let bytesPerMegabyte = 1024.0 * 1024.0

    /// Current phys_footprint (the number jetsam compares against the app's limit).
    static func physFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// Lifetime maximum phys_footprint of this process (monotonic; cannot be reset from user space).
    static func lifetimePeakPhysFootprintBytes() -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { usagePointer in
            // proc_pid_rusage is declared in LUTBench-Bridging-Header.h (not exposed by the iOS SDK).
            usagePointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPointer in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, reboundPointer)
            }
        }
        return result == 0 ? usage.ri_lifetime_max_phys_footprint : nil
    }

    static func megabytes(_ bytes: UInt64?) -> Any {
        guard let bytes else { return NSNull() }
        return (Double(bytes) / bytesPerMegabyte * 10).rounded() / 10
    }

    /// Bytes the app can still allocate before hitting its jetsam limit (iOS 13+).
    static func availableBytes() -> UInt64 {
        UInt64(os_proc_available_memory())
    }
}

/// Captures footprint before/after a stage and whether the lifetime peak moved during it.
/// Because the lifetime peak is monotonic, "peak_in_stage_mb" is only known when this stage set a new
/// process-wide peak; otherwise the stage peak was <= the earlier peak and we report null.
/// Stages are ordered small -> large (48 MP last) so most stages do set a new peak.
struct MemoryStageRecorder {
    private let footprintBefore: UInt64?
    private let lifetimePeakBefore: UInt64?

    init() {
        footprintBefore = MemoryProbe.physFootprintBytes()
        lifetimePeakBefore = MemoryProbe.lifetimePeakPhysFootprintBytes()
    }

    func finish() -> [String: Any] {
        let footprintAfter = MemoryProbe.physFootprintBytes()
        let lifetimePeakAfter = MemoryProbe.lifetimePeakPhysFootprintBytes()
        var peakInStage: Any = NSNull()
        if let before = lifetimePeakBefore, let after = lifetimePeakAfter, after > before {
            peakInStage = MemoryProbe.megabytes(after)
        }
        return [
            "before_mb": MemoryProbe.megabytes(footprintBefore),
            "after_mb": MemoryProbe.megabytes(footprintAfter),
            "lifetime_peak_after_mb": MemoryProbe.megabytes(lifetimePeakAfter),
            "peak_in_stage_mb": peakInStage,
        ]
    }
}

// MARK: - Device

enum DeviceProbe {
    static var isSimulator: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] != nil
    }

    /// hw.machine via uname(); on the simulator uname reports the host ("arm64"), so use the simulated model.
    static func modelIdentifier() -> String {
        if let simulatedModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulatedModel
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { rawBuffer in
            String(cString: rawBuffer.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// Small lookup for the devices in this study; unknown identifiers fall back to the identifier itself.
    static func marketingName(for modelIdentifier: String) -> String {
        let knownModels: [String: String] = [
            "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,4": "iPhone Air",
        ]
        let name = knownModels[modelIdentifier] ?? modelIdentifier
        if isSimulator {
            let simulatorName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? name
            return "\(simulatorName) (Simulator)"
        }
        return name
    }

    static func thermalStateName(_ state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    static func operatingSystemDescription() -> String {
        "iOS \(UIDevice.current.systemVersion)"
    }
}
