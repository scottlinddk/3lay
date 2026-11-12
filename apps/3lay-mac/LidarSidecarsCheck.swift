import Foundation
import simd

/// Checks `LidarSidecars` without a phone: the half-float reader, the version 3 manifest, and the depth/mesh
/// agreement on a synthetic wall.
@main struct LidarSidecarsCheck {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }

    static func main() throws {
        // Half precision: 1, -2, 2, the smallest subnormal, the largest normal, infinity, NaN.
        try require(LidarSidecars.float(fromHalf: 0x3C00) == 1, "half 1")
        try require(LidarSidecars.float(fromHalf: 0xC000) == -2, "half -2")
        try require(LidarSidecars.float(fromHalf: 0x4000) == 2, "half 2")
        try require(abs(LidarSidecars.float(fromHalf: 0x0001) - 5.9604645e-8) < 1e-12, "half subnormal")
        try require(LidarSidecars.float(fromHalf: 0x7BFF) == 65504, "half max")
        try require(LidarSidecars.float(fromHalf: 0x7C00) == .infinity, "half infinity")
        try require(LidarSidecars.float(fromHalf: 0x7E00).isNaN, "half NaN")
        try require(LidarSidecars.float(fromHalf: 0x0000) == 0, "half zero")

        // Manifests: a version 1 bundle has no extras, a version 3 bundle reports them.
        let v1 = #"{"format":"3lay-lidar/1","meshFile":"mesh/scan.ply","photos":[{"file":"photos/0001.jpg"}]}"#
        let old = try JSONDecoder().decode(LidarSidecars.Manifest.self, from: Data(v1.utf8))
        try require(old.summary.isEmpty && old.depthFrames == nil && old.room == nil, "version 1 manifest")
        let v3 = #"""
        {"format":"3lay-lidar/3","meshFile":"mesh/scan.ply",
         "photos":[{"file":"photos/0001.jpg","highRes":true},{"file":"photos/0002.jpg"}],
         "depthFrames":[{"file":"depth/f00001.depth","confidenceFile":"depth/f00001.conf","width":64,"height":48,"encoding":"float16",
                         "transform":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],"intrinsics":[50,50,32,24]}],
         "room":{"file":"room/room.json","walls":4,"doors":1,"windows":2,"openings":0,"objects":5}}
        """#
        let manifest = try JSONDecoder().decode(LidarSidecars.Manifest.self, from: Data(v3.utf8))
        try require(manifest.highResolutionPhotos == 1, "high-res count")
        try require(manifest.summary == "1 full-resolution photos · 1 depth frames · room layout: 4 walls, 1 doors, 2 windows, 5 objects",
                    "summary was: \(manifest.summary)")

        // A wall 2 m in front of a camera at the origin. ARKit world is Y up and looks down -Z, so the wall is
        // z = -2; in the mesh frame (x, -z, y) it is the plane y = 2, sampled every 2 cm.
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".build/lidar-check", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder.appending(path: "depth"), withIntermediateDirectories: true)
        let width = 64, height = 48
        var half = Data(); var single = Data()
        for _ in 0..<(width * height) {
            half.append(contentsOf: [0x00, 0x40])  // 2.0 as half
            var bits = Float(2).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { single.append(contentsOf: $0) }
        }
        try half.write(to: folder.appending(path: "depth/h.depth"))
        try single.write(to: folder.appending(path: "depth/s.depth"))
        try Data(repeating: 2, count: width * height).write(to: folder.appending(path: "depth/c.conf"))
        func frame(_ name: String, _ encoding: String) -> LidarSidecars.Manifest.DepthFrame {
            .init(file: "depth/\(name).depth", confidenceFile: "depth/c.conf", width: width, height: height, encoding: encoding,
                  transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], intrinsics: [50, 50, 32, 24])
        }
        func wall(offset: Float) -> [SIMD3<Float>] {
            var vertices: [SIMD3<Float>] = []
            for i in -100...100 { for j in -100...100 { vertices.append(SIMD3(Float(i) * 0.02, 2 + offset, Float(j) * 0.02)) } }
            return vertices
        }
        for (name, encoding) in [("h", "float16"), ("s", "float32")] {
            let good = LidarSidecars.DepthAgreement.measure(frames: [frame(name, encoding)], folder: folder, meshVertices: wall(offset: 0))
            try require(good != nil && good!.framesUsed == 1 && good!.matchedShare == 1, "\(encoding): wall should match")
            try require(good!.medianMeters < 0.015, "\(encoding): median \(good!.medianMeters) m should be under 1.5 cm")
            // The same scan with the mesh 20 cm off: still in range, clearly worse.
            let off = LidarSidecars.DepthAgreement.measure(frames: [frame(name, encoding)], folder: folder, meshVertices: wall(offset: 0.2))
            try require(off != nil && off!.medianMeters > 0.18 && off!.medianMeters < 0.22, "\(encoding): 20 cm offset read as \(String(describing: off?.medianMeters))")
            // 50 cm off: nothing within the search radius.
            let far = LidarSidecars.DepthAgreement.measure(frames: [frame(name, encoding)], folder: folder, meshVertices: wall(offset: 0.5))
            try require(far != nil && far!.matchedShare == 0, "\(encoding): far mesh should not match")
        }
        // Low confidence, wrong file size and missing files are skipped, not trusted.
        try Data(repeating: 1, count: width * height).write(to: folder.appending(path: "depth/low.conf"))
        var lowConfidence = frame("h", "float16"); lowConfidence.confidenceFile = "depth/low.conf"
        try require(LidarSidecars.DepthAgreement.measure(frames: [lowConfidence], folder: folder, meshVertices: wall(offset: 0)) == nil, "low confidence")
        try require(LidarSidecars.DepthAgreement.measure(frames: [frame("h", "float32")], folder: folder, meshVertices: wall(offset: 0)) == nil, "wrong size")
        try require(LidarSidecars.DepthAgreement.measure(frames: [frame("missing", "float16")], folder: folder, meshVertices: wall(offset: 0)) == nil, "missing file")
        try require(LidarSidecars.DepthAgreement.measure(frames: [], folder: folder, meshVertices: wall(offset: 0)) == nil, "no frames")
        print("LiDAR sidecar and depth agreement checks passed")
    }
}
