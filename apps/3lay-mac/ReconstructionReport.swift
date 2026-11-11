import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What one Mac reconstruction did, written next to the model as `<name>.report.json`, so quality and cost
/// can be compared run to run (and Full against Raw) instead of judged by eye.
struct ReconstructionReport: Codable, Equatable {
    var createdAt: Date
    /// The level asked for first ("Full", or "Raw" when maximum detail is on) and the level that produced the model.
    var requestedDetail: String
    var actualDetail: String
    /// Why the actual level is lower than requested, if it is.
    var fallbackReason: String?
    var photosTotal: Int
    var photosUsed: Int
    var photosSetAsideBlurry: Int
    var photosWithDepth: Int
    var durationSeconds: Double
    /// Highest resident memory of this process while reconstructing, in megabytes (sampled; see `PeakMemorySampler`).
    var peakResidentMegabytes: Double
    var outputBytes: Int?
    var triangleCount: Int?
    var vertexCount: Int?
    /// Extents along the model's principal axes in millimeters, largest first. See `OrientedExtents`.
    var extentsMillimeters: [Double]?

    var detailWasReduced: Bool { requestedDetail != actualDetail }

    func write(next model: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = model.deletingPathExtension().appendingPathExtension("report.json")
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Samples this process's resident memory while a reconstruction runs. The maximum of the samples is a
/// lower bound of the true peak, but it is the number that decides whether a Mac with less memory copes.
final class PeakMemorySampler {
    private let lock = NSLock()
    private var peak = 0.0
    private var task: Task<Void, Never>?

    func start(every seconds: Double = 0.5) {
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                self?.record(Self.residentMegabytes())
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    /// Stops sampling and returns the highest value seen.
    func stop() -> Double {
        task?.cancel()
        record(Self.residentMegabytes())
        return lock.withLock { peak }
    }

    private func record(_ value: Double) { lock.withLock { peak = max(peak, value) } }

    static func residentMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}

/// Size of a model measured along its own principal axes (PCA), largest first.
///
/// The axis-aligned `Mesh.bounds` depends on how the object happens to be rotated: a 100 mm bar turned 45
/// degrees reads about 70 mm per side. Comparing a scan to a ruler measurement needs extents that do not depend
/// on orientation. PCA axes are not the true minimum box for every shape (a round or symmetric object has no
/// preferred axis), so use it for boxy or elongated reference objects and say so in the benchmark notes.
enum OrientedExtents {
    static func measure(_ vertices: [SIMD3<Float>], maxSamples: Int = 200_000) -> [Double] {
        guard vertices.count >= 3 else { return [0, 0, 0] }
        let step = max(1, vertices.count / maxSamples)
        let points = stride(from: 0, to: vertices.count, by: step).map { SIMD3<Double>(vertices[$0]) }
        let mean = points.reduce(SIMD3<Double>.zero, +) / Double(points.count)
        var covariance = [[Double]](repeating: [0, 0, 0], count: 3)
        for p in points {
            let d = p - mean
            for i in 0..<3 { for j in 0..<3 { covariance[i][j] += d[i] * d[j] } }
        }
        let axes = jacobiEigenvectors(covariance)
        var low = [Double](repeating: .infinity, count: 3), high = [Double](repeating: -.infinity, count: 3)
        for p in points {
            let d = p - mean
            for a in 0..<3 {
                let value = d.x * axes[a].x + d.y * axes[a].y + d.z * axes[a].z
                low[a] = min(low[a], value)
                high[a] = max(high[a], value)
            }
        }
        return (0..<3).map { high[$0] - low[$0] }.sorted(by: >)
    }

    /// Eigenvectors of a symmetric 3x3 matrix by cyclic Jacobi rotations.
    static func jacobiEigenvectors(_ matrix: [[Double]]) -> [SIMD3<Double>] {
        var a = matrix
        var v = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
        for _ in 0..<50 {
            var off = 0.0
            for i in 0..<3 { for j in (i + 1)..<3 where j < 3 { off += a[i][j] * a[i][j] } }
            if off < 1e-18 { break }
            for p in 0..<2 {
                for q in (p + 1)..<3 {
                    guard abs(a[p][q]) > 1e-300 else { continue }
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for k in 0..<3 {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<3 {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<3 {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
        return (0..<3).map { SIMD3(v[0][$0], v[1][$0], v[2][$0]) }
    }
}

/// Compares measured extents with an independent reference (calipers, a ruler, a CAD model).
enum DimensionalError {
    struct Axis: Codable, Equatable {
        var referenceMillimeters: Double
        var measuredMillimeters: Double
        var errorMillimeters: Double { measuredMillimeters - referenceMillimeters }
        var errorPercent: Double { referenceMillimeters == 0 ? 0 : errorMillimeters / referenceMillimeters * 100 }
    }

    /// Both lists are sorted largest first, so axes pair up by size, not by direction.
    static func compare(measured: [Double], reference: [Double]) -> [Axis] {
        zip(measured.sorted(by: >), reference.sorted(by: >)).map { Axis(referenceMillimeters: $1, measuredMillimeters: $0) }
    }

    /// Spread of the same object's extents over repeated reconstructions: standard deviation per axis, in mm.
    /// Repeatability is separate from accuracy: a scan can be consistently wrong.
    static func repeatability(runs: [[Double]]) -> [Double] {
        guard let first = runs.first, runs.count > 1 else { return [] }
        let sorted = runs.map { $0.sorted(by: >) }
        return (0..<first.count).map { axis in
            let values = sorted.compactMap { $0.indices.contains(axis) ? $0[axis] : nil }
            let mean = values.reduce(0, +) / Double(values.count)
            return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1)).squareRoot()
        }
    }
}
