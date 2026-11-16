import Foundation
import simd

/// How fast the camera moved between two frames, and how much that smears a photo.
///
/// A photo's pose describes one instant, but its pixels are gathered over the exposure time. Whatever the
/// camera moves in that time is smeared into the image, and nothing downstream can take it out again: a
/// reconstruction places edges from those pixels, so smear turns directly into dimensional error. A fixed
/// speed limit cannot judge this, because the same hand speed is harmless at 1/500 s and ruinous at 1/60 s.
/// The smear in pixels can. Pure math, unit tested.
public struct CameraMotion: Equatable, Sendable {
    /// Meters per second.
    public var speed: Float
    /// Radians per second about any axis, roll included.
    public var angularSpeed: Float

    public init(speed: Float, angularSpeed: Float) {
        self.speed = speed
        self.angularSpeed = angularSpeed
    }

    /// Distance assumed to the scene when no depth is known (meters). Arm's length to a wall: on the near side
    /// of typical, so the translation term is not underestimated.
    public static let defaultSceneDepth: Float = 1
    /// Frames further apart than this (seconds) say nothing about the motion during one exposure.
    public static let maximumElapsed: TimeInterval = 0.5

    /// Average motion between two camera-to-world poses `elapsed` seconds apart. nil when the poses are too
    /// far apart in time to describe one exposure, or not in time order.
    public init?(from a: simd_float4x4, to b: simd_float4x4, elapsed: TimeInterval) {
        guard elapsed > 0, elapsed <= Self.maximumElapsed else { return nil }
        let dt = Float(elapsed)
        speed = simd_distance(CapturePolicy.position(a), CapturePolicy.position(b)) / dt
        angularSpeed = Self.rotationAngle(from: a, to: b) / dt
    }

    /// Angle (radians, 0 to pi) of the rotation that takes pose `a`'s orientation to pose `b`'s.
    ///
    /// Computed from the quaternion's vector part with `atan2`. The usual `acos((trace - 1) / 2)` loses nearly all
    /// its precision for the sub-milliradian turns between two consecutive frames, which are exactly the ones
    /// that matter here.
    public static func rotationAngle(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let relative = simd_quatf(rotation(of: a)).inverse * simd_quatf(rotation(of: b))
        return 2 * atan2(simd_length(relative.imag), abs(relative.real))
    }

    static func rotation(of m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }

    /// Upper estimate of the smear, in pixels of the image `focalLength` belongs to, over one exposure.
    ///
    /// Turning moves the image by `focalLength * angle`. Translating moves a surface at `sceneDepth` by
    /// `focalLength * distance / sceneDepth`. The two are added, which is the worst case (both in the same image
    /// direction, all translation sideways), so the true smear at the image center is at or below this figure.
    /// Rolling-shutter skew comes on top and is not modelled: the sensor's readout time is not published.
    public func blurPixels(exposure: TimeInterval, focalLength: Float, sceneDepth: Float? = nil) -> Float {
        guard exposure > 0, focalLength > 0 else { return 0 }
        let depth = sceneDepth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? Self.defaultSceneDepth
        return focalLength * Float(exposure) * (angularSpeed + speed / depth)
    }

    /// The depth to use for the translation term: the lower quartile of the valid values, because the nearer
    /// surfaces in view smear the most. nil when there are no valid values.
    public static func representativeDepth(_ samples: [Float]) -> Float? {
        let valid = samples.filter { $0.isFinite && $0 > 0 }.sorted()
        return valid.isEmpty ? nil : valid[valid.count / 4]
    }
}

/// How far ARKit moved a pose after it was recorded.
///
/// ARKit keeps correcting its map while you scan (most visibly when you return to a place it has seen). The LiDAR
/// mesh follows those corrections, but a camera pose copied out of a frame does not: it stays where ARKit
/// believed the camera was at that moment. An `ARAnchor` dropped at the camera pose does follow, so at the end of
/// the scan it holds the pose in the same, final map as the mesh. The difference is also the best measure the
/// phone has of how far its own tracking drifted.
public struct PoseCorrection: Equatable, Sendable {
    /// Meters between the recorded and the refined camera position.
    public var translation: Float
    /// Radians between the recorded and the refined orientation.
    public var rotation: Float

    public init(translation: Float, rotation: Float) {
        self.translation = translation
        self.rotation = rotation
    }

    public init(recorded: simd_float4x4, refined: simd_float4x4) {
        translation = simd_distance(CapturePolicy.position(recorded), CapturePolicy.position(refined))
        rotation = CameraMotion.rotationAngle(from: recorded, to: refined)
    }

    /// nil unless both are 16 finite numbers.
    public init?(recorded: [Float], refined: [Float]) {
        guard let a = simd_float4x4(flat: recorded), let b = simd_float4x4(flat: refined) else { return nil }
        self.init(recorded: a, refined: b)
    }
}
