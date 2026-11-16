import Foundation
import simd

/// Checks a LiDAR bundle on disk against its manifest, so a malformed or incomplete bundle fails with a
/// clear list of problems instead of producing a bad import later.
public enum LidarBundleValidator {
    public struct Issue: Equatable, CustomStringConvertible {
        public var photo: String?
        public var message: String
        public var description: String { photo.map { "\($0): \(message)" } ?? message }
    }

    public static func validate(manifest: LidarManifest, in folder: URL) -> [Issue] {
        var issues: [Issue] = []
        let fm = FileManager.default
        func add(_ photo: String?, _ message: String) { issues.append(Issue(photo: photo, message: message)) }

        guard manifest.format.hasPrefix("3lay-lidar/") else { return [Issue(photo: nil, message: "Unknown format \(manifest.format).")] }
        if manifest.units != "meters" { add(nil, "Units are \(manifest.units), expected meters.") }
        if !fm.fileExists(atPath: folder.appendingPathComponent(manifest.meshFile).path) { add(nil, "Mesh file \(manifest.meshFile) is missing.") }
        if manifest.photos.isEmpty { add(nil, "The bundle has no photos.") }
        let capabilities = manifest.capabilities ?? []
        if manifest.format != LidarManifest.formatV1, !capabilities.isEmpty,
           let m = manifest.meshFromWorld, simd_float4x4(flat: m) == nil {
            add(nil, "meshFromWorld is not a 4x4 matrix of finite numbers.")
        }

        var lastTime = -Double.infinity
        for photo in manifest.photos {
            let name = photo.file
            guard folder.appendingPathComponent(name).standardizedFileURL.path
                .hasPrefix(folder.standardizedFileURL.path + "/") else { add(name, "Path leaves the bundle."); continue }
            if !fm.fileExists(atPath: folder.appendingPathComponent(name).path) { add(name, "Photo file is missing.") }
            if photo.width <= 0 || photo.height <= 0 { add(name, "Image size \(photo.width)x\(photo.height) is not positive.") }
            if photo.timestamp < lastTime { add(name, "Timestamps go backwards.") }
            lastTime = max(lastTime, photo.timestamp)

            if let transform = simd_float4x4(flat: photo.transform) {
                if !isRigid(transform) { add(name, "Transform is not a rigid camera pose.") }
            } else { add(name, "Transform must be 16 finite numbers.") }
            if let refined = photo.refinedTransform, !isRigidPose(refined) {
                add(name, "Refined transform is not a rigid camera pose.")
            }
            if let blur = photo.motion?.blurPixels, !(blur.isFinite && blur >= 0) {
                add(name, "Motion blur must be a finite, non-negative number of pixels.")
            }
            if photo.highRes == true, !capabilities.contains(LidarManifest.highResCapability) {
                add(name, "Is a high-resolution still but the manifest does not declare \(LidarManifest.highResCapability).")
            }

            if let k = LidarGeometry.Intrinsics(photo.intrinsics) {
                if k.fx <= 0 || k.fy <= 0 { add(name, "Focal length must be positive.") }
                if k.cx < 0 || k.cx > Float(photo.width) || k.cy < 0 || k.cy > Float(photo.height) {
                    add(name, "Principal point lies outside the image.")
                }
            } else { add(name, "Intrinsics must be 4 finite numbers (fx, fy, cx, cy).") }

            if let depth = photo.depth {
                if depth.width <= 0 || depth.height <= 0 {
                    add(name, "Depth size \(depth.width)x\(depth.height) is not positive.")
                    continue
                }
                if !(manifest.capabilities ?? []).contains(LidarManifest.depthCapability) {
                    add(name, "Has depth but the manifest does not declare \(LidarManifest.depthCapability).")
                }
                let pixels = depth.width * depth.height
                check(folder.appendingPathComponent(depth.file), expecting: pixels * 4, label: "Depth map", photo: name, into: &issues)
                check(folder.appendingPathComponent(depth.confidenceFile), expecting: pixels, label: "Confidence map", photo: name, into: &issues)
                if LidarGeometry.Intrinsics(depth.intrinsics) == nil { add(name, "Depth intrinsics must be 4 finite numbers.") }
                // Depth has the photo's field of view: its aspect ratio must match, or the pixels do not line up.
                let photoAspect = Float(photo.width) / Float(photo.height), depthAspect = Float(depth.width) / Float(depth.height)
                if abs(photoAspect - depthAspect) / photoAspect > 0.02 { add(name, "Depth and photo aspect ratios differ, so they do not align.") }
            }
        }

        validateDepthFrames(manifest, in: folder, capabilities: capabilities, add: add)
        validateRoom(manifest, in: folder, capabilities: capabilities, add: add)
        return issues
    }

    /// How far a pose may be from a perfect rigid motion. A pose that stretches by this much moves a point 5 m
    /// away by 5 mm, so anything looser would let a scale error into the scan unnoticed. ARKit's own poses are
    /// orthonormal to about 1e-6.
    static let rigidTolerance: Float = 1e-3

    /// A camera pose is a rigid motion: every axis has unit length, the axes are perpendicular, the determinant
    /// is +1 (no mirror) and the bottom row is 0, 0, 0, 1 (no projection, no overall scale).
    public static func isRigid(_ transform: simd_float4x4) -> Bool {
        let c = transform.columns
        let x = SIMD3(c.0.x, c.0.y, c.0.z), y = SIMD3(c.1.x, c.1.y, c.1.z), z = SIMD3(c.2.x, c.2.y, c.2.z)
        let t = rigidTolerance
        guard abs(simd_length(x) - 1) <= t, abs(simd_length(y) - 1) <= t, abs(simd_length(z) - 1) <= t else { return false }
        guard abs(simd_dot(x, y)) <= t, abs(simd_dot(y, z)) <= t, abs(simd_dot(x, z)) <= t else { return false }
        guard abs(simd_float3x3(x, y, z).determinant - 1) <= 3 * t else { return false }
        return abs(c.0.w) <= t && abs(c.1.w) <= t && abs(c.2.w) <= t && abs(c.3.w - 1) <= t
    }

    /// `isRigid` for a pose as stored in a manifest (16 floats, column-major).
    public static func isRigidPose(_ flat: [Float]) -> Bool {
        simd_float4x4(flat: flat).map(isRigid) ?? false
    }

    private static func inside(_ path: String, of folder: URL) -> Bool {
        !path.isEmpty && !path.hasPrefix("/")
            && folder.appendingPathComponent(path).standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    private static func validateDepthFrames(
        _ manifest: LidarManifest, in folder: URL, capabilities: [String], add: (String?, String) -> Void
    ) {
        guard let frames = manifest.depthFrames, !frames.isEmpty else { return }
        if !capabilities.contains(LidarManifest.depthFramesCapability) {
            add(nil, "Has depth frames but the manifest does not declare \(LidarManifest.depthFramesCapability).")
        }
        var lastTime = -Double.infinity
        for frame in frames {
            let name = frame.file
            guard inside(name, of: folder), inside(frame.confidenceFile, of: folder) else { add(name, "Path leaves the bundle."); continue }
            if frame.width <= 0 || frame.height <= 0 { add(name, "Depth size \(frame.width)x\(frame.height) is not positive."); continue }
            if frame.timestamp < lastTime { add(name, "Depth frame timestamps go backwards.") }
            lastTime = max(lastTime, frame.timestamp)
            let pixels = frame.width * frame.height
            var issues: [Issue] = []
            check(folder.appendingPathComponent(name), expecting: pixels * frame.encoding.bytesPerPixel, label: "Depth map", photo: name, into: &issues)
            check(folder.appendingPathComponent(frame.confidenceFile), expecting: pixels, label: "Confidence map", photo: name, into: &issues)
            for issue in issues { add(issue.photo, issue.message) }
            if let transform = simd_float4x4(flat: frame.transform) {
                if !isRigid(transform) { add(name, "Transform is not a rigid camera pose.") }
            } else { add(name, "Transform must be 16 finite numbers.") }
            if let refined = frame.refinedTransform, !isRigidPose(refined) {
                add(name, "Refined transform is not a rigid camera pose.")
            }
            if let k = LidarGeometry.Intrinsics(frame.intrinsics) {
                if k.fx <= 0 || k.fy <= 0 { add(name, "Focal length must be positive.") }
                if k.cx < 0 || k.cx > Float(frame.width) || k.cy < 0 || k.cy > Float(frame.height) {
                    add(name, "Principal point lies outside the depth map.")
                }
            } else { add(name, "Depth intrinsics must be 4 finite numbers.") }
        }
    }

    private static func validateRoom(
        _ manifest: LidarManifest, in folder: URL, capabilities: [String], add: (String?, String) -> Void
    ) {
        guard let room = manifest.room else { return }
        if !capabilities.contains(LidarManifest.roomCapability) {
            add(room.file, "Has a room layout but the manifest does not declare \(LidarManifest.roomCapability).")
        }
        for path in [room.file] + [room.data, room.usdz].compactMap({ $0 }) {
            guard inside(path, of: folder) else { add(room.file, "Room path \(path) leaves the bundle."); continue }
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) {
                add(room.file, "Room file \(path) is missing.")
            }
        }
    }

    private static func check(_ url: URL, expecting size: Int, label: String, photo: String, into issues: inout [Issue]) {
        guard let actual = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int else {
            issues.append(Issue(photo: photo, message: "\(label) \(url.lastPathComponent) is missing."))
            return
        }
        if actual != size { issues.append(Issue(photo: photo, message: "\(label) is \(actual) bytes, expected \(size).")) }
    }
}
