import Foundation
import os

/// Timing and resource sampling for the slow paths (encoding, mesh saving, packing, upload).
/// Intervals show up in Instruments (os_signpost) and as `Logger` lines, so release builds on a device
/// can be compared run to run.
public enum Diagnostics {
    public static let subsystem = "app.scan3d"
    private static let signposter = OSSignposter(subsystem: subsystem, category: "scan")
    private static let logger = Logger(subsystem: subsystem, category: "scan")

    /// Runs `body` inside a signpost interval and logs its duration.
    public static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            logger.info("\(String(describing: name), privacy: .public) took \(Self.milliseconds(start.duration(to: .now)), privacy: .public) ms")
        }
        return try body()
    }

    public static func measure<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            logger.info("\(String(describing: name), privacy: .public) took \(Self.milliseconds(start.duration(to: .now)), privacy: .public) ms")
        }
        return try await body()
    }

    private static func milliseconds(_ d: Duration) -> Int {
        Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Thermal state, memory footprint and pending work at one moment.
    public struct Sample: Equatable {
        public var thermal: String
        public var residentMegabytes: Double
        public var pendingWork: Int
        public var frameAge: TimeInterval?
        public var saveFailures: Int
    }

    public static func sample(pendingWork: Int = 0, frameAge: TimeInterval? = nil, saveFailures: Int = 0) -> Sample {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return Sample(thermal: thermal, residentMegabytes: residentMegabytes(), pendingWork: pendingWork,
                      frameAge: frameAge, saveFailures: saveFailures)
    }

    /// Logs a sample. Call at a modest rate (about once a second), not per frame.
    public static func record(_ sample: Sample) {
        logger.info("thermal=\(sample.thermal, privacy: .public) mem=\(sample.residentMegabytes, privacy: .public)MB pending=\(sample.pendingWork) frameAge=\(sample.frameAge ?? -1) saveFailures=\(sample.saveFailures)")
    }

    static func residentMegabytes() -> Double {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
        #else
        return 0
        #endif
    }
}
