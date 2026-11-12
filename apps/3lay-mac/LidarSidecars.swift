import Foundation
import simd

/// What the phone's LiDAR bundle (`3lay-lidar/3`, see docs/LIDAR_BUNDLE.md) holds beyond the mesh and photos:
/// depth keyframes with their own poses, full-resolution stills and a RoomPlan layout. The Mac keeps these
/// next to the model, reports them, and uses the depth to check that the mesh and the depth agree.
enum LidarSidecars {
    /// Just the parts of `manifest.json` the Mac reads. Unknown fields are ignored, so any `3lay-lidar/` version decodes.
    struct Manifest: Decodable {
        struct Photo: Decodable { var highRes: Bool? }
        struct DepthFrame: Decodable {
            var file: String
            var confidenceFile: String
            var width: Int
            var height: Int
            /// "float16" or "float32", little-endian meters along the optical axis.
            var encoding: String
            var transform: [Float]
            var intrinsics: [Float]
        }
        struct Room: Decodable {
            var file: String
            var walls: Int
            var doors: Int
            var windows: Int
            var openings: Int
            var objects: Int
        }
        let format: String
        let meshFile: String
        let photos: [Photo]
        var depthFrames: [DepthFrame]?
        var room: Room?

        var highResolutionPhotos: Int { photos.filter { $0.highRes == true }.count }

        /// One line for the status bar, empty for a version 1 or 2 bundle without any of the extras.
        var summary: String {
            var parts: [String] = []
            if highResolutionPhotos > 0 { parts.append("\(highResolutionPhotos) full-resolution photos") }
            if let frames = depthFrames, !frames.isEmpty { parts.append("\(frames.count) depth frames") }
            if let room {
                parts.append("room layout: \(room.walls) walls, \(room.doors) doors, \(room.windows) windows, \(room.objects) objects")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// IEEE half precision to Float, by hand: `Float16` does not exist on Intel Macs.
    static func float(fromHalf bits: UInt16) -> Float {
        let sign: Float = (bits & 0x8000) != 0 ? -1 : 1
        let exponent = Int((bits >> 10) & 0x1F)
        let fraction = Float(bits & 0x03FF)
        switch exponent {
        case 0: return sign * fraction * Float(sign: .plus, exponent: -24, significand: 1)  // zero and subnormals
        case 31: return fraction == 0 ? sign * .infinity : .nan
        default: return sign * (1 + fraction / 1024) * Float(sign: .plus, exponent: exponent - 15, significand: 1)
        }
    }

    /// Does the phone's depth agree with its mesh? Samples confident depth pixels from evenly spaced keyframes,
    /// places them in the mesh's frame and measures how far each lies from the nearest mesh vertex.
    ///
    /// The median has a floor of roughly half the mesh's vertex spacing (a few centimeters for ARKit), so read it
    /// as a drift detector: a clean scan sits near that floor, a scan with a wrong scale or a drifted pose sits far above it.
    struct DepthAgreement: Equatable {
        var framesUsed: Int
        var samples: Int
        /// Share of samples with a mesh vertex within `searchRadius`.
        var matchedShare: Float
        var medianMeters: Float
        var ninetiethPercentileMeters: Float

        static let searchRadius: Float = 0.25

        /// `meshVertices` are in the bundle's mesh frame (meters, Z up). Depth poses are ARKit world (Y up), so each point
        /// is rotated with `meshFromWorld`: (x, y, z) becomes (x, -z, y).
        static func measure(
            frames: [Manifest.DepthFrame], folder: URL, meshVertices: [SIMD3<Float>], maxFrames: Int = 30, pixelStride: Int = 8
        ) -> DepthAgreement? {
            guard !frames.isEmpty, !meshVertices.isEmpty, maxFrames > 0, pixelStride > 0 else { return nil }
            let cell = searchRadius
            var grid: [SIMD3<Int32>: [Int32]] = [:]
            func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
                SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down)))
            }
            for (i, v) in meshVertices.enumerated() where v.x.isFinite && v.y.isFinite && v.z.isFinite { grid[key(v), default: []].append(Int32(i)) }

            let chosen = (0..<min(maxFrames, frames.count)).map { frames[$0 * frames.count / min(maxFrames, frames.count)] }
            var distances: [Float] = []
            var unmatched = 0, used = 0
            for frame in chosen {
                guard let pose = matrix(frame.transform), frame.intrinsics.count == 4, frame.intrinsics.allSatisfy(\.isFinite),
                      frame.intrinsics[0] > 0, frame.intrinsics[1] > 0, frame.width > 0, frame.height > 0,
                      let depth = try? Data(contentsOf: folder.appending(path: frame.file)),
                      let confidence = try? Data(contentsOf: folder.appending(path: frame.confidenceFile)) else { continue }
                let bytes = frame.encoding == "float16" ? 2 : 4
                let pixels = frame.width * frame.height
                guard depth.count == pixels * bytes, confidence.count == pixels else { continue }
                used += 1
                let fx = frame.intrinsics[0], fy = frame.intrinsics[1], cx = frame.intrinsics[2], cy = frame.intrinsics[3]
                for y in stride(from: 0, to: frame.height, by: pixelStride) {
                    for x in stride(from: 0, to: frame.width, by: pixelStride) {
                        let i = y * frame.width + x
                        guard confidence[confidence.startIndex + i] >= 2 else { continue }
                        let at = depth.startIndex + i * bytes
                        let meters: Float
                        if bytes == 2 {
                            let low = UInt16(depth[at]), high = UInt16(depth[at + 1])
                            meters = float(fromHalf: low | (high << 8))
                        } else {
                            let b0 = UInt32(depth[at]), b1 = UInt32(depth[at + 1]), b2 = UInt32(depth[at + 2]), b3 = UInt32(depth[at + 3])
                            meters = Float(bitPattern: b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
                        }
                        guard meters.isFinite, meters > 0.15, meters < 5 else { continue }
                        // Pixel centers; camera looks down -Z with +Y up, image v grows downward.
                        let camera = SIMD4((Float(x) + 0.5 - cx) * meters / fx, -(Float(y) + 0.5 - cy) * meters / fy, -meters, 1)
                        let w = pose * camera
                        let p = SIMD3<Float>(w.x, -w.z, w.y)
                        if let d = nearest(to: p, grid: grid, key: key(p), vertices: meshVertices) { distances.append(d) } else { unmatched += 1 }
                    }
                }
            }
            let total = distances.count + unmatched
            guard used > 0, total > 0 else { return nil }
            distances.sort()
            func percentile(_ q: Float) -> Float { distances.isEmpty ? .infinity : distances[min(distances.count - 1, Int(Float(distances.count) * q))] }
            return DepthAgreement(
                framesUsed: used, samples: total, matchedShare: Float(distances.count) / Float(total),
                medianMeters: percentile(0.5), ninetiethPercentileMeters: percentile(0.9))
        }

        private static func nearest(
            to p: SIMD3<Float>, grid: [SIMD3<Int32>: [Int32]], key k: SIMD3<Int32], vertices: [SIMD3<Float>]
        ) -> Float? {
            var best = Float.infinity
            for dx in Int32(-1)...1 { for dy in Int32(-1)...1 { for dz in Int32(-1)...1 {
                guard let bucket = grid[SIMD3(k.x + dx, k.y + dy, k.z + dz)] else { continue }
                for i in bucket { best = min(best, simd_distance_squared(p, vertices[Int(i)])) }
            } } }
            return best <= searchRadius * searchRadius ? best.squareRoot() : nil
        }

        private static func matrix(_ f: [Float]) -> simd_float4x4? {
            guard f.count == 16, f.allSatisfy(\.isFinite) else { return nil }
            return simd_float4x4(columns: (
                SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]), SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15])))
        }

        var summary: String {
            String(format: "depth agrees with the mesh to a median of %.1f cm (90%% within %.1f cm, %d%% matched)",
                   medianMeters * 100, ninetiethPercentileMeters * 100, Int((matchedShare * 100).rounded()))
        }
    }
}
