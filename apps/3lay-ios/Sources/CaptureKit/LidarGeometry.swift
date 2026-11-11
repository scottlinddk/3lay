import Foundation
import simd

/// The coordinate conventions of a LiDAR bundle, as code. Everything here is pure and tested against
/// hand-computed values, so a swapped axis or a wrongly scaled intrinsic shows up as a test failure.
///
/// - **World / photo transforms:** ARKit world: meters, right-handed, +Y up. `transform` takes camera to world.
/// - **Camera (ARKit):** +X right, +Y up, the camera looks along **-Z**.
/// - **Image:** pixel (u, v) has u to the right and v *down*, origin at the top-left corner of the
///   raw sensor image (not rotated to portrait).
/// - **Mesh file:** Z up: (x, y, z) in world becomes (x, -z, y).
public enum LidarGeometry {
    /// World (Y up) to mesh (Z up): a rotation of +90 degrees about X. Winding is preserved.
    public static let meshFromWorld = simd_float4x4(columns: (
        SIMD4(1, 0, 0, 0),
        SIMD4(0, 0, 1, 0),   // world +Y (up) maps to mesh +Z
        SIMD4(0, -1, 0, 0),  // world +Z maps to mesh -Y
        SIMD4(0, 0, 0, 1)))

    public static func meshPoint(fromWorld p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, -p.z, p.y) }

    public struct Intrinsics: Equatable {
        public var fx: Float, fy: Float, cx: Float, cy: Float
        public init(fx: Float, fy: Float, cx: Float, cy: Float) { self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy }
        public init?(_ values: [Float]) {
            guard values.count == 4, values.allSatisfy(\.isFinite) else { return nil }
            self.init(fx: values[0], fy: values[1], cx: values[2], cy: values[3])
        }
        public var array: [Float] { [fx, fy, cx, cy] }

        /// Intrinsics for the same view at another resolution. Pixel coordinates are continuous with the
        /// origin at the image corner, so both focal length and principal point scale by the size ratio.
        public func scaled(from: (width: Int, height: Int), to: (width: Int, height: Int)) -> Intrinsics {
            let sx = Float(to.width) / Float(from.width), sy = Float(to.height) / Float(from.height)
            return Intrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy)
        }
    }

    /// Where a world point lands in a photo, and how far in front of the camera it is (meters along the
    /// optical axis). nil if the point is at or behind the camera.
    public static func project(
        world point: SIMD3<Float>, cameraToWorld: simd_float4x4, intrinsics k: Intrinsics
    ) -> (u: Float, v: Float, depth: Float)? {
        let c = cameraToWorld.inverse * SIMD4(point, 1)
        let depth = -c.z
        guard depth > 1e-6 else { return nil }
        // ARKit camera has Y up and looks down -Z; image v grows downward.
        return (k.fx * c.x / depth + k.cx, k.cy - k.fy * c.y / depth, depth)
    }

    /// The world point seen at pixel (u, v) with the given depth (meters along the optical axis).
    public static func unproject(
        u: Float, v: Float, depth: Float, cameraToWorld: simd_float4x4, intrinsics k: Intrinsics
    ) -> SIMD3<Float> {
        let camera = SIMD4((u - k.cx) * depth / k.fx, -(v - k.cy) * depth / k.fy, -depth, 1)
        let w = cameraToWorld * camera
        return SIMD3(w.x, w.y, w.z)
    }
}

extension simd_float4x4 {
    /// 16 floats, column-major: the layout of `LidarManifest.Photo.transform`.
    public var flatMatrix: [Float] {
        [columns.0, columns.1, columns.2, columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    public init?(flat values: [Float]) {
        guard values.count == 16, values.allSatisfy(\.isFinite) else { return nil }
        self.init(columns: (
            SIMD4(values[0], values[1], values[2], values[3]), SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]), SIMD4(values[12], values[13], values[14], values[15])))
    }
}
