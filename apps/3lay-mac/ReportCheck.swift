import Foundation

/// Checks the measurement helpers on shapes with known sizes. Run by `./rebuild_check`.
@main struct ReportCheck {
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ReportCheck failed: \(message)\n".utf8))
        exit(1)
    }

    static func main() {
        // The corners of a 100 x 40 x 20 box, and the same box turned 45 degrees about two axes. Axis-aligned
        // bounds change with the turn; oriented extents must not.
        var corners: [SIMD3<Float>] = []
        for x in [0, 100] as [Float] { for y in [0, 40] as [Float] { for z in [0, 20] as [Float] { corners.append(SIMD3(x, y, z)) } } }
        let straight = OrientedExtents.measure(corners)
        guard zip(straight, [100, 40, 20]).allSatisfy({ abs($0 - $1) < 0.01 }) else { fail("box extents \(straight)") }

        let c = Float(0.5).squareRoot()
        let turned = corners.map { p -> SIMD3<Float> in
            let a = SIMD3(c * p.x - c * p.y, c * p.x + c * p.y, p.z)       // 45 degrees about z
            return SIMD3(a.x, c * a.y - c * a.z, c * a.y + c * a.z)        // 45 degrees about x
        }
        let turnedExtents = OrientedExtents.measure(turned)
        guard zip(turnedExtents, [100, 40, 20]).allSatisfy({ abs($0 - $1) < 0.05 }) else { fail("turned box extents \(turnedExtents)") }
        let aabb = (0..<3).map { axis in turned.map { $0[axis] }.max()! - turned.map { $0[axis] }.min()! }
        // Axis-aligned, the 20 mm side reads about 84 mm: that is why measurements use oriented extents.
        guard aabb.min()! > 60 else { fail("the turned box should read larger axis-aligned: \(aabb)") }

        let axes = DimensionalError.compare(measured: [101.2, 39.5, 20.3], reference: [100, 40, 20])
        guard abs(axes[0].errorMillimeters - 1.2) < 1e-9, abs(axes[1].errorPercent + 1.25) < 1e-9 else { fail("dimensional error \(axes)") }
        let spread = DimensionalError.repeatability(runs: [[100, 40, 20], [102, 40, 21], [101, 40, 19]])
        guard abs(spread[0] - 1) < 1e-9, spread[1] == 0, abs(spread[2] - 1) < 1e-9 else { fail("repeatability \(spread)") }
        guard DimensionalError.repeatability(runs: [[1, 2, 3]]).isEmpty else { fail("one run has no spread") }

        let report = ReconstructionReport(
            createdAt: Date(timeIntervalSince1970: 0), requestedDetail: "Full", actualDetail: "Medium",
            fallbackReason: "Full failed", photosTotal: 80, photosUsed: 76, photosSetAsideBlurry: 4, photosWithDepth: 80,
            durationSeconds: 61.5, peakResidentMegabytes: 4100, outputBytes: 1, triangleCount: 2, vertexCount: 3,
            extentsMillimeters: straight)
        guard report.detailWasReduced else { fail("a reduced detail level must be visible") }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "report-check-\(UUID().uuidString).usdz")
        defer { try? FileManager.default.removeItem(at: file.deletingPathExtension().appendingPathExtension("report.json")) }
        do { try report.write(next: file) } catch { fail("write: \(error)") }
        let url = file.deletingPathExtension().appendingPathExtension("report.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let back = try? decoder.decode(ReconstructionReport.self, from: Data(contentsOf: url)), back == report else { fail("report did not round-trip") }
        print("Report check passed")
    }
}
